defmodule Trailblazer.Store.Resolution.Sql do
  @moduledoc "SQL helpers for the resolver's tables: query and row mapping, batched inserts and scoped reads, shared by the resolver and its publication."

  alias Trailblazer.Graph.Inputs

  @doc false
  def publication_rows(conn, select, repo, column, keys, full) do
    if full,
      do: rows(conn, select <> " WHERE repo_id=?", [repo]),
      else: scoped(conn, select, repo, column, keys)
  end

  @doc false
  def scoped(conn, select, repo, column, keys) do
    keys
    |> Enum.chunk_every(200)
    |> Enum.flat_map(fn chunk ->
      rows(conn, select <> " WHERE repo_id=? AND #{column} IN (#{marks(chunk)})", [repo | chunk])
    end)
  end

  @doc false
  def replace_tables(conn, repo, tables, path) do
    for {name, cols, key} <- [
          {"resolve_import", ~w(path member target), :imports},
          {"resolve_path", ~w(path node_count ref_count), :paths},
          {"resolve_file_suffix", ~w(suffix path), :file_suffixes},
          {"resolve_doc_suffix", ~w(suffix node_id path), :doc_suffixes}
        ] do
      if path == :all,
        do: query(conn, "DELETE FROM #{name} WHERE repo_id=?", [repo]),
        else: query(conn, "DELETE FROM #{name} WHERE repo_id=? AND path=?", [repo, path])

      insert(
        conn,
        name,
        ["repo_id" | cols],
        Enum.map(Map.fetch!(tables, key), &[repo | &1]),
        "OR IGNORE"
      )
    end
  end

  @doc false
  def blob(token), do: {:blob, Inputs.encode(token)}
  @doc false
  def marks(values), do: Enum.map_join(values, ",", fn _ -> "?" end)

  @doc false
  def insert(conn, table, columns, data, modifier \\ "", suffix \\ "") do
    for chunk <- Enum.chunk_every(data, 200) do
      tuple = "(" <> marks(columns) <> ")"

      query(
        conn,
        "INSERT #{modifier} INTO #{table} (#{Enum.join(columns, ",")}) VALUES " <>
          Enum.map_join(chunk, ",", fn _ -> tuple end) <> suffix,
        List.flatten(chunk)
      )
    end

    :ok
  end

  @doc false
  def query(conn, sql, args \\ []), do: Exqlite.query!(conn, sql, args, timeout: :infinity)

  @doc false
  def rows(conn, sql, args \\ []) do
    %{columns: cols, rows: rs} = query(conn, sql, args)
    keys = Enum.map(cols, &String.to_atom/1)
    Enum.map(rs, &(Enum.zip(keys, &1) |> Map.new()))
  end
end
