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
  alias Trailblazer.{Config, Embed, EmbedGate, Vectors}

  # The code embedding cycle's sizes (operator, 2026-11-06): one entry is at
  # most a definition's 2,400 characters (`Embed.node_text/4`), 16 per request.
  @doc_chars Trailblazer.History.Chunks.doc_chars()
  @request_chars 600
  @batch 16
  @bulk_files 60

  import Trailblazer.History.Chunks, only: [chunks: 8, file_patches: 1]
  import Trailblazer.History.Git, only: [bug: 1, cards: 2, commits: 2, git: 2, refs: 1]
  import Trailblazer.History.Privacy, only: [patterns: 1, screen: 2, tilde: 2]
  import Trailblazer.History.Labels, only: [reverted: 1]

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

  # Background work: the corpus registers at the gate below every indexer and
  # takes it one small batch at a time, so live indexing goes first and
  # queries (trails, memory recall) preempt it between requests.
  defp embed_new(new, opts) do
    gate = Keyword.get(opts, :gate, EmbedGate)

    idle(gate, fn ->
      new
      |> Enum.chunk_every(@batch)
      |> Enum.reduce_while(:ok, fn batch, :ok ->
        turn(gate, fn -> embed_batch(batch, opts) end)
      end)
    end)
  end

  defp idle(gate, fun) do
    if gate && GenServer.whereis(gate) do
      :ok = EmbedGate.update(EmbedGate.idle_priority(), true, gate)

      try do
        fun.()
      after
        EmbedGate.update(EmbedGate.idle_priority(), false, gate)
      end
    else
      fun.()
    end
  end

  defp turn(gate, fun) do
    if gate && GenServer.whereis(gate) do
      # {:error, :owner_down} if the gate restarted: the ingest stops; the
      # batches not yet written are embedded on the next run
      with :ok <- EmbedGate.acquire(self(), gate) do
        try do
          fun.()
        after
          EmbedGate.release(gate)
        end
      else
        error -> {:halt, error}
      end
    else
      fun.()
    end
  end

  defp embed_batch(batch, opts) do
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

  @doc """
  The `limit` stored entries nearest to `text`, as `{score, entry}`. Each
  entry carries `"change"`: the file's whole diff in that commit, stitched
  from all its chunks (the embedded unit is a chunk; what a coder is shown is
  the change), or nil when its chunks are not all held.
  """
  @spec similar(String.t(), pos_integer(), keyword()) ::
          {:ok, [{float(), map()}]} | {:error, term()}
  def similar(text, limit \\ 10, opts \\ []) do
    stored = load()
    by_point = Map.new(stored, fn {_, e} -> {e["point"], e} end)

    with {:ok, vector} <- embed(opts).query(text, opts),
         {:ok, hits} <- vectors(opts).nearest(root(), vector, limit, opts) do
      files = Enum.group_by(Map.values(stored), &{&1["repo"], &1["commit"], &1["path"]})

      {:ok,
       for {point, score} <- hits, e = by_point[point] do
         {score, Map.put(e, "change", change(files[{e["repo"], e["commit"], e["path"]}]))}
       end}
    end
  end

  @doc false
  # Chunk 0's file header, then every chunk's hunks in order; nil unless
  # chunks 0..n-1 are all held (an entry from before `chunks` was recorded
  # needs only an unbroken run from 0).
  def change(siblings) do
    sorted = Enum.sort_by(siblings || [], & &1["chunk"])
    total = sorted |> List.first(%{}) |> Map.get("chunks")

    if sorted != [] and Enum.map(sorted, & &1["chunk"]) == Enum.to_list(0..(length(sorted) - 1)) and
         total in [nil, length(sorted)] do
      [first | _] = parts = Enum.map(sorted, &String.split(&1["patch"], ~r/^(?=@@ )/m, parts: 2))
      hd(first) <> Enum.map_join(parts, &Enum.at(&1, 1, ""))
    end
  end

  defp stringify(e), do: e |> Jason.encode!() |> Jason.decode!()

  defp doc_hash(e) do
    {path, text} = document(%{"path" => e.path, "request" => e.request, "patch" => e.patch})
    :crypto.hash(:sha256, [path, 0, text]) |> Base.encode16(case: :lower)
  end

  defp embed(opts), do: Keyword.get(opts, :embed, Embed)
  defp vectors(opts), do: Keyword.get(opts, :vectors, Vectors)

  @doc false
  defdelegate label(entries, reverted), to: Trailblazer.History.Labels
end
