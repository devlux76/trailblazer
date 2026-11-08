defmodule Trailblazer.Planner.Research.Journal do
  @moduledoc "The research journal on cases.db: the table's DDL, the row reads and the row writes."

  alias Trailblazer.CaseStore

  @table "planner_research"
  @closed ~w(researched blocked)

  @doc false
  def row_of(ref),
    do:
      CaseStore.transaction(fn conn ->
        schema(conn)
        rowof(conn, ref)
      end)

  def schema(conn),
    do:
      query(
        conn,
        :planner_research_schema,
        "CREATE TABLE IF NOT EXISTS #{@table} (ref TEXT PRIMARY KEY, lease TEXT NOT NULL, state TEXT NOT NULL, conference TEXT, children TEXT, children_done INTEGER NOT NULL, reason TEXT NOT NULL, at INTEGER NOT NULL)",
        []
      )

  @doc false
  def record(ref, state, reason, conference \\ nil, extra \\ []) do
    CaseStore.transaction(fn conn ->
      schema(conn)
      existing = rowof(conn, ref) || %{}

      children_text =
        Jason.encode!(Keyword.get(extra, :children) || Map.get(existing, :children) || [])

      done =
        Keyword.get(extra, :children_done) ||
          (existing[:children_done] && Map.get(existing, :children_done)) || 0

      query(
        conn,
        :planner_research_put,
        "INSERT OR REPLACE INTO #{@table} (ref, lease, state, conference, children, children_done, reason, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [
          ref,
          existing[:lease] || "",
          state,
          conference || (existing[:conference] || nil),
          children_text,
          done,
          String.slice(reason || "", 0, 900),
          System.os_time(:millisecond)
        ]
      )

      :ok
    end)
  end

  @doc false
  def rows(conn) do
    schema(conn)

    for [ref, lease, state, conference, children, done, reason, at] <-
          query(
            conn,
            :planner_research_rows,
            "SELECT ref, lease, state, conference, children, children_done, reason, at FROM #{@table} ORDER BY rowid",
            []
          ) do
      %{
        ref: ref,
        lease: lease,
        state: state,
        conference: conference,
        children: decode_children(children),
        children_done: done,
        reason: reason,
        at: at
      }
    end
  end

  defp rowof(conn, ref), do: Enum.find(rows(conn), &(&1.ref == ref))

  defp decode_children(""), do: []
  defp decode_children(nil), do: []

  defp decode_children(text) do
    case Jason.decode!(text) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp query(conn, name, sql, params) do
    {_query, %Exqlite.Result{rows: rows}} =
      Exqlite.prepare_execute!(conn, name, sql, params, timeout: :infinity)

    rows || []
  end

  @doc false
  def finished?(ref) do
    case row_of(ref) do
      %{state: state} -> state in @closed
      _ -> false
    end
  end

  @doc false
  def journal_state(ref) do
    case row_of(ref) do
      %{state: state} -> state
      _ -> "none"
    end
  end
end
