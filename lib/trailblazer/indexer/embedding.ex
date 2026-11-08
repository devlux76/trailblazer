defmodule Trailblazer.Indexer.Embedding do
  @moduledoc "Pending vectors for one repository's indexer: picks the next batch of definitions to embed, writes their vectors and queued point deletions, and backs off while the embedder or Qdrant is down."

  alias Trailblazer.{Config, Embed, EmbedGate, EmbedHealth, Files, Store, Vectors}
  alias Trailblazer.Indexer
  import Trailblazer.Indexer.Parse, only: [read: 2, hash: 1]

  # J29: a file indexed while git reported it, then ignored (a .gitignore or
  # .git/info/exclude entry added later), changes without git ever saying so,
  # and its pending definitions would wait for a sync that never comes. It is
  # settled the way the full listing would: an ignored file is not listed, so
  # it is deleted (a full sync would only mark it stale, still pending), and an
  # ignored file in a vendored tree, which is listed, is read again. Changed
  # files git does report are left to the sync their change starts. Once per
  # path and content, so a file that keeps changing cannot loop.
  defp resync_ignored(s) do
    done = Map.get(s, :resynced, MapSet.new())
    changed = MapSet.difference(Map.get(s, :changed_unsynced, MapSet.new()), done)
    s = Map.put(s, :changed_unsynced, MapSet.new())
    paths = changed |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    git = Keyword.get(s.opts, :git, Trailblazer.Git)

    case paths != [] && git.ignored(s.path, paths) do
      {:ok, [_ | _] = ignored} ->
        {vendored, unlisted} = Enum.split_with(ignored, &Files.vendored?/1)
        Enum.each(unlisted, &Store.delete_file(s.id, &1))
        s = if unlisted == [], do: s, else: Map.put(s, :edges_current, false)
        s = Map.put(s, :resynced, MapSet.union(done, changed))
        s = if vendored == [], do: s, else: Indexer.queue_sync(s, MapSet.new(vendored))
        # the deletions leave vectors to remove
        kick(s)

      _ ->
        s
    end
  end

  @doc false
  def kick(%{sync_job: job} = s) when not is_nil(job), do: s
  def kick(%{store_waiting: true} = s), do: s
  def kick(%{job: job} = s) when not is_nil(job), do: s
  def kick(%{waiting: true} = s), do: s

  def kick(s) do
    deleted = Store.pending_vector_deletes(s.id)
    known = Store.files(s.id) |> Map.new(&{&1.path, &1.hash})

    # 16 definitions per embedder, so every device in the pool has work.
    size = 16 * length(Embed.urls(s.opts))

    nodes =
      if s.paused,
        do: [],
        else: Store.pending_vectors(s.id, size, exclude_stale: true, after_id: s.cursor)

    # A file that no longer matches what was indexed is skipped, and noted with
    # what is on disk now (J29, below).
    {batch, changed} =
      Enum.reduce(nodes, {[], Map.get(s, :changed_unsynced, MapSet.new())}, fn node,
                                                                               {batch, changed} ->
        case read(s, node.path) do
          {:ok, source} ->
            disk = hash(source)

            if disk == known[node.path] do
              text =
                source
                |> String.split("\n")
                |> Enum.slice(node.start_line - 1, node.end_line - node.start_line + 1)
                |> Enum.join("\n")

              calls =
                Store.edges_from(node.id, ["calls"])
                |> Enum.map(&Store.node(&1.to_id))
                |> Enum.reject(&is_nil/1)
                |> Enum.map(& &1.qualified)

              {[{node, Embed.node_text(node, text, calls, Config.doc_limit(s.path))} | batch],
               changed}
            else
              {batch, MapSet.put(changed, {node.path, disk})}
            end

          _ ->
            {batch, MapSet.put(changed, {node.path, :unreadable})}
        end
      end)

    batch = Enum.reverse(batch)
    # Map.put, not %{s | ...}: indexers already running when this code is
    # loaded have no such key yet.
    s = Map.put(s, :changed_unsynced, changed)
    s = if nodes == [], do: s, else: %{s | cursor: List.last(nodes).id}

    cond do
      batch == [] and deleted == [] and nodes != [] ->
        kick(s)

      batch == [] and deleted == [] ->
        :ok = EmbedGate.update(s.embed_priority, false)

        # What is still pending has a file that changed since it was read:
        # the sync that follows the change kicks again (no timer). Git reports
        # no change to an ignored file, so those get a sync here (J29).
        resync_ignored(%{s | cursor: 0})

      true ->
        :ok = EmbedGate.update(s.embed_priority, batch != [])
        parent = self()

        {pid, ref} =
          :erlang.spawn_opt(
            fn ->
              vectors = Keyword.get(s.opts, :vectors, Vectors)
              embed = Keyword.get(s.opts, :embed, Embed)
              pairs = Enum.map(batch, fn {n, _} -> {n.id, n.text_hash} end)

              result =
                with :ok <- vectors.ensure(s.path, s.opts),
                     :ok <- vectors.delete(s.path, deleted, s.opts),
                     :ok <- embed_batch(Map.put(s, :owner, parent), batch, embed, vectors) do
                  :ok
                end

              send(parent, {:batch_done, self(), result, pairs, deleted})
            end,
            [:link, :monitor]
          )

        %{s | job: {pid, ref}}
    end
  end

  defp embed_batch(_, [], _, _), do: :ok

  defp embed_batch(s, batch, embed, vectors) do
    :ok = EmbedGate.acquire(s.owner)

    # The HTTP has no client timeout: one backstop guards the batch, and only
    # the requests run in the guarded process, so the gate is always released.
    limit = {:ms, Config.get(:backstop_embed_batch_ms)}
    evidence = fn -> %{definitions: length(batch)} end

    try do
      case Trailblazer.Backstop.guard(:embed_batch, s.path, limit, evidence, fn ->
             put_batch(s, batch, embed, vectors)
           end) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    after
      EmbedGate.release()
    end
  end

  defp put_batch(s, batch, embed, vectors) do
    with {:ok, values} <-
           Trailblazer.EmbedCache.documents(Enum.map(batch, &elem(&1, 1)), embed, s.opts),
         true <- length(values) == length(batch) do
      points =
        Enum.zip_with(batch, values, fn {n, _}, v ->
          %{id: n.id, vector: v, payload: %{path: n.path, kind: n.kind}}
        end)

      vectors.put(s.path, points, s.opts)
    else
      false -> {:error, :bad_batch}
      error -> error
    end
  end

  # The embedder or Qdrant failed: EmbedHealth probes and publishes :up.
  @doc false
  def retry(s, reason) do
    :ok = EmbedGate.update(s.embed_priority, false)
    EmbedHealth.down(reason)
    %{s | waiting: true}
  end
end
