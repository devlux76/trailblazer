defmodule Trailblazer.Store.Driver do
  @moduledoc false
  use DBConnection

  @impl true
  def connect(opts) do
    writer? = Keyword.get(opts, :mode) != :readonly
    key = {:store_writer, Path.expand(Keyword.fetch!(opts, :database))}
    # A controller may die before its native transaction finishes cleanup.
    # Its replacement waits for the old cancellation owner, not a lock timer.
    if writer? do
      for {guardian, _} <- Registry.lookup(Trailblazer.Events, key) do
        ref = Process.monitor(guardian)
        receive do: ({:DOWN, ^ref, :process, ^guardian, _} -> :ok)
      end
    end

    with {:ok, state} <- Exqlite.Connection.connect(opts) do
      worker = Keyword.fetch!(opts, :store_worker)
      driver = self()
      raw = state.db
      # A dirty NIF may outlive the Erlang process killed inside it. Keep an
      # independent cancellation owner for abrupt worker/controller death.
      {guardian, guardian_ref} =
        spawn_monitor(fn ->
          worker_ref = Process.monitor(worker)
          driver_ref = Process.monitor(driver)
          if writer?, do: Registry.register(Trailblazer.Events, key, nil)
          send(driver, {:guardian_ready, self()})

          receive do
            {:DOWN, ^driver_ref, :process, ^driver, _} ->
              Exqlite.Sqlite3.cancel(raw)

            {:DOWN, ^worker_ref, :process, ^worker, _} ->
              Exqlite.Sqlite3.cancel(raw)
              receive do: ({:DOWN, ^driver_ref, :process, ^driver, _} -> :ok)
          end

          # A killed DBConnection process may skip disconnect/2. close_v2 may
          # retain live statement resources, so explicitly release the transaction.
          release_transaction(raw)

          :ok = Exqlite.Sqlite3.close(raw)
        end)

      receive do
        {:guardian_ready, ^guardian} ->
          Process.demonitor(guardian_ref, [:flush])

        {:DOWN, ^guardian_ref, :process, ^guardian, reason} ->
          raise "store cleanup owner exited: #{inspect(reason)}"
      end

      send(worker, {:sqlite_open, driver, raw, guardian})
      {:ok, state}
    end
  end

  @impl true
  def disconnect(reason, state) do
    Exqlite.Sqlite3.cancel(state.db)
    release_transaction(state.db)
    Exqlite.Connection.disconnect(reason, state)
  end

  defp release_transaction(raw) do
    case Exqlite.Sqlite3.transaction_status(raw) do
      {:ok, :transaction} -> :ok = Exqlite.Sqlite3.execute(raw, "ROLLBACK")
      _ -> :ok
    end
  end

  for {name, arity} <- [
        checkout: 1,
        ping: 1,
        handle_prepare: 3,
        handle_execute: 4,
        handle_begin: 2,
        handle_commit: 2,
        handle_rollback: 2,
        handle_close: 3,
        handle_declare: 4,
        handle_deallocate: 4,
        handle_fetch: 4,
        handle_status: 2
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)
    @impl true
    defdelegate unquote(name)(unquote_splicing(args)), to: Exqlite.Connection
  end
end
