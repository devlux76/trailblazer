defmodule Trailblazer.IndexerRestoreTest do
  use ExUnit.Case, async: false
  alias Trailblazer.{Indexer, Store, Files}

  defmodule Embed do
    def documents(docs, opts) do
      send(opts[:observer], {:embedded, self(), docs})
      if opts[:gate], do: receive(do: (:continue -> :ok))
      if opts[:down], do: {:error, :embedder_down}, else: {:ok, Enum.map(docs, fn _ -> [1.0] end)}
    end
  end

  defmodule Vectors do
    def ensure(_, _), do: :ok

    def put(_, points, opts) do
      send(opts[:observer], {:points, points})
      if opts[:vectors_down], do: {:error, :qdrant_down}, else: :ok
    end

    def delete(_, [], _), do: :ok

    def delete(_, ids, opts) do
      send(opts[:observer], {:deleted, ids})
      if opts[:vectors_down], do: {:error, :qdrant_down}, else: :ok
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "trailblazer-index-#{System.unique_integer([:positive])}")
    File.cp_r!(Path.expand("../fixtures/mini", __DIR__), root)

    on_exit(fn ->
      if pid = Indexer.whereis(root), do: GenServer.stop(pid)
      File.rm_rf!(root)
    end)

    %{
      root: root,
      opts: [
        embed: Embed,
        vectors: Vectors,
        observer: self(),
        filesystem: false,
        embedding: :paused
      ]
    }
  end

  # J27, operator 2026-10-19: a restart must not full-sync every repository
  # never indexed; each waits for its first git change or request.
  test "J27: a deferred watch reads and embeds nothing until asked", %{
    root: root,
    opts: opts
  } do
    {:ok, _} = Indexer.watch(root, Keyword.put(opts, :defer, true))
    {:ok, repo} = Store.add_repo(root)

    assert %{deferred: true, nodes: 0, syncing: false, embedding: :paused} =
             Indexer.status(root)

    # a watcher restart's resync does not wake it
    {:ok, canonical} = Files.canonical_path(root)
    Trailblazer.Events.subscribe({:repo, canonical})
    send(Indexer.whereis(root), {:watcher_resync, self()})
    assert_receive {:trailblazer_event, _, %{event: :watcher_resynced}}
    assert %{deferred: true, syncing: false, nodes: 0} = Indexer.status(root)

    assert Store.files(repo) == []

    assert {:ok, _} = Indexer.fresh(root)
    assert %{deferred: false, nodes: nodes} = Indexer.status(root)
    assert nodes > 0
    assert Store.files(repo) != []
  end

  test "watched repos restore after supervisor restart and missing paths retain their graph", %{
    root: root,
    opts: opts
  } do
    {:ok, repo} = Store.add_repo(root)
    refute Enum.any?(Store.watched_repos(), &(&1.id == repo))
    {:ok, pid} = Indexer.watch(root, opts)
    assert Enum.any?(Store.watched_repos(), &(&1.id == repo))
    before = Store.graph_snapshot(repo).nodes
    prior = Application.fetch_env(:trailblazer, :restore_watch_opts)
    Application.put_env(:trailblazer, :restore_watch_opts, opts)

    on_exit(fn ->
      if is_nil(Process.whereis(Trailblazer.Indexer.Supervisor)),
        do: Supervisor.restart_child(Trailblazer.Supervisor, Trailblazer.Indexer.Supervisor)

      case prior do
        {:ok, value} -> Application.put_env(:trailblazer, :restore_watch_opts, value)
        :error -> Application.delete_env(:trailblazer, :restore_watch_opts)
      end
    end)

    :ok = Supervisor.terminate_child(Trailblazer.Supervisor, Trailblazer.Indexer.Supervisor)
    {:ok, _} = Supervisor.restart_child(Trailblazer.Supervisor, Trailblazer.Indexer.Supervisor)
    eventually(fn -> is_pid(Indexer.whereis(root)) and Indexer.whereis(root) != pid end)

    conn =
      Plug.Test.conn(:post, "/status", Jason.encode!(%{repo: root}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer restored-test")
      |> Trailblazer.API.call(Trailblazer.API.init(token: "restored-test"))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["nodes"] == length(before)
    File.rm_rf!(root)

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = Supervisor.terminate_child(Trailblazer.Supervisor, Trailblazer.Indexer.Supervisor)

        {:ok, _} =
          Supervisor.restart_child(Trailblazer.Supervisor, Trailblazer.Indexer.Supervisor)

        :sys.get_state(Trailblazer.Indexer.Restore)
      end)

    assert logs =~ root
    refute Indexer.watched?(root)
    assert Enum.any?(Store.watched_repos(), &(&1.id == repo))
    assert Store.graph_snapshot(repo).nodes == before
  end

  # E16, found on the deployed service: one file that crashed the Elixir
  # parser took mirai-agent's whole indexer down, then the restore with it.
  test "E16: a parser that raises on one file marks that file stale, and the rest index", %{
    root: root,
    opts: opts
  } do
    real = fn path, lang, source ->
      if path == "lib/app.ex",
        do: raise(CaseClauseError, term: nil),
        else: Trailblazer.Indexer.parse_file(path, lang, source)
    end

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = Indexer.watch(root, Keyword.put(opts, :parse, real))
      end)

    assert logs =~ "lib/app.ex"
    status = Indexer.status(root)
    assert status.stale_files == 1
    {:ok, repo} = Store.add_repo(root)
    assert Store.nodes_by_qualified(repo, "saveHikes") != []
  end

  test "E16: an exception in a whole sync is an error, not a crash", %{root: root, opts: opts} do
    opts = Keyword.put(opts, :list_files, fn _ -> raise ArgumentError, "boom" end)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, _} = Indexer.watch(root, opts)
    end)

    refute Indexer.watched?(root)
  end

  # A watch that raises is caught inside the sync; one whose indexer exits
  # reaches Restore as an exit (its catch branch, from Codex's review of a90709e).
  for how <- [:raise, :exit] do
    @how how
    test "E16: restore skips a repository whose watch fails and restores the rest (#{how})", %{
      root: root,
      opts: opts
    } do
      other = root <> "-other"
      File.cp_r!(root, other)
      on_exit(fn -> File.rm_rf!(other) end)

      {:ok, _} = Indexer.watch(root, opts)
      {:ok, _} = Indexer.watch(other, opts)

      bad = Path.expand(root)

      # a watch that syncs at boot (J27 defers only never-indexed ones)
      restore_opts =
        opts
        |> Keyword.put(:defer, false)
        |> Keyword.put(:list_files, fn path ->
          if Path.expand(path) == bad,
            do: fail(@how),
            else: Trailblazer.Files.list(path)
        end)

      prior = Application.fetch_env(:trailblazer, :restore_watch_opts)
      Application.put_env(:trailblazer, :restore_watch_opts, restore_opts)

      on_exit(fn ->
        if is_nil(Process.whereis(Trailblazer.Indexer.Supervisor)),
          do: Supervisor.restart_child(Trailblazer.Supervisor, Trailblazer.Indexer.Supervisor)

        case prior do
          {:ok, value} -> Application.put_env(:trailblazer, :restore_watch_opts, value)
          :error -> Application.delete_env(:trailblazer, :restore_watch_opts)
        end
      end)

      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok = Supervisor.terminate_child(Trailblazer.Supervisor, Trailblazer.Indexer.Supervisor)

          {:ok, _} =
            Supervisor.restart_child(Trailblazer.Supervisor, Trailblazer.Indexer.Supervisor)

          :sys.get_state(Trailblazer.Indexer.Restore)
        end)

      assert logs =~ root
      assert Indexer.watched?(other)
      refute Indexer.watched?(root)
      assert Process.alive?(Process.whereis(Trailblazer.Indexer.Restore))
    end
  end

  defp fail(:raise), do: raise(ArgumentError, "boom")
  defp fail(:exit), do: exit(:boom)

  test "a failed first watch is not persisted", %{root: root, opts: opts} do
    path = root <> "/missing"
    assert {:error, _} = Indexer.watch(path, opts)
    refute Enum.any?(Store.watched_repos(), &(&1.path == path))
  end

  # E12, found on the deployed service: without inotify-tools the watcher does
  # not start and changes were never followed. The indexer polls instead, and
  # says so.
  # Design §13.7: a repository without a live watch is only colder; a request
  # reconciles it first, and nothing polls.
  test "E12: with no file watcher, a request still sees the change", %{root: root, opts: opts} do
    git_init(root)

    opts =
      Keyword.merge(opts,
        filesystem: true,
        start_watcher: fn _path -> :ignore end
      )

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _pid} = Indexer.watch(root, opts)
      end)

    assert logs =~ "when the next request reconciles from git"
    assert Indexer.status(root).following == :on_request
    assert Indexer.status(root).watch_error =~ ":ignore"

    File.write!(Path.join(root, "web/probe.ts"), "export function probeFn() { return 1; }\n")
    {:ok, repo} = Store.add_repo(root)
    assert {:ok, %{generation: g}} = Indexer.fresh(root)
    assert g >= 2
    assert Store.nodes_by_qualified(repo, "probeFn") != []
  end

  test "following is :off when watching is disabled", %{root: root, opts: opts} do
    {:ok, _} = Indexer.watch(root, opts)
    assert Indexer.status(root).following == :off
  end

  # Codex's review of e6ac1ba: when inotify exits, file_system sends
  # {:file_event, watcher, :stop} and its worker stays alive, so following
  # still said :events while nothing was followed. Its :stop is a failure.
  test "E12: after a watcher stops, a request still sees the change", %{root: root, opts: opts} do
    git_init(root)
    watcher = spawn(fn -> receive do: (:done -> :ok) end)

    opts =
      Keyword.merge(opts,
        filesystem: true,
        start_watcher: fn _path -> {:ok, watcher} end,
        subscribe_watcher: fn _pid -> :ok end
      )

    {:ok, _pid} = Indexer.watch(root, opts)
    assert Indexer.status(root).following == :events

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        send(Trailblazer.Watcher, {:file_event, watcher, :stop})
        eventually(fn -> Indexer.status(root).following == :on_request end, 1000)
      end)

    assert logs =~ "when the next request reconciles from git"

    File.write!(
      Path.join(root, "web/afterStop.ts"),
      "export function afterStop() { return 1; }\n"
    )

    {:ok, repo} = Store.add_repo(root)
    assert {:ok, _} = Indexer.fresh(root)
    assert Store.nodes_by_qualified(repo, "afterStop") != []

    # another watcher's stop changes nothing
    send(Trailblazer.Watcher, {:file_event, spawn(fn -> :ok end), :stop})
    assert Indexer.status(root).following == :on_request
    Process.exit(watcher, :kill)
  end

  test "embedding drains the newest repo first and sync refreshes priority",
       %{root: root, opts: opts} do
    older = root <> "-older"
    File.mkdir_p!(older)

    on_exit(fn ->
      if pid = Indexer.whereis(older), do: GenServer.stop(pid)
      File.rm_rf!(older)
    end)

    # Enough nodes for several batches, with deterministic mtime priorities.
    source =
      "defmodule Many do\n" <> Enum.map_join(1..40, "\n", &"def f#{&1}(), do: #{&1}") <> "\nend\n"

    File.write!(Path.join(older, "many.ex"), source)
    old_time = 1_600_000_000
    new_time = old_time + 100
    File.touch!(Path.join(older, "many.ex"), old_time)
    for file <- Files.list(root), do: File.touch!(Path.join(root, file.path), new_time)
    opts = Keyword.put(opts, :gate, true)
    {:ok, _} = Indexer.watch(older, opts)
    {:ok, _} = Indexer.watch(root, opts)
    assert Indexer.status(older).embed_priority == old_time
    assert Indexer.status(root).embed_priority == new_time

    # Hold the shared permit while both repos enqueue their first batches.
    :ok = Trailblazer.EmbedGate.update(0, false)
    :ok = Trailblazer.EmbedGate.acquire(self())
    :ok = Indexer.resume_embedding(older)
    :ok = Indexer.resume_embedding(root)
    eventually(fn -> Indexer.status(root).embedding == :queued end)
    assert Indexer.status(older).embedding == :queued
    :ok = Trailblazer.EmbedGate.release()
    drain_repo(root)
    drain_repo(older)

    # Change only mtime, preserving hashes: a sync must still refresh priority.
    File.touch!(Path.join(older, "many.ex"), new_time + 100)
    assert {:ok, %{parsed: 0}} = Indexer.sync(older)
    assert Indexer.status(older).embed_priority == new_time + 100
  end

  defp drain_repo(root) do
    if Indexer.status(root).pending_vectors > 0 do
      assert_receive {:embedded, job, docs}, 2000
      [{title, _} | _] = docs
      # The synthetic older repo contains only the Many module and its functions.
      if String.ends_with?(root, "-older"),
        do: assert(String.starts_with?(title, "Many")),
        else: refute(String.starts_with?(title, "Many"))

      send(job, :continue)
      assert_receive {:points, _}, 1000

      eventually(fn ->
        case :sys.get_state(Indexer.whereis(root)).job do
          {pid, _} -> pid != job
          nil -> true
        end
      end)

      drain_repo(root)
    end
  end

  defp git_init(path) do
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: path, stderr_to_stdout: true)
  end

  # 10 ms a try; a test waiting on a poll or a sync under load passes 1000 (10 s)
  defp eventually(check, tries \\ 100)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, tries) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(check, tries - 1)
        )
  end
end
