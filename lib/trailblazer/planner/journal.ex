defmodule Trailblazer.Planner.Journal do
  @moduledoc """
  The planning brain's durable fence: one row per board snapshot fingerprint,
  written on the existing cases.db store before each effect and after it.

  The row's state tells a restart what happened: `intent` holds a resource
  lease that may still be granted. Recovery confirms its release and may
  resume a retained, still-current choice without repeating the model; `unavailable` means the
  resource was busy and no inference ran (a later real event may retry), and
  `wait`, `error`, `interrupted`, `stale`, `dispatched` and `assign_failed` are
  terminal for that snapshot: the same board state is never planned for again
  automatically.
  """
  alias Trailblazer.CaseStore

  @table "planner_brain"

  def record(fingerprint, lease, state, ref, reason) do
    CaseStore.transaction(fn conn ->
      schema(conn)

      query(
        conn,
        :planner_brain_put,
        "INSERT OR REPLACE INTO #{@table} (fingerprint, lease, state, ref, reason, at) VALUES (?, ?, ?, ?, ?, ?)",
        [fingerprint, lease, state, ref, reason, System.os_time(:millisecond)]
      )

      :ok
    end)
  end

  @doc "The row for a snapshot fingerprint, or nil."
  def get(fingerprint) do
    CaseStore.transaction(fn conn ->
      schema(conn)

      case rows(
             conn,
             "SELECT fingerprint, lease, state, ref, reason, at FROM #{@table} WHERE fingerprint = ?",
             [
               fingerprint
             ]
           ) do
        [row] -> row
        [] -> nil
      end
    end)
  end

  @doc "The most recently written row, or nil."
  def latest do
    CaseStore.transaction(fn conn ->
      schema(conn)

      case rows(
             conn,
             "SELECT fingerprint, lease, state, ref, reason, at FROM #{@table} ORDER BY rowid DESC LIMIT 1",
             []
           ) do
        [row] -> row
        [] -> nil
      end
    end)
  end

  @doc "Rows whose resource lease was never confirmed released."
  def unresolved do
    CaseStore.transaction(fn conn ->
      schema(conn)

      rows(
        conn,
        "SELECT fingerprint, lease, state, ref, reason, at FROM #{@table} WHERE state = 'intent'",
        []
      )
    end)
  end

  defp schema(conn),
    do:
      query(
        conn,
        :planner_brain_schema,
        "CREATE TABLE IF NOT EXISTS #{@table} (fingerprint TEXT PRIMARY KEY, lease TEXT NOT NULL, state TEXT NOT NULL, ref TEXT, reason TEXT NOT NULL, at INTEGER NOT NULL)",
        []
      )

  defp rows(conn, sql, params) do
    {_query, %Exqlite.Result{columns: columns, rows: rows}} =
      Exqlite.prepare_execute!(conn, :planner_brain, sql, params, timeout: :infinity)

    keys = Enum.map(columns, &String.to_existing_atom/1)
    Enum.map(rows, fn row -> keys |> Enum.zip(row) |> Map.new() end)
  end

  defp query(conn, name, sql, params) do
    {_, %Exqlite.Result{rows: rows}} =
      Exqlite.prepare_execute!(conn, name, sql, params, timeout: :infinity)

    rows || []
  end
end
