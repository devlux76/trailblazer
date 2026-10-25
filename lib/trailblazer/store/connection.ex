defmodule Trailblazer.Store.Connection do
  @moduledoc false
  use GenServer
  alias Trailblazer.{Anomaly, Events}

  def start_link(owner, db, mode, setup),
    do: GenServer.start_link(__MODULE__, {owner, db, mode, setup}, timeout: :infinity)

  @impl true
  def init({owner, db, mode, setup}) do
    {:ok, conn} =
      DBConnection.start_link(Trailblazer.Store.Driver,
        store_worker: self(),
        database: db,
        busy_timeout: 0,
        pool_size: 1,
        journal_mode: :wal,
        mode: if(mode == :read, do: :readonly, else: [:readwrite, :create]),
        backoff_type: :stop
      )

    {:ok, %{owner: owner, conn: conn, mode: mode, setup: setup, db: db}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, s) do
    if s.mode == :read,
      do: Exqlite.query!(s.conn, "PRAGMA query_only = ON", [], timeout: :infinity)

    :ok = s.setup.(s.conn)
    Exqlite.query!(s.conn, "SELECT 1", [], timeout: :infinity)
    {:noreply, s}
  end

  @impl true
  def handle_info({:sqlite_open, driver, raw, guardian}, s) do
    send(s.owner, {:connection_ready, self(), s.conn, driver, raw, guardian})
    {:noreply, s}
  end

  @impl true
  def handle_cast({:run, ref, fun}, s) do
    result =
      try do
        # DEFERRED also gives every multi-query read one WAL snapshot (J15).
        {:ok, value} = Exqlite.transaction(s.conn, fun, timeout: :infinity, mode: :deferred)
        if s.mode == :write, do: Events.publish(:store, {:committed, self(), ref})
        {:returned, value}
      catch
        kind, reason ->
          stack = __STACKTRACE__
          report_busy(reason, s)
          {:raised, kind, reason, stack}
      end

    send(s.owner, {:store_result, self(), ref, result})
    {:noreply, s}
  end

  @impl true
  def terminate(_, s) do
    if Process.alive?(s.conn), do: Supervisor.stop(s.conn, :normal, :infinity)
    :ok
  end

  defp report_busy(%Exqlite.Error{message: message}, s) do
    if String.contains?(String.downcase(message), ["busy", "locked"]) do
      Anomaly.report(:store_busy, {s.db, s.mode}, %{
        connection: inspect(self()),
        holder: :external_or_unknown,
        error: message
      })
    end
  end

  defp report_busy(_, _), do: :ok
end
