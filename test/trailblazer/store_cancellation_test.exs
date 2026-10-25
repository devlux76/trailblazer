defmodule Trailblazer.StoreCancellationTest do
  use ExUnit.Case, async: false
  alias Trailblazer.{Backstop, Events, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "sql-cancel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    db = Path.join(dir, "graph.db")

    store =
      start_supervised!(
        {Store.Connections, name: __MODULE__.Local, db: db, setup: &Store.migrate/1}
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, store: store, db: db}
  end

  test "cancelling an executing native statement releases the writer lock", ctx do
    {task, _holder, ref} = running_query(ctx)
    send(Backstop, {:fire, ref})
    assert {:raised, :error, %RuntimeError{}, _} = Task.await(task, :infinity)
    assert_next_write(ctx.store)
  end

  test "abrupt controller death also cancels the native statement", ctx do
    Events.subscribe(:store)
    {task, _holder, _ref} = running_query(ctx)
    Process.exit(ctx.store, :kill)
    assert {:exit, _} = Task.await(task, :infinity)
    assert_receive {:trailblazer_event, :store, {:ready, replacement}}
    refute replacement == ctx.store
    assert_next_write(replacement)
  end

  test "unexpected lock contention fails immediately and records the unknown holder", ctx do
    Events.subscribe(:anomaly)
    {:ok, raw} = Exqlite.Sqlite3.open(ctx.db)

    try do
      :ok = Exqlite.Sqlite3.execute(raw, "BEGIN IMMEDIATE")

      assert {:returned, [[0]]} =
               request(ctx.store, :read, fn conn ->
                 Exqlite.query!(conn, "PRAGMA busy_timeout", [], timeout: :infinity).rows
               end)

      assert {:returned, [[1]]} =
               request(ctx.store, :read, fn conn ->
                 Exqlite.query!(conn, "PRAGMA query_only", [], timeout: :infinity).rows
               end)

      assert {:raised, :error, %Exqlite.Error{}, _} =
               request(ctx.store, :write, fn conn ->
                 Exqlite.query!(conn, "INSERT INTO repo(path) VALUES ('blocked')", [],
                   timeout: :infinity
                 )
               end)

      assert_receive {:trailblazer_event, :anomaly,
                      %{
                        kind: "store_busy",
                        evidence: %{holder: :external_or_unknown, connection: connection}
                      }}

      assert is_binary(connection)
    after
      Exqlite.Sqlite3.execute(raw, "ROLLBACK")
      Exqlite.Sqlite3.close(raw)
    end

    assert_next_write(ctx.store)
  end

  test "normal shutdown also closes all cleanup owners normally", ctx do
    guardians =
      :sys.get_state(ctx.store).workers |> Enum.map(fn {_, worker} -> worker.guardian end)

    monitors = Enum.map(guardians, &{&1, Process.monitor(&1)})
    stop_supervised!(Store.Connections)

    for {guardian, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^guardian, :normal}
    end
  end

  defp running_query(ctx) do
    Events.subscribe(:backstop)
    parent = self()

    task =
      Task.async(fn ->
        try do
          request(ctx.store, :write, fn conn ->
            Exqlite.query!(conn, "INSERT INTO repo(path) VALUES ('cancelled')", [],
              timeout: :infinity
            )

            send(parent, {:holding, self()})
            receive do: (:run_sql -> :ok)

            Exqlite.query!(
              conn,
              "WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<1000000000) SELECT sum(x) FROM c",
              [],
              timeout: :infinity
            )
          end)
        catch
          :exit, reason -> {:exit, reason}
        end
      end)

    assert_receive {:holding, holder}
    db = ctx.db
    assert_receive {:trailblazer_event, :backstop, {:armed, ref, :store_io, {^db, :write}, _}}
    :erlang.trace_pattern({Exqlite.Sqlite3NIF, :multi_step, 3}, true, [:local])
    # Trace arity only: keeping statement refs in a trace can prolong their lifetime.
    :erlang.trace(holder, true, [:call, :arity])

    on_exit(fn ->
      :erlang.trace_pattern({Exqlite.Sqlite3NIF, :multi_step, 3}, false, [:local])
    end)

    send(holder, :run_sql)
    assert_receive {:trace, ^holder, :call, {Exqlite.Sqlite3NIF, :multi_step, 3}}
    {task, holder, ref}
  end

  defp assert_next_write(store) do
    assert {:returned, _} =
             request(store, :write, fn conn ->
               Exqlite.query!(conn, "INSERT INTO repo(path) VALUES ('next')", [],
                 timeout: :infinity
               )
             end)

    assert {:returned, [["next"]]} =
             request(store, :read, fn conn ->
               Exqlite.query!(conn, "SELECT path FROM repo", [], timeout: :infinity).rows
             end)
  end

  defp request(store, mode, fun), do: GenServer.call(store, {:run, mode, fun}, :infinity)
end
