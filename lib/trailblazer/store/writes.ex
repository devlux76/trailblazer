defmodule Trailblazer.Store.Writes do
  @moduledoc "Writes that change one file's graph: replacing its nodes and refs, marking them stale, forgetting the file, and the batch fingerprints that make a retried write a no-op."

  alias Trailblazer.Store.{Resolution, Sql}
  import Trailblazer.Store, only: [run: 1]
  import Trailblazer.Store.Sql
  import Trailblazer.Store.ResolutionAccess, only: [resolution_file: 3]
  import Trailblazer.Store.Vectors, only: [queue_vector_deletes: 3]

  @node_select Sql.node_select()
  @node_upsert """
  INSERT INTO node (repo_id, key, lang, kind, name, qualified, path, start_line, end_line,
                    signature, text_hash, ord, stale)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
  ON CONFLICT (repo_id, key) DO UPDATE SET
    ord = excluded.ord,
    lang = excluded.lang,
    kind = excluded.kind,
    name = excluded.name,
    qualified = excluded.qualified,
    path = excluded.path,
    start_line = excluded.start_line,
    end_line = excluded.end_line,
    signature = excluded.signature,
    text_hash = excluded.text_hash,
    stale = 0
  """

  @doc """
  Replaces everything `path` contributed to `repo_id`: its hash, its nodes and
  its refs, in one transaction. A node whose key is already there keeps its id
  and its `vector_hash`, so only a node whose text changed needs embedding
  again; nodes and refs that are gone are removed, and the file's nodes are no
  longer marked stale.
  """
  @spec replace_file(integer(), Path.t(), %{
          hash: term(),
          nodes: [map()],
          refs: [map()]
        }) :: :ok | {:error, {:bad_ref_target, map()}}
  def replace_file(repo_id, path, %{hash: hash, nodes: nodes, refs: refs}) do
    cond do
      Enum.any?(refs, &(not is_map(&1) or not is_binary(&1[:target]))) ->
        {:error,
         {:bad_ref_target, Enum.find(refs, &(not is_map(&1) or not is_binary(&1[:target])))}}

      Enum.any?(refs, &(not is_boolean(Map.get(&1, :ambiguous, false)))) ->
        {:error, {:bad_ref, Enum.find(refs, &(not is_boolean(Map.get(&1, :ambiguous, false))))}}

      true ->
        replace_valid_file(repo_id, path, hash, nodes, refs)
    end
  end

  defp replace_valid_file(repo_id, path, hash, nodes, refs) do
    run(fn conn ->
      transaction(conn, fn conn ->
        digest = batch_digest({hash, nodes, refs})

        unless same_batch?(conn, repo_id, "file", path, digest) do
          Resolution.ensure(conn)
          before = resolution_file(conn, repo_id, path)
          incoming = Resolution.incoming(conn, repo_id, path)
          upsert_nodes(conn, repo_id, nodes)
          drop_missing_nodes(conn, repo_id, path, nodes)

          write(conn, :refs_delete_file, "DELETE FROM ref WHERE repo_id = ? AND path = ?", [
            repo_id,
            path
          ])

          insert_refs(conn, repo_id, path, refs)

          write(
            conn,
            :file_upsert,
            "INSERT INTO file (repo_id, path, hash) VALUES (?, ?, ?) " <>
              "ON CONFLICT (repo_id, path) DO UPDATE SET hash = excluded.hash",
            [repo_id, path, hash]
          )

          Resolution.mutated(
            conn,
            repo_id,
            path,
            before,
            resolution_file(conn, repo_id, path),
            incoming
          )

          forget_batch(conn, repo_id, "edges", "")
          remember_batch(conn, repo_id, "file", path, digest)
        end
      end)
    end)
  end

  @doc """
  Marks the nodes of `path` stale, because the file no longer parses. They and
  their edges stay, so a file being edited does not empty the graph.
  """
  @spec mark_stale(integer(), Path.t()) :: :ok
  def mark_stale(repo_id, path) do
    run(fn conn ->
      forget_batch(conn, repo_id, "file", path)

      write(conn, :node_mark_stale, "UPDATE node SET stale = 1 WHERE repo_id = ? AND path = ?", [
        repo_id,
        path
      ])

      :ok
    end)
  end

  @doc """
  Forgets `path`: its nodes, its refs, and every edge to or from those nodes.
  An edge that pointed into the file from another file goes with it, so the
  graph holds no dangling ids; the reference that made it stays unresolved.
  """
  @spec delete_file(integer(), Path.t()) :: :ok
  def delete_file(repo_id, path) do
    run(fn conn ->
      transaction(conn, fn conn ->
        Resolution.ensure(conn)
        before = resolution_file(conn, repo_id, path)
        incoming = Resolution.incoming(conn, repo_id, path)
        forget_batch(conn, repo_id, "file", path)
        forget_batch(conn, repo_id, "edges", "")
        ids = ids_of_file(conn, repo_id, path)
        queue_vector_deletes(conn, repo_id, ids)
        delete_edges_touching(conn, ids)

        write(conn, :refs_delete_file, "DELETE FROM ref WHERE repo_id = ? AND path = ?", [
          repo_id,
          path
        ])

        write(conn, :node_delete_file, "DELETE FROM node WHERE repo_id = ? AND path = ?", [
          repo_id,
          path
        ])

        write(conn, :file_delete, "DELETE FROM file WHERE repo_id = ? AND path = ?", [
          repo_id,
          path
        ])

        Resolution.mutated(conn, repo_id, path, before, %{nodes: [], refs: []}, incoming)
      end)
    end)
  end

  ## Writes

  # A node's place in its parser's output is kept (`ord`), so a file's nodes
  # come back in source order whatever ids earlier versions gave them (C4).
  defp upsert_nodes(conn, repo_id, nodes) do
    for {node, ord} <- Enum.with_index(nodes) do
      write(conn, :node_upsert, @node_upsert, [
        repo_id,
        node.key,
        node[:lang],
        node.kind,
        node[:name],
        node[:qualified],
        node.path,
        node.start_line,
        node.end_line,
        node[:signature],
        node[:text_hash],
        ord
      ])
    end

    :ok
  end

  defp drop_missing_nodes(conn, repo_id, path, nodes) do
    keep = MapSet.new(nodes, & &1.key)

    gone =
      conn
      |> node_rows(:nodes_of_file, @node_select <> " WHERE repo_id = ? AND path = ?", [
        repo_id,
        path
      ])
      |> Enum.reject(&MapSet.member?(keep, &1.key))
      |> Enum.map(& &1.id)

    queue_vector_deletes(conn, repo_id, gone)
    delete_edges_touching(conn, gone)

    case gone do
      [] ->
        :ok

      _ ->
        write(
          conn,
          :node_delete,
          "DELETE FROM node WHERE id IN (#{placeholders(length(gone))})",
          gone
        )
    end

    :ok
  end

  defp ids_of_file(conn, repo_id, path) do
    conn
    |> rows(:node_ids_of_file, "SELECT id FROM node WHERE repo_id = ? AND path = ?", [
      repo_id,
      path
    ])
    |> Enum.map(& &1.id)
  end

  defp delete_edges_touching(conn, ids) do
    case ids do
      [] ->
        :ok

      ids ->
        write(
          conn,
          :edge_delete_touching,
          "DELETE FROM edge WHERE from_id IN (#{placeholders(length(ids))}) " <>
            "OR to_id IN (#{placeholders(length(ids))})",
          ids ++ ids
        )

        :ok
    end
  end

  defp insert_refs(conn, repo_id, path, refs) do
    for ref <- refs do
      write(
        conn,
        :ref_insert,
        "INSERT INTO ref (repo_id, path, from_key, kind, target, arity, line, ambiguous, provenance) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [
          repo_id,
          path,
          ref[:from_key],
          ref.kind,
          ref.target,
          ref[:arity],
          ref[:line],
          if(ref[:ambiguous], do: 1, else: 0),
          ref[:provenance]
        ]
      )
    end

    :ok
  end

  # One durable fingerprint per current file/edge batch, committed with its data.
  # Retrying after a lost acknowledgement leaves row identities intact (J16).
  @doc false
  def batch_digest(payload),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(payload, [:deterministic]))

  @doc false
  def same_batch?(conn, repo, kind, path, digest) do
    rows(
      conn,
      :batch_match,
      "SELECT 1 AS present FROM write_batch WHERE repo_id = ? AND kind = ? AND path = ? AND digest = ?",
      [repo, kind, path, {:blob, digest}]
    ) != []
  end

  @doc false
  def remember_batch(conn, repo, kind, path, digest) do
    write(
      conn,
      :batch_remember,
      "INSERT INTO write_batch(repo_id,kind,path,digest) VALUES (?,?,?,?) " <>
        "ON CONFLICT(repo_id,kind,path) DO UPDATE SET digest = excluded.digest",
      [repo, kind, path, {:blob, digest}]
    )
  end

  defp forget_batch(conn, repo, kind, path),
    do:
      write(
        conn,
        :batch_forget,
        "DELETE FROM write_batch WHERE repo_id = ? AND kind = ? AND path = ?",
        [repo, kind, path]
      )
end
