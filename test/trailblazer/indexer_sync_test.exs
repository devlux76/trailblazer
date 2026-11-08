defmodule Trailblazer.IndexerSyncTest do
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

  test "a deleted node during an embedding batch is not left as a vector point", %{
    root: root,
    opts: opts
  } do
    {:ok, _} = Indexer.watch(root, Keyword.put(opts, :gate, true))
    :ok = Indexer.resume_embedding(root)
    assert_receive {:embedded, worker, _}, 1000
    {:ok, repo} = Store.add_repo(root)
    [save] = Store.nodes_by_qualified(repo, "saveHikes")
    File.rm!(Path.join(root, "web/save.ts"))
    Indexer.sync(root)
    send(worker, :continue)
    assert_receive {:points, _}, 1000
    eventually(fn -> Indexer.status(root).pending_vectors == 0 end)
    # The tombstone is processed after the in-flight put, preventing orphaned points.
    assert_receive {:deleted, ids}
    assert save.id in ids
  end

  test "listing failures preserve the graph and successful parsing restores stale files", %{
    root: root,
    opts: opts
  } do
    {:ok, mode} = Agent.start_link(fn -> :normal end)

    list = fn repo ->
      if Agent.get(mode, & &1) == :fail, do: raise("listing unavailable"), else: Files.list(repo)
    end

    {:ok, _} = Indexer.watch(root, Keyword.put(opts, :list_files, list))
    before = Indexer.status(root)
    Agent.update(mode, fn _ -> :fail end)
    assert {:error, {:listing_failed, _}} = Indexer.sync(root)
    assert Indexer.status(root).nodes == before.nodes
    Agent.update(mode, fn _ -> :normal end)
    original = File.read!(Path.join(root, "lib/app.ex"))
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Broken do")
    Indexer.sync(root)
    assert Indexer.status(root).stale_files == 1
    File.write!(Path.join(root, "lib/app.ex"), original)
    assert :ok = Indexer.ensure_fresh(root, ["lib/app.ex"])
    assert Indexer.status(root).stale_files == 0
  end

  test "a change during a held sync forms the next batch and status stays responsive", %{
    root: root,
    opts: opts
  } do
    parent = self()
    {:ok, gate} = Agent.start_link(fn -> false end)

    read = fn repo, path ->
      result = Files.read(repo, path)

      if path == "lib/app.ex" and Agent.get_and_update(gate, &{&1, false}) do
        send(parent, {:sync_read_held, self()})
        receive do: (:release_sync -> :ok)
      end

      result
    end

    Trailblazer.Events.subscribe({:repo, root})
    {:ok, pid} = Indexer.watch(root, Keyword.put(opts, :read_file, read))
    assert_receive {:trailblazer_event, {:repo, ^root}, %{event: :sync_done}}
    {:ok, repo} = Store.add_repo(root)
    Agent.update(gate, fn _ -> true end)
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Mini.App do; def first, do: :ok; end")
    send(pid, {:file_event, self(), {Path.join(root, "lib/app.ex"), [:modified]}})
    assert_receive {:sync_read_held, worker}
    on_exit(fn -> send(worker, :release_sync) end)
    status = Task.async(fn -> send(parent, {:status_during_sync, Indexer.status(root)}) end)
    assert_receive {:status_during_sync, %{syncing: true}}
    Task.await(status, :infinity)
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Mini.App do; def second, do: :ok; end")
    send(pid, {:file_event, self(), {Path.join(root, "lib/app.ex"), [:modified]}})
    send(worker, :release_sync)
    assert_receive {:trailblazer_event, {:repo, ^root}, %{event: :sync_done}}
    assert_receive {:trailblazer_event, {:repo, ^root}, %{event: :sync_done}}
    assert Store.nodes_by_qualified(repo, "Mini.App.second/0") != []
    assert Store.nodes_by_qualified(repo, "Mini.App.first/0") == []
  end

  test "a store restart retains the active sync input and its caller", %{root: root, opts: opts} do
    parent = self()
    {:ok, gate} = Agent.start_link(fn -> false end)

    parse = fn path, lang, source ->
      if path == "lib/app.ex" and Agent.get_and_update(gate, &{&1, false}) do
        send(parent, {:parse_held, self()})
        receive do: (:release_parse -> :ok)
      end

      Indexer.parse_file(path, lang, source)
    end

    {:ok, _} = Indexer.watch(root, Keyword.put(opts, :parse, parse))
    {:ok, repo} = Store.add_repo(root)
    Agent.update(gate, fn _ -> true end)

    File.write!(
      Path.join(root, "lib/app.ex"),
      "defmodule Mini.App do; def recovered, do: :ok; end"
    )

    sync = Task.async(fn -> Indexer.sync(root) end)
    assert_receive {:parse_held, worker}
    on_exit(fn -> send(worker, :release_parse) end)
    Trailblazer.Events.subscribe(:store)
    old_store = Process.whereis(Store)
    Process.exit(old_store, :kill)
    assert_receive {:trailblazer_event, :store, {:ready, replacement}}
    refute replacement == old_store
    send(worker, :release_parse)
    assert {:ok, _} = Task.await(sync, :infinity)
    assert Store.nodes_by_qualified(repo, "Mini.App.recovered/0") != []
  end

  # Q3: a sync used to read and parse one file after another, which left the
  # parse pool's workers idle. The seam below holds every parse once armed, so
  # two holders are two parses in flight at the same time: nothing can reach
  # the store until both are released.
  test "Q3: the files one sync must parse are parsed at the same time", %{root: root, opts: opts} do
    parent = self()
    {:ok, gate} = Agent.start_link(fn -> false end)

    parse = fn path, lang, source ->
      if Agent.get(gate, & &1) do
        send(parent, {:parse_held, self()})
        receive do: (:release_parse -> :ok)
      end

      Indexer.parse_file(path, lang, source)
    end

    {:ok, _} = Indexer.watch(root, Keyword.put(opts, :parse, parse))
    {:ok, repo} = Store.add_repo(root)
    Agent.update(gate, fn _ -> true end)

    # One file the Elixir parser reads in-process, one the pool reads through a
    # tree-sitter Port: both are held at once, or this never gets past the first.
    File.write!(
      Path.join(root, "lib/app.ex"),
      "defmodule Mini.App do; def together, do: :ok; end"
    )

    File.write!(Path.join(root, "web/save.ts"), "export function together() { return 1; }\n")

    sync = Task.async(fn -> Indexer.sync(root) end)

    assert_receive {:parse_held, first}, 5000
    assert_receive {:parse_held, second}, 5000
    refute first == second
    assert Process.alive?(first) and Process.alive?(second)
    assert Indexer.status(root).syncing

    send(first, :release_parse)
    send(second, :release_parse)

    assert {:ok, %{parsed: 2}} = Task.await(sync, :infinity)
    assert Store.nodes_by_qualified(repo, "Mini.App.together/0") != []
    assert Store.nodes_by_qualified(repo, "together") != []
  end

  test "filesystem events queue and reparse without an explicit sync", %{
    root: root,
    opts: opts
  } do
    {:ok, pid} = Indexer.watch(root, opts)
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Mini.App do; def changed, do: :ok; end")
    send(pid, {:file_event, self(), {Path.join(root, "lib/app.ex"), [:modified]}})
    {:ok, repo} = Store.add_repo(root)
    # Two rg passes can each wait on process scheduling.
    eventually(fn -> Store.nodes_by_qualified(repo, "Mini.App.changed/0") != [] end, 1000)
  end

  test "shared watcher restart rescans every registered repository", %{root: root, opts: opts} do
    others = [root <> "-second", root <> "-third"]
    for path <- others, do: File.cp_r!(root, path)

    on_exit(fn ->
      for path <- others do
        if pid = Indexer.whereis(path), do: GenServer.stop(pid)
        File.rm_rf!(path)
      end
    end)

    parent = self()

    opts =
      Keyword.merge(opts,
        filesystem: true,
        start_watcher: fn paths ->
          watcher = spawn(fn -> receive do: (:done -> :ok) end)
          send(parent, {:shared_started, watcher, paths})
          {:ok, watcher}
        end,
        subscribe_watcher: fn _ -> :ok end
      )

    roots = [root | others]
    # One watch per repository, on its git directory (B12b).
    for path <- roots, do: git_init(path)
    for path <- roots, do: Trailblazer.Events.subscribe({:repo, path})

    Enum.reduce(roots, [], fn path, watched ->
      assert {:ok, _} = Indexer.watch(path, opts)
      assert_receive {:shared_started, watcher, native_dirs}

      assert Enum.sort(native_dirs) ==
               Enum.sort(Enum.map([path | watched], &Path.join(&1, ".git")))

      for repo <- [path | watched] do
        assert_receive {:trailblazer_event, {:repo, ^repo},
                        %{event: :watcher_resynced, watcher: ^watcher}},
                       5000

        assert Indexer.status(repo).following == :events
      end

      [path | watched]
    end)
  end

  test "restart retains queued vector deletion and re-syncs graph", %{root: root, opts: opts} do
    {:ok, pid} = Indexer.watch(root, opts)
    {:ok, repo} = Store.add_repo(root)
    File.write!(Path.join(root, "new.ex"), "defmodule New do; end")
    Process.exit(pid, :kill)
    eventually(fn -> is_pid(Indexer.whereis(root)) and Indexer.whereis(root) != pid end, 1000)
    eventually(fn -> Store.nodes_by_qualified(repo, "New") != [] end, 1000)
  end

  test "vector deletion retries survive restarting the indexer", %{root: root, opts: opts} do
    {:ok, pid} = Indexer.watch(root, Keyword.put(opts, :vectors_down, true))
    {:ok, repo} = Store.add_repo(root)
    [save] = Store.nodes_by_qualified(repo, "saveHikes")
    File.rm!(Path.join(root, "web/save.ts"))
    Indexer.sync(root)

    eventually(fn ->
      Indexer.status(root).embedding == :paused and Store.pending_vector_deletes(repo) != []
    end)

    assert save.id in Store.pending_vector_deletes(repo)
    GenServer.stop(pid)
    {:ok, _} = Indexer.watch(root, opts)
    eventually(fn -> Store.pending_vector_deletes(repo) == [] end)
  end

  test "a source changed mid-embedding stays pending for its new hash", %{root: root, opts: opts} do
    {:ok, _} = Indexer.watch(root, Keyword.put(opts, :gate, true))
    :ok = Indexer.resume_embedding(root)
    assert_receive {:embedded, worker, _}, 1000
    :ok = Indexer.pause_embedding(root)
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Mini.App do; def run(x), do: x; end")
    Indexer.sync(root)
    send(worker, :continue)
    assert_receive {:points, _}, 1000
    eventually(fn -> Indexer.status(root).pending_vectors > 0 end)
    :ok = Indexer.resume_embedding(root)
    assert_receive {:embedded, worker, _}, 1000
    send(worker, :continue)
    eventually(fn -> Indexer.status(root).pending_vectors == 0 end)
  end

  test "unreadable pending head does not starve later definitions, and retry can drain it", %{
    root: root,
    opts: opts
  } do
    File.write!(
      Path.join(root, "0.ex"),
      "defmodule Head do\n" <>
        Enum.map_join(1..20, "\n", fn i -> "def f#{i}, do: :ok" end) <> "\nend"
    )

    {:ok, mode} = Agent.start_link(fn -> :readable end)

    read = fn repo, path ->
      if path == "0.ex" and Agent.get(mode, & &1) == :blocked,
        do: {:error, :enoent},
        else: Files.read(repo, path)
    end

    {:ok, pid} = Indexer.watch(root, Keyword.put(opts, :read_file, read))
    {:ok, repo} = Store.add_repo(root)
    Agent.update(mode, fn _ -> :blocked end)
    :ok = Indexer.resume_embedding(root)

    eventually(fn ->
      Enum.all?(Store.nodes_in_file(repo, "web/save.ts"), &(&1.vector_hash == &1.text_hash))
    end)

    assert Indexer.status(root).pending_vectors > 0
    Agent.update(mode, fn _ -> :readable end)
    send(pid, :embed)
    eventually(fn -> Indexer.status(root).pending_vectors == 0 end)
  end

  test "pending vector paging excludes stale rows in SQLite", %{root: root, opts: opts} do
    {:ok, _} = Indexer.watch(root, opts)
    {:ok, repo} = Store.add_repo(root)
    Store.mark_stale(repo, "lib/app.ex")
    first = Store.pending_vectors(repo, 3, exclude_stale: true)
    assert length(first) == 3
    assert Enum.all?(first, &(!&1.stale))
    later = Store.pending_vectors(repo, 3, exclude_stale: true, after_id: List.last(first).id)
    assert Enum.all?(later, &(&1.id > List.last(first).id and not &1.stale))
  end

  test "file modules own imports, top-level callbacks and citations and contain top-level definitions",
       %{root: root, opts: opts} do
    File.mkdir_p!(Path.join(root, "tests"))
    File.write!(Path.join(root, "web/weather.ts"), "export function weatherAt(){ return 1; }\n")

    File.write!(
      Path.join(root, "tests/weather.test.ts"),
      "import {weatherAt} from '../web/weather';\n// docs/design.md §2\ntest('weather', () => { weatherAt(); });\n"
    )

    {:ok, _} = Indexer.watch(root, opts)
    {:ok, repo} = Store.add_repo(root)
    [module] = Store.nodes_by_qualified(repo, "tests/weather.test.ts")
    assert module.kind == "module"
    assert module.key == "typescript:module:tests/weather.test.ts#tests/weather.test.ts"
    refs = Enum.filter(Store.refs(repo), &(&1.path == module.path))
    assert Enum.all?(refs, &is_binary(&1.from_key))
    users = Trailblazer.Query.who_uses(root, "weatherAt")
    assert Enum.any?(users, &(&1.node.id == module.id and &1.kind == "calls"))
    assert Enum.any?(Trailblazer.Query.impact_of(root, "weatherAt"), &(&1.node.id == module.id))

    assert Enum.any?(
             Trailblazer.Query.where_declared(root, {module.path, 1}),
             &(&1.qualified == "weatherAt")
           )

    [weather] = Store.nodes_by_qualified(repo, "weatherAt")
    [file] = Store.nodes_by_qualified(repo, "web/weather.ts")
    assert Enum.any?(Store.edges_from(file.id, ["contains"]), &(&1.to_id == weather.id))

    assert Enum.any?(
             Store.edges_from(module.id, ["implements"]),
             &(&1.to_id == hd(Store.nodes_by_qualified(repo, "docs/design.md#2")).id)
           )
  end

  test "watch performs one initial listing and resolution pass", %{root: root, opts: opts} do
    observer = self()

    list = fn path ->
      send(observer, :listed)
      Files.list(path)
    end

    {:ok, _} = Indexer.watch(root, Keyword.put(opts, :list_files, list))
    assert_receive :listed
    refute_receive :listed, 30
  end

  test "an unchanged file indexed before file modules is upgraded on watch", %{
    root: root,
    opts: opts
  } do
    {:ok, repo} = Store.add_repo(root)
    source = File.read!(Path.join(root, "web/save.ts"))
    {:ok, parsed} = Trailblazer.Parse.TreeSitter.parse("web/save.ts", :typescript, source)
    hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
    :ok = Store.replace_file(repo, "web/save.ts", Map.put(parsed, :hash, hash))
    assert Store.nodes_by_qualified(repo, "web/save.ts") == []
    {:ok, _} = Indexer.watch(root, opts)
    assert [%{kind: "module"}] = Store.nodes_by_qualified(repo, "web/save.ts")
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
