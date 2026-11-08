defmodule Trailblazer.Store.Edges do
  @moduledoc "The edges the resolver drew between a repository's nodes: replaced as one batch, and read by endpoint and kind."

  alias Trailblazer.Store.Resolution
  import Trailblazer.Store, only: [read: 1, run: 1]
  import Trailblazer.Store.Sql
  import Trailblazer.Store.Writes, only: [batch_digest: 1, same_batch?: 5, remember_batch: 5]

  @edge_columns "id, repo_id, from_id, to_id, kind, uncertain, line"
  @edge_select "SELECT #{@edge_columns} FROM edge"

  @edge_batch 500

  ## Edges

  @doc """
  Replaces `repo_id`'s resolved edges with `edges`.
  """
  @spec put_edges(integer(), [map()]) :: :ok | {:error, {:foreign_node, integer()}}
  def put_edges(repo_id, edges) do
    case Enum.find_index(edges, &(not valid_edge?(&1))) do
      nil -> put_valid_edges(repo_id, edges)
      index -> {:error, {:bad_edge, Enum.at(edges, index)}}
    end
  end

  defp valid_edge?(%{from_id: from, to_id: to, kind: kind, uncertain: uncertain} = edge) do
    is_integer(from) and from > 0 and is_integer(to) and to > 0 and
      is_binary(kind) and is_boolean(uncertain) and
      (is_nil(edge[:line]) or (is_integer(edge[:line]) and edge[:line] > 0))
  end

  defp valid_edge?(_), do: false

  defp put_valid_edges(repo_id, edges) do
    run(fn conn ->
      own_ids =
        rows(conn, :repo_node_ids, "SELECT id FROM node WHERE repo_id = ?", [repo_id])
        |> MapSet.new(& &1.id)

      case Enum.find(
             Enum.flat_map(edges, &[&1.from_id, &1.to_id]),
             &(not MapSet.member?(own_ids, &1))
           ) do
        nil ->
          digest = batch_digest(edges)

          unless same_batch?(conn, repo_id, "edges", "", digest) do
            replace_edges(conn, repo_id, edges)
            Resolution.untracked(conn, repo_id)
            remember_batch(conn, repo_id, "edges", "", digest)
          end

          :ok

        id ->
          {:error, {:foreign_node, id}}
      end
    end)
  end

  defp replace_edges(conn, repo_id, edges) do
    transaction(conn, fn conn ->
      write(conn, :edge_delete_repo, "DELETE FROM edge WHERE repo_id = ?", [repo_id])

      for batch <- Enum.chunk_every(edges, @edge_batch) do
        write(
          conn,
          :"edge_insert_#{length(batch)}",
          "INSERT INTO edge (repo_id, from_id, to_id, kind, uncertain, line) VALUES " <>
            Enum.map_join(batch, ", ", fn _ -> "(?, ?, ?, ?, ?, ?)" end),
          Enum.flat_map(batch, fn edge ->
            [repo_id, edge.from_id, edge.to_id, edge.kind, sql_bool(edge.uncertain), edge[:line]]
          end)
        )
      end
    end)
  end

  @doc """
  Distinct graph links touching these ids, with both endpoints in the repo.
  Call-site lines are not needed by a graph walk: many calls to the same
  target contribute one weighted link, not repeated database round trips.

  `max_targets: n` leaves out uncertain calls from a site that resolved to
  more than `n` candidates.
  """
  def adjacent_edges(repo_id, ids, opts \\ []) do
    max_targets = Keyword.get(opts, :max_targets)
    true = is_nil(max_targets) or (is_integer(max_targets) and max_targets > 0)

    read(fn conn ->
      ids
      |> Enum.uniq()
      |> Enum.chunk_every(400)
      |> Enum.flat_map(fn batch ->
        slots = placeholders(length(batch))

        # With max_targets, an uncertain call whose site (from_id, line) resolved
        # to more candidates than that is left out: it says only that some
        # function of that name exists. On a TypeScript repository nearly all
        # call edges are such fan-out (every `.pipe(` linked to every `pipe`),
        # and walking through them reached most of the graph.
        ambiguous =
          if max_targets,
            do:
              " AND NOT (e.kind='calls' AND e.uncertain=1 AND " <>
                "(SELECT count(*) FROM edge s INDEXED BY edge_site " <>
                "WHERE s.from_id=e.from_id AND s.line IS e.line AND s.kind='calls') > #{max_targets})",
            else: ""

        # OR plus repo_id makes SQLite scan the whole repo for every batch.
        # Each direction must use its endpoint index; UNION removes repeated
        # call sites while retaining distinct kinds and uncertainty weights.
        direction = fn column, index ->
          "SELECT e.from_id, e.to_id, e.kind, e.uncertain FROM edge e INDEXED BY #{index} " <>
            "JOIN node f ON f.id=e.from_id JOIN node t ON t.id=e.to_id " <>
            "WHERE e.repo_id=? AND f.repo_id=? AND t.repo_id=? " <>
            "AND e.#{column} IN (#{slots})" <> ambiguous
        end

        params = [repo_id, repo_id, repo_id] ++ batch

        rows(
          conn,
          :adjacent_edges,
          direction.("from_id", "edge_from") <> " UNION " <> direction.("to_id", "edge_to"),
          params ++ params
        )
      end)
      |> Enum.uniq()
      |> Enum.map(fn edge -> Map.update!(edge, :uncertain, &flag/1) end)
    end)
  end

  @doc """
  The edges leaving `ids`, of any kind or only those named in `kinds`.
  """
  @spec edges_from(integer() | [integer()], [String.t()] | nil) :: [map()]
  def edges_from(ids, kinds \\ nil), do: edges(:edges_from, "from_id", ids, kinds)

  @doc """
  The edges arriving at `ids`, of any kind or only those named in `kinds`.
  """
  @spec edges_to(integer() | [integer()], [String.t()] | nil) :: [map()]
  def edges_to(ids, kinds \\ nil), do: edges(:edges_to, "to_id", ids, kinds)

  defp edges(name, column, ids, kinds) do
    ids = List.wrap(ids)
    kinds = List.wrap(kinds)

    read(fn conn ->
      case ids do
        [] ->
          []

        _ ->
          sql =
            @edge_select <>
              " WHERE #{column} IN (#{placeholders(length(ids))})" <> kinds_sql(kinds)

          conn
          |> rows(name, sql, ids ++ kinds)
          |> Enum.map(fn edge -> Map.update!(edge, :uncertain, &flag/1) end)
      end
    end)
  end
end
