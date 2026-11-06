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
  - every request, commit message, path and patch is screened with the commit
    hook's patterns (`~/.config/git/pii-patterns`, never copied or printed;
    case-insensitive, as the hooks apply them); a match drops the entry and
    logs only its repo, commit and field. A missing, empty or uncompilable
    pattern file refuses the run (`{:error, :pii_patterns}`): the screen never
    silently passes everything;
  - the home directory's absolute path is written as `~` everywhere, and an
    entry that is not valid UTF-8 is dropped;
  - an entry whose commit is no longer reachable is purged (vector and line)
    on the next `ingest/2`.

  Labels (recomputed on every ingest): `reverted` (a revert commit names it),
  `fixed_up` (a later commit citing the same bug changed the lines it wrote
  within 24 hours, by committer time; ranges are the changed lines, not the
  context), `open` (its card is still open), else `succeeded`.

  An entry whose embedded text changes (a card edited later) is re-embedded
  under the same point; a git failure halts the ingest before anything is
  purged.

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
  @hunk_head ~r/\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@([^\n]*)\n/

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

    with {:ok, patterns} <- patterns(opts),
         {:ok, refs} <- refs(repo),
         {:ok, commits} <- commits(repo, refs),
         {:ok, cards} <- cards(repo, commits) do
      home = home(opts)

      result =
        Enum.reduce_while(commits, {:ok, [], 0}, fn c, {:ok, acc, dropped} ->
          case commit_entries(repo, c, cards, patterns, home) do
            {:ok, kept, n} -> {:cont, {:ok, [kept | acc], dropped + n}}
            error -> {:halt, error}
          end
        end)

      with {:ok, acc, dropped} <- result do
        entries = acc |> Enum.reverse() |> Enum.concat()
        {:ok, label(entries, reverted(commits)), %{commits: length(commits), dropped: dropped}}
      end
    end
  end

  defp home(opts), do: Keyword.get_lazy(opts, :home, &System.user_home!/0)
  defp tilde(text, home), do: String.replace(text, home, "~")

  defp refs(repo) do
    case git(repo, ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/tags"]) do
      {:ok, out} -> {:ok, String.split(out, "\n", trim: true)}
      error -> error
    end
  end

  defp commits(_repo, []), do: {:ok, []}

  defp commits(repo, refs) do
    format = "--format=%H%x1f%P%x1f%aI%x1f%ct%x1f%B%x1e"

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
  # git-bug itself must run (it is in ~/.local/bin, outside the service's
  # PATH): without it every card would silently fall back to the commit
  # message. A cited id with no card still falls back.
  defp cards(repo, commits) do
    ids = commits |> Enum.map(&bug(&1.message)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    cond do
      ids == [] ->
        {:ok, %{}}

      match?({:ok, _}, git(repo, ["bug", "version"])) ->
        {:ok, Map.new(ids, &{&1, card(repo, &1)})}

      true ->
        {:error, :git_bug_unavailable}
    end
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
        [sha] <-
          Regex.scan(~r/This reverts commit ([0-9a-f]{7,40})/, c.message, capture: :all_but_first),
        do: sha
  end

  # The entries of one commit (one per file and chunk) and how many the
  # privacy screen dropped.
  # A git failure is returned (the caller halts before purging anything); a
  # bulk commit (an import or snapshot, not a worked change) yields nothing.
  defp commit_entries(repo, c, cards, patterns, home) do
    with {:ok, out} <-
           git(repo, ["show", "--format=", "--no-renames", "--no-color", "-U3", c.sha]) do
      patches = file_patches(out)

      if length(patches) > @bulk_files do
        {:ok, [], 0}
      else
        bug = bug(c.message)
        card = bug && cards[bug]
        # the home directory's path names the machine's user: written as ~
        message = tilde(c.message, home)
        request = String.slice(tilde((card && card.text) || c.message, home), 0, @request_chars)

        {kept, dropped} =
          Enum.flat_map_reduce(patches, 0, fn {path, patch}, dropped ->
            path = tilde(path, home)
            patch = tilde(patch, home)
            fields = %{request: request, message: message, path: path, patch: patch}

            case screen(fields, patterns) do
              :ok ->
                {chunks(repo, home, c, bug, card, path, request, patch), dropped}

              {:drop, field} ->
                Logger.info(
                  "trailblazer: history dropped #{Path.basename(repo)} #{c.sha} (#{field})"
                )

                {[], dropped + 1}
            end
          end)

        {:ok, kept, dropped}
      end
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

  @screened [:request, :message, :path, :patch]

  defp screen(fields, patterns) do
    cond do
      field = Enum.find(@screened, &(not String.valid?(fields[&1]))) ->
        {:drop, "#{field} not utf-8"}

      field = Enum.find(@screened, fn f -> Enum.any?(patterns, &Regex.match?(&1, fields[f])) end) ->
        {:drop, field}

      true ->
        :ok
    end
  end

  # The commit hook's patterns, case-insensitive as the hooks apply them;
  # never printed, logged or copied. Missing, empty or uncompilable refuses.
  defp patterns(opts) do
    path = Keyword.get_lazy(opts, :pii_file, fn -> Path.expand("~/.config/git/pii-patterns") end)

    with {:ok, text} <- File.read(path),
         lines =
           for(
             line <- String.split(text, "\n"),
             line = String.trim(line),
             line != "" and not String.starts_with?(line, "#"),
             do: line
           ),
         true <- lines != [],
         compiled = Enum.map(lines, &Regex.compile(&1, "i")),
         true <- Enum.all?(compiled, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(compiled, fn {:ok, re} -> re end)}
    else
      _ -> {:error, :pii_patterns}
    end
  end

  # A file's diff cut at hunk boundaries so request + path + chunk fit the
  # embedder's input; an oversized hunk is split at line boundaries, each
  # piece with its own correct `@@` header.
  defp chunks(repo, home, c, bug, card, path, request, patch) do
    [header | hunks] = String.split(patch, ~r/^(?=@@ )/m)
    budget = @doc_chars - String.length(request) - String.length(path) - 32

    hunks
    |> Enum.flat_map(&split_hunk(&1, budget - String.length(header)))
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

      id =
        :crypto.hash(:sha256, Enum.join([name, c.sha, path, i], <<0>>))
        |> Base.encode16(case: :lower)

      {old_ranges, new_ranges} = changed_ranges(chunk)

      %{
        id: id,
        point: Vectors.point_id(id),
        repo: name,
        repo_path: tilde(repo, home),
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
        old_ranges: old_ranges,
        new_ranges: new_ranges,
        label: "succeeded"
      }
    end)
  end

  # Room for a piece's own `@@ -s,n +s,n @@` line.
  @head_room 48

  defp split_hunk(hunk, budget) do
    with true <- String.length(hunk) > budget and budget > @head_room,
         [head, os, on, ns, nn, context] <- Regex.run(@hunk_head, hunk) do
      body = binary_part(hunk, byte_size(head), byte_size(hunk) - byte_size(head))

      body
      |> String.split(~r/(?<=\n)/, trim: true)
      |> Enum.chunk_while(
        [],
        fn line, acc ->
          # a "\ No newline" marker stays with the line it qualifies
          if acc != [] and not String.starts_with?(line, "\\") and
               String.length(Enum.join(Enum.reverse([line | acc]))) > budget - @head_room,
             do: {:cont, Enum.reverse(acc), [line]},
             else: {:cont, [line | acc]}
        end,
        fn acc -> {:cont, Enum.reverse(acc), []} end
      )
      |> Enum.map_reduce({first(os, on), first(ns, nn), context}, fn lines, {o, n, ctx} ->
        old = Enum.count(lines, &String.starts_with?(&1, [" ", "-"]))
        new = Enum.count(lines, &String.starts_with?(&1, [" ", "+"]))

        piece =
          "@@ -#{start(o, old)},#{old} +#{start(n, new)},#{new} @@#{ctx}\n" <> Enum.join(lines)

        {piece, {o + old, n + new, ""}}
      end)
      |> elem(0)
    else
      _ -> [hunk]
    end
  end

  # The first line a hunk side covers; a side of 0 lines names the line before.
  defp first(s, n), do: if(n == "0", do: String.to_integer(s) + 1, else: String.to_integer(s))
  defp start(line, 0), do: line - 1
  defp start(line, _), do: line

  # The changed lines (not the context) of every hunk in `chunk`, one
  # [first, last] per run of -/+ lines: `{old_ranges, new_ranges}`. A side a
  # run does not touch is [k, k - 1] (empty, before line k).
  defp changed_ranges(chunk) do
    chunk
    |> String.split(~r/^(?=@@ )/m)
    |> Enum.flat_map(fn hunk ->
      case Regex.run(@hunk_head, hunk) do
        [head, os, on, ns, nn, _] ->
          body = binary_part(hunk, byte_size(head), byte_size(hunk) - byte_size(head))
          runs(String.split(body, "\n"), first(os, on), first(ns, nn), nil, [])

        _ ->
          []
      end
    end)
    |> Enum.unzip()
  end

  defp runs([], _o, _n, run, acc), do: Enum.reverse(close(run, acc))

  defp runs([line | rest], o, n, run, acc) do
    case line do
      "-" <> _ -> runs(rest, o + 1, n, bump(run, o, n, 1, 0), acc)
      "+" <> _ -> runs(rest, o, n + 1, bump(run, o, n, 0, 1), acc)
      " " <> _ -> runs(rest, o + 1, n + 1, nil, close(run, acc))
      _ -> runs(rest, o, n, run, acc)
    end
  end

  defp bump(nil, o, n, dm, dp), do: {o, n, dm, dp}
  defp bump({os, ns, m, p}, _o, _n, dm, dp), do: {os, ns, m + dm, p + dp}

  defp close(nil, acc), do: acc
  defp close({os, ns, m, p}, acc), do: [{[os, os + m - 1], [ns, ns + p - 1]} | acc]

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

  # A later same-bug commit whose changed old lines (or insertion point) fall
  # inside lines `e` wrote; `e`'s pure deletions wrote nothing.
  defp fixed_up?(e, siblings) do
    written = Enum.filter(e.new_ranges, fn [c, d] -> d >= c end)

    Enum.any?(siblings, fn s ->
      s.commit != e.commit and s.at > e.at and s.at - e.at <= @fixup_seconds and
        Enum.any?(s.old_ranges, fn [a, b] ->
          Enum.any?(written, fn [c, d] -> a <= d and c <= max(a, b) end)
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
            {:ok, stored, counts} ->
              {:cont, {:ok, stored, Map.put(stats, Path.basename(repo), counts)}}

            {:error, _} = error ->
              {:halt, error}
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
      fresh = Enum.map(fresh, &(&1 |> stringify() |> Map.put("doc", doc_hash(&1))))
      fresh_ids = MapSet.new(fresh, & &1["id"])
      repo_path = tilde(repo, home(opts))

      gone =
        for {id, e} <- stored,
            e["repo_path"] == repo_path,
            not MapSet.member?(fresh_ids, id),
            do: e

      # not held yet, or its embedded text changed (re-embedded, same point)
      new = Enum.reject(fresh, &(get_in(stored, [&1["id"], "doc"]) == &1["doc"]))

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
  def document(e),
    do: {e["path"], String.slice(e["request"] <> "\n" <> e["patch"], 0, @doc_chars)}

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
  @spec similar(String.t(), pos_integer(), keyword()) ::
          {:ok, [{float(), map()}]} | {:error, term()}
  def similar(text, limit \\ 10, opts \\ []) do
    by_point = Map.new(load(), fn {_, e} -> {e["point"], e} end)

    with {:ok, vector} <- embed(opts).query(text, opts),
         {:ok, hits} <- vectors(opts).nearest(root(), vector, limit, opts) do
      {:ok, for({point, score} <- hits, e = by_point[point], do: {score, e})}
    end
  end

  defp stringify(e), do: e |> Jason.encode!() |> Jason.decode!()

  defp doc_hash(e) do
    {path, text} = document(%{"path" => e.path, "request" => e.request, "patch" => e.patch})
    :crypto.hash(:sha256, [path, 0, text]) |> Base.encode16(case: :lower)
  end

  defp git(repo, args) do
    path = Enum.join([Path.expand("~/.local/bin"), System.get_env("PATH", "")], ":")

    case System.cmd("git", args, cd: repo, stderr_to_stdout: true, env: [{"PATH", path}]) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {:git, status, String.slice(out, 0, 300)}}
    end
  rescue
    e -> {:error, {:git, Exception.message(e)}}
  end

  defp embed(opts), do: Keyword.get(opts, :embed, Embed)
  defp vectors(opts), do: Keyword.get(opts, :vectors, Vectors)
end
