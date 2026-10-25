defmodule Trailblazer.StoreIOTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Store

  test "a WAL read answers while an uncommitted writer batch is held" do
    parent = self()
    path = "/tmp/trailblazer-held-write-#{System.unique_integer([:positive])}"

    writer =
      Task.async(fn ->
        GenServer.call(
          Store,
          {:run, :write,
           fn conn ->
             {:ok, :ok} =
               Exqlite.transaction(
                 conn,
                 fn tx ->
                   Exqlite.query!(tx, "INSERT INTO repo(path) VALUES (?)", [path],
                     timeout: :infinity
                   )

                   send(parent, {:writer_held, self()})
                   receive do: (:release -> :ok)
                 end,
                 timeout: :infinity
               )

             :ok
           end},
          :infinity
        )
      end)

    assert_receive {:writer_held, holder}
    on_exit(fn -> if Process.alive?(writer.pid), do: send(holder, :release) end)
    reader = Task.async(fn -> send(parent, {:read_answer, Store.repos()}) end)
    assert_receive {:read_answer, rows}
    refute Enum.any?(rows, &(&1.path == path))
    send(holder, :release)
    assert {:returned, :ok} = Task.await(writer, :infinity)
    Task.await(reader, :infinity)
    assert Enum.any?(Store.repos(), &(&1.path == path))
  end

  test "replaying a file or edge batch keeps reference and edge identities" do
    {:ok, repo} = Store.add_repo("/tmp/replay-#{System.unique_integer([:positive])}")
    {:ok, other} = Store.add_repo("/tmp/replay-other-#{System.unique_integer([:positive])}")
    source = "defmodule Replay do\n def f(), do: g()\n def g(), do: :ok\nend\n"
    {:ok, parsed} = Trailblazer.Parse.Elixir.parse("a.ex", source)
    batch = Map.put(parsed, :hash, "same")
    :ok = Store.replace_file(repo, "a.ex", batch)
    snapshot = Store.graph_snapshot(repo)
    [node | _] = snapshot.nodes
    edge = %{from_id: node.id, to_id: node.id, kind: "calls", uncertain: false}
    :ok = Store.put_edges(repo, [edge])
    edges = Store.edges_from(node.id)
    # Another producer advances the global row ids before the original retries.
    :ok = Store.replace_file(other, "a.ex", batch)
    [other_node | _] = Store.graph_snapshot(other).nodes
    :ok = Store.put_edges(other, [%{edge | from_id: other_node.id, to_id: other_node.id}])
    :ok = Supervisor.terminate_child(Trailblazer.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(Trailblazer.Supervisor, Store)
    :ok = Store.replace_file(repo, "a.ex", batch)
    assert Store.graph_snapshot(repo) == snapshot
    :ok = Store.put_edges(repo, [edge])
    assert Store.edges_from(node.id) == edges
  end

  test "stale recovery and a new parser payload invalidate the previous receipt" do
    {:ok, repo} = Store.add_repo("/tmp/replay-stale-#{System.unique_integer([:positive])}")

    {:ok, parsed} =
      Trailblazer.Parse.Elixir.parse("a.ex", "defmodule Replay do\n def f(), do: :ok\nend\n")

    batch = Map.put(parsed, :hash, "same")
    :ok = Store.replace_file(repo, "a.ex", batch)
    :ok = Store.mark_stale(repo, "a.ex")
    assert Enum.all?(Store.graph_snapshot(repo).nodes, & &1.stale)
    :ok = Store.replace_file(repo, "a.ex", batch)
    refute Enum.any?(Store.graph_snapshot(repo).nodes, & &1.stale)

    changed = %{
      batch
      | nodes: Enum.map(batch.nodes, &Map.put(&1, :signature, "new parser signature"))
    }

    :ok = Store.replace_file(repo, "a.ex", changed)
    assert Enum.all?(Store.graph_snapshot(repo).nodes, &(&1.signature == "new parser signature"))
    :ok = Store.delete_file(repo, "a.ex")
    assert Store.graph_snapshot(repo).nodes == []
    :ok = Store.replace_file(repo, "a.ex", changed)
    assert Store.graph_snapshot(repo).nodes != []
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "store-io-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    db = Path.join(dir, "graph.db")

    store =
      start_supervised!(
        {Trailblazer.Store.Connections, name: __MODULE__.Local, db: db, setup: &Store.migrate/1}
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, local: store, db: db}
  end

  test "a multi-query reader keeps its WAL snapshot while a writer commits", %{local: store} do
    assert {:returned, _} =
             request(store, :write, fn conn ->
               Exqlite.query!(conn, "INSERT INTO repo(path) VALUES ('old')", [],
                 timeout: :infinity
               )
             end)

    parent = self()

    reader =
      Task.async(fn ->
        request(store, :read, fn conn ->
          before = Exqlite.query!(conn, "SELECT path FROM repo", [], timeout: :infinity).rows
          send(parent, {:snapshot_held, self()})
          receive do: (:release -> :ok)
          after_write = Exqlite.query!(conn, "SELECT path FROM repo", [], timeout: :infinity).rows
          {before, after_write}
        end)
      end)

    assert_receive {:snapshot_held, holder}
    on_exit(fn -> if Process.alive?(reader.pid), do: send(holder, :release) end)

    assert {:returned, _} =
             request(store, :write, fn conn ->
               Exqlite.query!(conn, "UPDATE repo SET path = 'new'", [], timeout: :infinity)
             end)

    # The second reader is independent of the held snapshot.
    assert {:returned, [["new"]]} =
             request(store, :read, fn conn ->
               Exqlite.query!(conn, "SELECT path FROM repo", [], timeout: :infinity).rows
             end)

    send(holder, :release)
    assert {:returned, {[["old"]], [["old"]]}} = Task.await(reader, :infinity)
  end

  test "read connections reject writes and keep serving after a failed transaction", %{
    local: store
  } do
    assert {:raised, :error, %Exqlite.Error{}, _} =
             request(store, :read, fn conn ->
               Exqlite.query!(conn, "INSERT INTO repo(path) VALUES ('forbidden')", [],
                 timeout: :infinity
               )
             end)

    assert {:returned, []} =
             request(store, :read, fn conn ->
               Exqlite.query!(conn, "SELECT path FROM repo", [], timeout: :infinity).rows
             end)
  end

  test "a backstop rolls back its writer and the queued batch resumes", %{local: store, db: db} do
    Trailblazer.Events.subscribe(:backstop)
    parent = self()

    held =
      Task.async(fn ->
        request(store, :write, fn conn ->
          Exqlite.query!(conn, "INSERT INTO repo(path) VALUES ('cancelled')", [],
            timeout: :infinity
          )

          send(parent, {:held, self()})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:held, holder}
    assert_receive {:trailblazer_event, :backstop, {:armed, ref, :store_io, {^db, :write}, _}}

    next =
      Task.async(fn ->
        request(store, :write, fn conn ->
          Exqlite.query!(conn, "INSERT INTO repo(path) VALUES ('next')", [], timeout: :infinity)
        end)
      end)

    monitor = Process.monitor(holder)
    send(Trailblazer.Backstop, {:fire, ref})
    assert {:raised, :error, %RuntimeError{message: message}, _} = Task.await(held, :infinity)
    assert message =~ "store_backstop"
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}
    assert {:returned, _} = Task.await(next, :infinity)

    assert {:returned, [["next"]]} =
             request(store, :read, fn conn ->
               Exqlite.query!(conn, "SELECT path FROM repo", [], timeout: :infinity).rows
             end)
  end

  test "a caller dying cancels its uncommitted work", %{local: store} do
    parent = self()

    caller =
      spawn(fn ->
        request(store, :write, fn conn ->
          Exqlite.query!(conn, "INSERT INTO repo(path) VALUES ('abandoned')", [],
            timeout: :infinity
          )

          send(parent, {:held, self()})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:held, holder}
    monitor = Process.monitor(holder)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}

    assert {:returned, _} =
             request(store, :write, fn conn ->
               Exqlite.query!(conn, "INSERT INTO repo(path) VALUES ('kept')", [],
                 timeout: :infinity
               )
             end)

    assert {:returned, [["kept"]]} =
             request(store, :read, fn conn ->
               Exqlite.query!(conn, "SELECT path FROM repo", [], timeout: :infinity).rows
             end)
  end

  test "a commit survives controller death before acknowledgement", %{local: store} do
    Trailblazer.Events.subscribe(:store)
    parent = self()

    caller =
      spawn(fn ->
        try do
          request(store, :write, fn conn ->
            Exqlite.query!(conn, "INSERT INTO repo(path) VALUES ('committed')", [],
              timeout: :infinity
            )

            send(parent, {:held, self()})
            receive do: (:release -> :ok)
          end)
        catch
          :exit, reason -> send(parent, {:caller_exit, reason})
        end
      end)

    assert_receive {:held, holder}
    :sys.suspend(store)
    send(holder, :release)
    assert_receive {:trailblazer_event, :store, {:committed, ^holder, _}}
    # The controller has not consumed the result or acknowledged the writer.
    Process.exit(store, :kill)
    assert_receive {:caller_exit, _}
    assert_receive {:trailblazer_event, :store, {:ready, replacement}}
    refute replacement == store

    assert {:returned, [["committed"]]} =
             request(replacement, :read, fn conn ->
               Exqlite.query!(conn, "SELECT path FROM repo", [], timeout: :infinity).rows
             end)

    refute Process.alive?(caller)
  end

  defp request(store, mode, fun), do: GenServer.call(store, {:run, mode, fun}, :infinity)
end
