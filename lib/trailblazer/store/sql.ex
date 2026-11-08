defmodule Trailblazer.Store.Sql do
  @moduledoc "The store's SQL plumbing: the shared column lists, prepared statements, row maps, placeholders and the transaction wrapper."

  @node_columns "id, repo_id, key, lang, kind, name, qualified, path, " <>
                  "start_line, end_line, signature, text_hash, stale, vector_hash"

  @node_select "SELECT #{@node_columns} FROM node"

  @ref_select """
  SELECT r.id, r.repo_id, r.path, r.from_key, n.id AS from_id, r.kind, r.target, r.arity, r.line, r.ambiguous
  FROM ref r
  LEFT JOIN node n ON n.repo_id = r.repo_id AND n.key = r.from_key
  """

  @doc false
  def node_select, do: @node_select

  @doc false
  def ref_select, do: @ref_select

  @doc false
  def transaction(conn, fun) do
    {:ok, _result} = Exqlite.transaction(conn, fun, timeout: :infinity)
    :ok
  end

  def write(conn, name, statement, params \\ []) do
    {_query, _result} =
      Exqlite.prepare_execute!(conn, name, statement, params, timeout: :infinity)

    :ok
  end

  def rows(conn, name, statement, params \\ []) do
    {_query, %Exqlite.Result{columns: columns, rows: rows}} =
      Exqlite.prepare_execute!(conn, name, statement, params, timeout: :infinity)

    keys = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows, fn row -> keys |> Enum.zip(row) |> Map.new() end)
  end

  def node_rows(conn, name, statement, params) do
    conn
    |> rows(name, statement, params)
    |> Enum.map(fn row -> Map.update!(row, :stale, &flag/1) end)
  end

  def kinds_sql([]), do: ""
  def kinds_sql(kinds), do: " AND kind IN (#{placeholders(length(kinds))})"

  def placeholders(count) when count > 0, do: Enum.map_join(1..count, ",", fn _ -> "?" end)
  def placeholders(_count), do: "NULL"

  def sql_bool(value) when value in [true, 1, "1"], do: 1
  def sql_bool(_other), do: 0

  def flag(value) when value in [true, 1, "1"], do: true
  def flag(_other), do: false
end
