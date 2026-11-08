defmodule Trailblazer.Store.Vectors do
  @moduledoc "Vector bookkeeping: the embedding cache, the nodes whose vector is pending, and the points whose deletion is queued for Qdrant."

  alias Trailblazer.Store.Sql
  import Trailblazer.Store, only: [read: 1, run: 1]
  import Trailblazer.Store.Sql

  @node_select Sql.node_select()

  @doc "The cached float32 vector blob for this model and exact input hash."
  def embedding_cache_get(model, hash) do
    read(fn conn ->
      case rows(
             conn,
             :embedding_cache_get,
             "SELECT vector FROM embedding_cache WHERE model = ? AND hash = ?",
             [model, hash]
           ) do
        [%{vector: blob}] -> blob
        [] -> nil
      end
    end)
  end

  @doc "Caches a float32 vector independently of a repository's point ids."
  def embedding_cache_put(model, hash, blob) do
    run(fn conn ->
      write(
        conn,
        :embedding_cache_put,
        "INSERT INTO embedding_cache (model, hash, vector) VALUES (?, ?, ?) " <>
          "ON CONFLICT (model, hash) DO UPDATE SET vector = excluded.vector",
        [model, hash, {:blob, blob}]
      )
    end)
  end

  def pending_vector_deletes(repo_id),
    do:
      read(fn conn ->
        rows(
          conn,
          :vector_deletes,
          "SELECT node_id FROM vector_delete WHERE repo_id = ? ORDER BY node_id",
          [repo_id]
        )
        |> Enum.map(& &1.node_id)
      end)

  def vector_deleted(repo_id, ids) do
    run(fn conn ->
      for id <- ids,
          do:
            write(
              conn,
              :vector_deleted,
              "DELETE FROM vector_delete WHERE repo_id = ? AND node_id = ?",
              [repo_id, id]
            )

      :ok
    end)
  end

  @doc false
  def queue_vector_deletes(conn, repo_id, ids) do
    for id <- ids,
        do:
          write(
            conn,
            :vector_delete_queue,
            "INSERT OR IGNORE INTO vector_delete (repo_id,node_id) VALUES (?,?)",
            [repo_id, id]
          )
  end

  ## Vectors

  @doc """
  At most `limit` of the repo's nodes whose `vector_hash` is not their current
  `text_hash`, in the order they were indexed.
  """
  @spec pending_vectors(integer(), integer()) :: [map()]
  @spec pending_vectors(integer(), integer(), keyword()) :: [map()]
  def pending_vectors(repo_id, limit, opts \\ []) do
    read(fn conn ->
      node_rows(
        conn,
        :pending_vectors,
        @node_select <>
          " WHERE repo_id = ? AND (vector_hash IS NULL OR IFNULL(text_hash, '') <> IFNULL(vector_hash, ''))" <>
          if(Keyword.get(opts, :exclude_stale, false), do: " AND stale = 0", else: "") <>
          " AND id > ? ORDER BY id LIMIT ?",
        [repo_id, Keyword.get(opts, :after_id, 0), limit]
      )
    end)
  end

  @doc """
  Says that each node is embedded as the text whose hash it is given, so it is
  no longer pending.

  The hash is the one that was embedded, not the node's current one: a file
  may have been indexed again while the embedding was in flight, and then this
  node's vector is the old text's, so it has to stay pending for the new text.
  """
  @spec vector_done([{integer(), String.t() | nil}] | {integer(), String.t() | nil}) :: :ok
  def vector_done(pairs) do
    pairs = List.wrap(pairs)

    run(fn conn ->
      transaction(conn, fn conn ->
        for {id, hash} <- pairs do
          write(conn, :vector_done, "UPDATE node SET vector_hash = ? WHERE id = ?", [hash, id])
        end
      end)
    end)
  end
end
