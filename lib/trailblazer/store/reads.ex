defmodule Trailblazer.Store.Reads do
  @moduledoc "Read-only queries over one repository's nodes, refs, files and counts. Each call answers from one snapshot."

  alias Trailblazer.Store.Sql
  import Trailblazer.Store, only: [read: 1]
  import Trailblazer.Store.Sql

  @node_select Sql.node_select()
  @ref_select Sql.ref_select()

  ## Reads

  @doc """
  The node with that id, or `nil`.
  """
  @spec node(integer()) :: map() | nil
  def node(id) do
    read(fn conn ->
      case node_rows(conn, :node_by_id, @node_select <> " WHERE id = ?", [id]) do
        [node] -> node
        [] -> nil
      end
    end)
  end

  @doc "The nodes with these ids, fetched in batches rather than one transaction per node."
  def nodes(ids) do
    read(fn conn ->
      ids
      |> Enum.uniq()
      |> Enum.chunk_every(400)
      |> Enum.flat_map(fn batch ->
        node_rows(
          conn,
          :nodes_by_ids,
          @node_select <> " WHERE id IN (#{placeholders(length(batch))})",
          batch
        )
      end)
    end)
  end

  @doc """
  The repo's nodes declared with that bare name, such as `"put"`.
  """
  @spec nodes_by_name(integer(), String.t()) :: [map()]
  def nodes_by_name(repo_id, name), do: nodes_where(repo_id, "name", name)

  @doc """
  The repo's nodes with that qualified name, such as `"Mini.Store.put/2"`.
  """
  @spec nodes_by_qualified(integer(), String.t()) :: [map()]
  def nodes_by_qualified(repo_id, qualified), do: nodes_where(repo_id, "qualified", qualified)

  @doc """
  The repo's nodes declared in that file.
  """
  @spec nodes_in_file(integer(), Path.t()) :: [map()]
  def nodes_in_file(repo_id, path), do: nodes_where(repo_id, "path", path)

  defp nodes_where(repo_id, column, value) do
    read(fn conn ->
      node_rows(
        conn,
        :"nodes_by_#{column}",
        @node_select <> " WHERE repo_id = ? AND #{column} = ? ORDER BY path, ord, id",
        [
          repo_id,
          value
        ]
      )
    end)
  end

  @doc """
  Every reference of the repo as it was parsed, each with the node it comes
  from as `from_id` when that node is still there. A reference outside any
  definition has a nil `from_key` and a nil `from_id`.
  """
  @spec refs(integer()) :: [map()]
  def refs(repo_id) do
    read(fn conn ->
      rows(conn, :refs, @ref_select <> " WHERE r.repo_id = ? ORDER BY r.id", [repo_id])
      |> Enum.map(&Map.update!(&1, :ambiguous, fn value -> flag(value) end))
    end)
  end

  @doc "A coherent view of all nodes and unresolved refs in one repository."
  def graph_snapshot(repo_id), do: read(&graph_snapshot(&1, repo_id))

  @doc false
  def graph_snapshot(conn, repo_id) do
    %{
      nodes:
        node_rows(conn, :snapshot_nodes, @node_select <> " WHERE repo_id = ? ORDER BY id", [
          repo_id
        ]),
      refs:
        rows(conn, :snapshot_refs, @ref_select <> " WHERE r.repo_id = ? ORDER BY r.id", [repo_id])
        |> Enum.map(&Map.update!(&1, :ambiguous, fn value -> flag(value) end))
    }
  end

  @doc "The last successfully parsed hash of each indexed file."
  def files(repo_id),
    do:
      read(fn conn ->
        rows(conn, :files, "SELECT path, hash FROM file WHERE repo_id = ? ORDER BY path", [
          repo_id
        ])
      end)

  @doc "The paths whose file is a module node of its own (`qualified` is the path)."
  def module_paths(repo_id),
    do:
      read(fn conn ->
        conn
        |> rows(
          :module_paths,
          "SELECT path FROM node WHERE repo_id = ? AND kind = 'module' AND qualified = path",
          [repo_id]
        )
        |> Enum.map(& &1.path)
      end)

  @doc "A repository's node and edge counts, counted by the database."
  def counts(repo_id),
    do:
      read(fn conn ->
        [%{n: nodes}] =
          rows(conn, :count_nodes, "SELECT COUNT(*) AS n FROM node WHERE repo_id = ?", [repo_id])

        [%{n: edges}] =
          rows(
            conn,
            :count_edges,
            "SELECT COUNT(*) AS n FROM edge e JOIN node f ON f.id = e.from_id WHERE f.repo_id = ?",
            [repo_id]
          )

        %{nodes: nodes, edges: edges}
      end)

  @doc "The paths with stale nodes in a repository, without loading its graph."
  def stale_paths(repo_id),
    do:
      read(fn conn ->
        conn
        |> rows(:stale_paths, "SELECT DISTINCT path FROM node WHERE repo_id = ? AND stale = 1", [
          repo_id
        ])
        |> Enum.map(& &1.path)
      end)
end
