defmodule Trailblazer.History do
  @moduledoc """
  The history corpus (plan `docs/2026-11-05-history-retrieval-plan.md`, step
  2): every change our repositories already hold, as worked examples a coder
  can be shown later. One entry is one commit x one file's hunks: the card's
  request (git-bug title, body and "Implementation plan:" note, else the
  commit message), the file's unified diff, and an outcome label. Each entry is
  one JSON line in `<state>/history/entries.jsonl` and one 768-wide vector in
  the corpus's own collection, so `similar/3` finds the past changes closest to
  a task.

  Like `Trailblazer.Memory`, the corpus belongs to the harness, not to one
  repository: entries are tagged with their repo and recall works across all.

  What is read (privacy, operator 2026-11-05; the repositories were squashed
  on 2026-10-25 to redact PII, and the corpus must not undo that):

  - reachable history only: the commits of `refs/heads` and `refs/tags`, never
    `--all`, `refs/bugs`, the reflog or unreachable objects; merges and
    "Squashed snapshot" commits are skipped;
  - every request, commit message and patch is screened with the commit hook's
    patterns (`~/.config/git/pii-patterns`, never copied or printed) and the
    request and message also for the home directory's absolute path; a match
    drops the entry and logs only its repo, commit, path and field;
  - an entry whose commit is no longer reachable is purged (vector and line)
    on the next `ingest/2`.

  Labels (recomputed on every ingest): `reverted` (a revert commit names it),
  `fixed_up` (a later commit citing the same bug changed the lines it wrote
  within 24 hours), `open` (its card is still open), else `succeeded`.

  Point ids come from sha256 (`Trailblazer.Vectors.point_id/1`), not
  `:erlang.phash2` (31 bits; Qdrant silently overwrites a colliding id), and
  a collision is refused on write.

  Run on the live node:
  `bin/trailblazer rpc 'Trailblazer.History.ingest(["/home/mirai/projects/vortex"]) |> IO.inspect()'`.
  """

  require Logger
  alias Trailblazer.{Config, Embed, Vectors}

  @doc_chars 6_000
  @request_chars 1_500
  @batch 16
  @fixup_seconds 24 * 3600
  @skip_dirs ~w(_build deps node_modules dist)
  @lock_names ~w(package-lock.json mix.lock)
  @squash "Squashed snapshot"
  @bulk_files 60
  @hunk ~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/m

  @doc "Where the corpus lives; also the key of its vector collection."
  def root, do: Path.join(Config.get(:state_dir), "history")
  defp file, do: Path.join(root(), "entries.jsonl")

  ## Reading a repository

  @doc """
  The entries of one repository's reachable history, labelled, after the
  privacy screen: `{:ok, entries, %{commits: n, dropped: n}}`.
  """
  @spec entries(Path.t(), keyword()) :: {:ok, [map()], map()} | {:error, term()}
  def entries(repo, opts \\ []) do
    repo = Path.expand(repo)

    with {:ok, refs} <- refs(repo),
         {:ok, commits} <- commits(repo, refs) do
      cards = cards(repo, commits)
      patterns = patterns(opts)
      home = Keyword.get_lazy(opts, :home, &System.user_home!/0)

      {entries, dropped} =
        Enum.flat_map_reduce(commits, 0, fn c, dropped ->
          {kept, n} = commit_entries(repo, c, cards, patterns, home)
          {kept, dropped + n}
        end)

      {:ok, label(entries, reverted(commits)), %{commits: length(commits), dropped: dropped}}
    end
  end

  defp refs(repo) do
    case git(repo, ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/tags"]) do
      {:ok, out} -> {:ok, String.split(out, "\n", trim: true)}
      error -> error
    end
  end

  defp commits(_repo, []), do: {:ok, []}

  defp commits(repo, refs) do
    format = "--format=%H%x1f%P%x1f%aI%x1f%at%x1f%B%x1e"

    with {:ok, out} <- git(repo, ["log", "--no-merges", "--reverse", format | refs] ++ ["--"]) do
      commits =
        out
        |> String.split("\x1e", trim: true)
        |> Enum.flat_map(fn record ->
          case String.split(String.trim_leading(record, "\n"), "\x1f", parts: 5) do
            [sha, parents, date, at, message] when sha != "" ->
              [
                %{
                  sha: sha,
                  parent: parents |> String.split(" ", trim: true) |> List.first(),
                  date: date,
                  at: String.to_integer(at),
                  message: String.trim(message)
                }
              ]

            _ ->
              []
          end
        end)
        |> Enum.reject(&String.starts_with?(&1.message, @squash))

      {:ok, commits}
    end
  end

  # One git-bug card per bug id cited in the history: %{title, status, text}.
  defp cards(repo, commits) do
    commits
    |> Enum.map(&bug(&1.message))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(fn id -> {id, card(repo, id)} end)
  end

  defp card(repo, id) do
    with {:ok, out} <- git(repo, ["bug", "bug", "show", id, "--format", "json"]),
         {:ok, %{"title" => title, "status" => status} = card} <- Jason.decode(out) do
      comments = for %{"message" => m} <- card["comments"] || [], is_binary(m), do: m
      %{title: title, status: status, text: Enum.join([title | comments], "\n\n")}
    else
      _ -> nil
    end
  end

  defp bug(message) do
    case Regex.run(~r/\bbug:([0-9a-f]{7,})/, message, capture: :all_but_first) do
      [id] -> id
      _ -> nil
    end
  end

  defp reverted(commits) do
    for c <- commits,
        [sha] <- Regex.scan(~r/This reverts commit ([0-9a-f]{7,40})/, c.message, capture: :all_but_first),
        do: sha
  end

  # The entries of one commit (one per file and chunk) and how many the
  # privacy screen dropped.
  defp commit_entries(repo, c, cards, patterns, home) do
    with {:ok, out} <- git(repo, ["show", "--format=", "--no-renames", "--no-color", "-U3", c.sha]),
         patches when length(patches) <= @bulk_files <- file_patches(out) do
      bug = bug(c.message)
      card = bug && cards[bug]
      # the home directory's path names the machine's user: written as ~
      tilde = &String.replace(&1, home, "~")
      message = tilde.(c.message)
      request = String.slice(tilde.((card && card.text) || c.message), 0, @request_chars)

      Enum.flat_map_reduce(patches, 0, fn {path, patch}, dropped ->
        patch = tilde.(patch)

        case screen(%{request: request, message: message, patch: patch}, patterns) do
          :ok ->
            {chunks(repo, c, bug, card, path, request, patch), dropped}

          {:drop, field} ->
            Logger.info(
              "trailblazer: history dropped #{Path.basename(repo)} #{c.sha} #{path} (#{field})"
            )

            {[], dropped + 1}
        end
      end)
    else
      # git failed, or a bulk commit (an import or snapshot, not a worked change)
      _ -> {[], 0}
    end
  end

  # {path, patch} per changed file: no deletions, binaries, lock files or
  # build output.
  defp file_patches(show) do
    show
    |> String.split(~r/^diff --git /m, trim: true)
    |> Enum.flat_map(fn part ->
      with [_, path] <- Regex.run(~r/^\+\+\+ b\/(.+)$/m, part),
           false <- String.contains?(part, ["\nBinary files ", "\nGIT binary patch"]),
           false <- skipped?(path),
           [_, body] <- String.split(part, ~r/^--- /m, parts: 2) do
        [{path, "--- " <> body}]
      else
        _ -> []
      end
    end)
  end

  defp skipped?(path) do
    parts = Path.split(path)
    name = List.last(parts)

    Enum.any?(parts, &(&1 in @skip_dirs)) or name in @lock_names or
      String.ends_with?(name, ".lock") or String.starts_with?(name, "bun.lock")
  end

  defp screen(fields, patterns) do
    case Enum.find([:request, :message, :patch], fn f ->
           Enum.any?(patterns, &Regex.match?(&1, fields[f]))
         end) do
      nil -> :ok
      field -> {:drop, field}
    end
  end

  # The commit hook's patterns; never printed, logged or copied.
  defp patterns(opts) do
    path = Keyword.get_lazy(opts, :pii_file, fn -> Path.expand("~/.config/git/pii-patterns") end)

    case File.read(path) do
      {:ok, text} ->
        for line <- String.split(text, "\n"),
            line = String.trim(line),
            line != "" and not String.starts_with?(line, "#"),
            {:ok, re} <- [Regex.compile(line)],
            do: re

      {:error, _} ->
        []
    end
  end

  # A file's diff cut at hunk boundaries so request + path + chunk fit the
  # embedder's input; one oversized hunk is cut hard.
  defp chunks(repo, c, bug, card, path, request, patch) do
    [header | hunks] = String.split(patch, ~r/^(?=@@ )/m)
    budget = @doc_chars - String.length(request) - String.length(path) - 32

    hunks
    |> Enum.flat_map(&hard_cut(&1, budget - String.length(header)))
    |> Enum.chunk_while(
      "",
      fn hunk, acc ->
        if acc != "" and String.length(header <> acc <> hunk) > budget,
          do: {:cont, header <> acc, hunk},
          else: {:cont, acc <> hunk}
      end,
      fn acc -> {:cont, header <> acc, ""} end
    )
    |> Enum.with_index()
    |> Enum.map(fn {chunk, i} ->
      name = Path.basename(repo)
      id = :crypto.hash(:sha256, Enum.join([name, c.sha, path, i], <<0>>)) |> Base.encode16(case: :lower)
      ranges = Regex.scan(@hunk, chunk, capture: :all_but_first)

      %{
        id: id,
        point: Vectors.point_id(id),
        repo: name,
        repo_path: repo,
        commit: c.sha,
        parent: c.parent,
        date: c.date,
        at: c.at,
        bug: bug,
        card_status: card && card.status,
        path: path,
        chunk: i,
        request: request,
        patch: chunk,
        old_ranges: Enum.map(ranges, fn [s, n | _] -> range(s, n) end),
        new_ranges: Enum.map(ranges, fn [_, _, s, n | _] -> range(s, n) end),
        label: "succeeded"
      }
    end)
  end

  defp hard_cut(hunk, budget) when budget > 0 do
    if String.length(hunk) <= budget,
      do: [hunk],
      else: hunk |> String.codepoints() |> Enum.chunk_every(budget) |> Enum.map(&Enum.join/1)
  end

  defp hard_cut(hunk, _budget), do: [hunk]

  # [first, last] lines of a hunk side; an empty side is [s, s - 1].
  defp range(s, n) do
    s = String.to_integer(s)
    n = if n in [nil, ""], do: 1, else: String.to_integer(n)
    [s, s + n - 1]
  end

  @doc false
  # reverted > fixed_up > open > succeeded.
  def label(entries, reverted) do
    by_change = Enum.group_by(entries, &{&1.bug, &1.path})

    Enum.map(entries, fn e ->
      label =
        cond do
          Enum.any?(reverted, &String.starts_with?(e.commit, &1)) -> "reverted"
          e.bug && fixed_up?(e, by_change[{e.bug, e.path}]) -> "fixed_up"
          e.card_status == "open" -> "open"
          true -> "succeeded"
        end

      %{e | label: label}
    end)
  end

  defp fixed_up?(e, siblings) do
    Enum.any?(siblings, fn s ->
      s.commit != e.commit and s.at > e.at and s.at - e.at <= @fixup_seconds and
        Enum.any?(s.old_ranges, fn [a, b] ->
          Enum.any?(e.new_ranges, fn [c, d] -> a <= max(c, d) and c <= max(a, b) end)
        end)
    end)
  end

  ## Storing

  @doc """
  Brings the corpus up to date with `repos` (paths): embeds the entries it
  does not hold yet (in batches, appended as they land, so an interrupted run
  resumes), refreshes every label and purges entries whose commit is no
  longer reachable. Returns per-repo counts.
  """
  @spec ingest([Path.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def ingest(repos, opts \\ []) do
    File.mkdir_p!(root())

    with :ok <- vectors(opts).ensure(root(), opts) do
      result =
        Enum.reduce_while(repos, {:ok, load(), %{}}, fn repo, {:ok, stored, stats} ->
          case ingest_repo(Path.expand(repo), stored, opts) do
            {:ok, stored, counts} -> {:cont, {:ok, stored, Map.put(stats, Path.basename(repo), counts)}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      with {:ok, stored, stats} <- result do
        rewrite(stored)
        {:ok, stats}
      end
    end
  end

  defp ingest_repo(repo, stored, opts) do
    with {:ok, fresh, info} <- entries(repo, opts) do
      fresh = Enum.map(fresh, &stringify/1)
      fresh_ids = MapSet.new(fresh, & &1["id"])

      gone =
        for {id, e} <- stored, e["repo_path"] == repo, not MapSet.member?(fresh_ids, id), do: e

      new = Enum.reject(fresh, &Map.has_key?(stored, &1["id"]))

      with :ok <- vectors(opts).delete(root(), Enum.map(gone, & &1["point"]), opts),
           :ok <- no_collision(new, stored),
           :ok <- embed_new(new, opts) do
        stored =
          stored
          |> Map.drop(Enum.map(gone, & &1["id"]))
          |> Map.merge(Map.new(fresh, &{&1["id"], &1}))

        {:ok, stored,
         Map.merge(info, %{entries: length(fresh), new: length(new), purged: length(gone)})}
      end
    end
  end

  defp no_collision(new, stored) do
    taken = Map.new(stored, fn {id, e} -> {e["point"], id} end)

    Enum.reduce_while(new, {:ok, taken}, fn %{"id" => id, "point" => point}, {:ok, taken} ->
      case taken[point] do
        nil -> {:cont, {:ok, Map.put(taken, point, id)}}
        ^id -> {:cont, {:ok, taken}}
        other -> {:halt, {:error, {:point_collision, id, other}}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp embed_new(new, opts) do
    new
    |> Enum.chunk_every(@batch)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      docs = Enum.map(batch, &document/1)

      with {:ok, vectors} <- embed(opts).documents(docs, opts),
           points =
             Enum.zip_with(batch, vectors, fn e, v ->
               %{id: e["point"], vector: v, payload: %{id: e["id"], repo: e["repo"]}}
             end),
           :ok <- vectors(opts).put(root(), points, opts) do
        File.write!(file(), Enum.map(batch, &(Jason.encode!(&1) <> "\n")), [:append])
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  @doc "The text embedded for an entry: `{path, request + patch}`, at most #{@doc_chars} characters."
  def document(e), do: {e["path"], String.slice(e["request"] <> "\n" <> e["patch"], 0, @doc_chars)}

  @doc "Every stored entry by id (string keys; the last line for an id wins)."
  @spec load() :: %{String.t() => map()}
  def load do
    case File.read(file()) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"id" => _} = e} -> [e]
            _ -> []
          end
        end)
        |> Map.new(&{&1["id"], &1})

      {:error, _} ->
        %{}
    end
  end

  # One line per entry, oldest first, written whole then renamed into place.
  defp rewrite(stored) do
    tmp = file() <> ".tmp"

    lines =
      stored
      |> Map.values()
      |> Enum.sort_by(&{&1["at"], &1["repo"], &1["path"], &1["chunk"]})
      |> Enum.map(&(Jason.encode!(&1) <> "\n"))

    File.write!(tmp, lines)
    File.rename!(tmp, file())
  end

  ## Recall

  @doc "The `limit` stored entries nearest to `text`, as `{score, entry}`."
  @spec similar(String.t(), pos_integer(), keyword()) :: {:ok, [{float(), map()}]} | {:error, term()}
  def similar(text, limit \\ 10, opts \\ []) do
    by_point = Map.new(load(), fn {_, e} -> {e["point"], e} end)

    with {:ok, vector} <- embed(opts).query(text, opts),
         {:ok, hits} <- vectors(opts).nearest(root(), vector, limit, opts) do
      {:ok, for({point, score} <- hits, e = by_point[point], do: {score, e})}
    end
  end

  defp stringify(e), do: e |> Jason.encode!() |> Jason.decode!()

  defp git(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {:git, status, String.slice(out, 0, 300)}}
    end
  rescue
    e -> {:error, {:git, Exception.message(e)}}
  end

  defp embed(opts), do: Keyword.get(opts, :embed, Embed)
  defp vectors(opts), do: Keyword.get(opts, :vectors, Vectors)
end
