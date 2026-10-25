defmodule Trailblazer.CaseStore do
  @moduledoc """
  Case records' own database, `cases.db` in the state directory, with its own
  connection process.

  They lived in the graph's database and went through the Store's one
  connection, so every step of a running task waited behind indexing: with a
  large repository being re-watched, `trailblazer run` timed out opening its
  case and the CLI printed nothing (E23). Case records share nothing with the
  graph, so a separate file also keeps SQLite's write lock apart.
  """
  use GenServer

  alias Trailblazer.{Backstop, Config}

  @schema_path Path.expand("../../priv/migrations/002_cases.sql", __DIR__)
  @external_resource @schema_path
  @schema File.read!(@schema_path)

  # Case writes are small; they wait for the database however long it takes,
  # under one backstop per call (design §13.2).

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Records a new case; `{:error, :exists}` when the id is taken."
  def case_insert(id, repo, task_json, opened_at) do
    run(fn conn ->
      case rows(conn, :case_status, "SELECT status FROM task_case WHERE id = ?", [id]) do
        [] ->
          write(
            conn,
            :case_insert,
            "INSERT INTO task_case (id, repo, task, opened_at) VALUES (?, ?, ?, ?)",
            [id, repo, task_json, opened_at]
          )

        [_] ->
          {:error, :exists}
      end
    end)
  end

  @doc """
  Appends an event to an open case and gives `{:ok, seq}`. When `close` is `{status, report_json}`,
  the case is closed by the same transaction, so a report event and the case's
  final status land together or not at all.
  """
  def case_append(id, kind, at, data_json, close \\ nil) do
    run(fn conn ->
      case rows(conn, :case_status, "SELECT status FROM task_case WHERE id = ?", [id]) do
        [] ->
          {:error, :no_case}

        [%{status: "open"}] ->
          {:ok, seq} =
            Exqlite.transaction(
              conn,
              fn conn ->
                [%{seq: seq}] =
                  rows(
                    conn,
                    :case_next_seq,
                    "SELECT COALESCE(MAX(seq), 0) + 1 AS seq FROM case_event WHERE case_id = ?",
                    [id]
                  )

                write(
                  conn,
                  :case_event_insert,
                  "INSERT INTO case_event (case_id, seq, kind, at, data) VALUES (?, ?, ?, ?, ?)",
                  [id, seq, kind, at, data_json]
                )

                with {status, report_json} <- close do
                  write(
                    conn,
                    :case_close,
                    "UPDATE task_case SET status = ?, report = ?, closed_at = ? WHERE id = ?",
                    [status, report_json, at, id]
                  )
                end

                seq
              end,
              timeout: :infinity
            )

          {:ok, seq}

        [_closed] ->
          {:error, :closed}
      end
    end)
  end

  @doc "A case's row and its events in order, or nil."
  def case_get(id) do
    run(fn conn ->
      case rows(conn, :case_get, "SELECT * FROM task_case WHERE id = ?", [id]) do
        [row] ->
          events =
            rows(
              conn,
              :case_events,
              "SELECT seq, kind, at, data FROM case_event WHERE case_id = ? ORDER BY seq",
              [id]
            )

          Map.put(row, :events, events)

        [] ->
          nil
      end
    end)
  end

  @doc "A case's events after `seq`, in order (for a follower catching up, J2)."
  def case_events_after(id, seq) do
    run(fn conn ->
      rows(
        conn,
        :case_events_after,
        "SELECT seq, kind, at, data FROM case_event WHERE case_id = ? AND seq > ? ORDER BY seq",
        [id, seq]
      )
    end)
  end

  @doc "Ids of the cases not closed, oldest first."
  def case_open_ids do
    run(fn conn ->
      conn
      |> rows(
        :case_open_ids,
        "SELECT id FROM task_case WHERE status = 'open' ORDER BY opened_at, id"
      )
      |> Enum.map(& &1.id)
    end)
  end

  @doc "Runs a short domain transaction on cases.db's serialized connection."
  def transaction(fun) do
    run(fn conn ->
      {:ok, result} = Exqlite.transaction(conn, fun, timeout: :infinity)
      result
    end)
  end

  # Lazy DDL also works when this module is hot-loaded into an existing store.
  def lifecycle_get(id) do
    run(fn conn ->
      lifecycle_schema(conn)

      case rows(
             conn,
             :lifecycle_get,
             "SELECT version, record FROM repair_lifecycle WHERE case_id = ?",
             [id]
           ) do
        [] -> nil
        [%{record: json}] -> Jason.decode!(json)
      end
    end)
  end

  def lifecycle_cas(id, expected, record) do
    run(fn conn ->
      lifecycle_schema(conn)

      current =
        rows(conn, :lifecycle_version, "SELECT version FROM repair_lifecycle WHERE case_id = ?", [
          id
        ])

      version =
        case current do
          [] -> 0
          [%{version: v}] -> v
        end

      if version != expected do
        {:error, :conflict}
      else
        next = Map.put(record, "version", version + 1)

        write(
          conn,
          :lifecycle_put,
          "INSERT INTO repair_lifecycle (case_id, version, record) VALUES (?, ?, ?) ON CONFLICT(case_id) DO UPDATE SET version = excluded.version, record = excluded.record",
          [id, version + 1, Jason.encode!(next)]
        )

        {:ok, next}
      end
    end)
  end

  defp lifecycle_schema(conn),
    do:
      write(
        conn,
        :lifecycle_schema,
        "CREATE TABLE IF NOT EXISTS repair_lifecycle (case_id TEXT PRIMARY KEY, version INTEGER NOT NULL, record TEXT NOT NULL)"
      )

  ## Anomalies (design §13.5)

  @doc """
  Records an anomaly, or counts it again while one of the same kind and
  subject is open (J6): `{:new, id}` or `{:repeat, id, count}`. One call, so
  two reports of one fault cannot both open a row.
  """
  def anomaly_report(kind, subject, evidence_json, load_json, at) do
    run(fn conn ->
      open =
        rows(
          conn,
          :anomaly_open,
          "SELECT id, count FROM anomaly WHERE kind = ? AND subject = ? AND acked_at IS NULL",
          [kind, subject]
        )

      case open do
        [%{id: id, count: count}] ->
          write(conn, :anomaly_bump, "UPDATE anomaly SET count = ?, last_at = ? WHERE id = ?", [
            count + 1,
            at,
            id
          ])

          {:repeat, id, count + 1}

        [] ->
          write(
            conn,
            :anomaly_insert,
            "INSERT INTO anomaly (kind, subject, evidence, load, at, last_at) VALUES (?, ?, ?, ?, ?, ?)",
            [kind, subject, evidence_json, load_json, at, at]
          )

          [%{id: id}] = rows(conn, :last_id, "SELECT last_insert_rowid() AS id")
          {:new, id}
      end
    end)
  end

  @doc "Anomalies, newest first; `open: true` leaves out acknowledged ones."
  def anomaly_list(open?) do
    where = if open?, do: " WHERE acked_at IS NULL", else: ""

    run(fn conn ->
      rows(conn, :anomaly_list, "SELECT * FROM anomaly#{where} ORDER BY id DESC")
    end)
  end

  def anomaly_mark_sent(id) do
    run(&write(&1, :anomaly_sent, "UPDATE anomaly SET sent = 1 WHERE id = ?", [id]))
  end

  @doc "`:ok`, or `{:error, :no_anomaly}` when no open anomaly has that id."
  def anomaly_ack(id, at) do
    run(fn conn ->
      case rows(conn, :anomaly_get, "SELECT id FROM anomaly WHERE id = ? AND acked_at IS NULL", [
             id
           ]) do
        [_] -> write(conn, :anomaly_ack, "UPDATE anomaly SET acked_at = ? WHERE id = ?", [at, id])
        [] -> {:error, :no_anomaly}
      end
    end)
  end

  @impl GenServer
  def init(opts) do
    db = Keyword.get(opts, :db) || Path.join(Config.get(:state_dir), "cases.db")
    File.mkdir_p!(Path.dirname(db))
    {:ok, conn} = Exqlite.start_link(database: db, pool_size: 1)

    for statement <- statements(@schema), do: write(conn, :schema, statement)

    {:ok, conn}
  end

  @impl GenServer
  def handle_call({:run, fun}, _from, conn), do: {:reply, fun.(conn), conn}

  # The call waits for the store (it monitors it, so the store's death is an
  # answer); a backstop reports one that stops answering. Without a running
  # Backstop (it is restarting) the call goes ahead unguarded: case records
  # never depend on the watchdog.
  defp run(fun) do
    backstop =
      if Process.whereis(Backstop),
        do: Backstop.arm(:case_store, "cases.db", {:ms, Config.get(:backstop_store_ms)})

    result = GenServer.call(__MODULE__, {:run, fun}, :infinity)

    case backstop && Backstop.disarm(backstop) do
      :fired ->
        receive do
          {:backstop, ^backstop, _id} -> result
        end

      _ ->
        result
    end
  end

  defp statements(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "--"))
    |> Enum.join("\n")
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp write(conn, name, statement, params \\ []) do
    {_query, _result} =
      Exqlite.prepare_execute!(conn, name, statement, params, timeout: :infinity)

    :ok
  end

  defp rows(conn, name, statement, params \\ []) do
    {_query, %Exqlite.Result{columns: columns, rows: rows}} =
      Exqlite.prepare_execute!(conn, name, statement, params, timeout: :infinity)

    keys = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows, fn row -> keys |> Enum.zip(row) |> Map.new() end)
  end
end
