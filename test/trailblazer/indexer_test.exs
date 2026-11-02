defmodule Trailblazer.IndexerTest do
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

  test "sync is incremental, stale syntax keeps graph, deletion removes points and leaves refs",
       %{root: root, opts: opts} do
    assert {:ok, pid} = Indexer.watch(root, opts)
    assert {:ok, ^pid} = Indexer.watch(root <> "/.", opts)
    assert {:ok, %{parsed: 0, deleted: 0, stale: 0}} = Indexer.sync(root)
    {:ok, repo} = Store.add_repo(root)
    assert length(Store.nodes_by_qualified(repo, "Mini.Store.put/2")) == 2
    [run] = Store.nodes_by_qualified(repo, "Mini.App.run/1")
    assert length(Store.edges_from(run.id, ["calls"])) == 2
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Mini.App do\n def run(x), do: x\nend")
    assert {:ok, %{parsed: 1}} = Indexer.sync(root)
    [run] = Store.nodes_by_qualified(repo, "Mini.App.run/1")
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Mini.App do\n def run(")
    assert {:ok, %{stale: 1}} = Indexer.sync(root)
    assert Store.node(run.id).stale
    [save] = Store.nodes_by_qualified(repo, "saveHikes")
    File.rm!(Path.join(root, "web/save.ts"))
    assert {:ok, %{deleted: 1}} = Indexer.sync(root)
    assert_receive {:deleted, ids}
    assert save.id in ids
    assert Store.node(save.id) == nil
    assert Enum.any?(Store.refs(repo), &(&1.target == "saveHikes"))
  end

  test "J32/J34: changed syncs maintain coverage; clean syncs preserve it", %{
    root: root,
    opts: opts
  } do
    {:ok, _} = Indexer.watch(root, opts)
    {:ok, repo} = Store.add_repo(root)
    state = Store.resolution_state(repo)
    assert state.complete and state.version == 1
    assert state.revision == state.resolved_revision
    dependencies = Store.resolution_dependencies(repo)
    assert {:ok, %{parsed: 0, deleted: 0, stale: 0}} = Indexer.sync(root)
    assert Store.resolution_state(repo) == state
    assert Store.resolution_dependencies(repo) == dependencies

    File.write!(
      Path.join(root, "lib/app.ex"),
      File.read!(Path.join(root, "lib/app.ex")) <> "\n# graph delta\n"
    )

    assert {:ok, %{parsed: 1}} = Indexer.sync(root)
    updated = Store.resolution_state(repo)
    assert updated.complete and updated.pending == []
    assert updated.revision > state.revision and updated.resolved_revision == updated.revision

    revisions =
      case GenServer.call(
             Store,
             {:run, :read,
              fn conn ->
                Exqlite.query!(
                  conn,
                  "SELECT DISTINCT revision FROM resolve_source WHERE repo_id=?",
                  [repo]
                ).rows
              end},
             :infinity
           ) do
        {:returned, rows} -> rows
      end

    assert revisions == [[state.revision]],
           "a full pass with unchanged outputs retains source coverage rows"
  end

  test "J31: unchanged git and full syncs neither resolve nor rewrite edges", %{
    root: root,
    opts: opts
  } do
    git_init(root)
    {_, 0} = System.cmd("git", ["add", "."], cd: root)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@example.test",
          "commit",
          "-qm",
          "fixture"
        ],
        cd: root
      )

    {:ok, pid} = Indexer.watch(root, opts)
    trace_resolution(pid)
    before = Indexer.status(root)

    assert {:ok, %{parsed: 0, deleted: 0, stale: 0, generation: generation, head: head}} =
             Indexer.fresh(root)

    assert generation == before.generation + 1
    assert head == before.head
    assert {:ok, %{parsed: 0, deleted: 0, stale: 0}} = Indexer.sync(root)
    assert :ok = Indexer.ensure_fresh(root, ["not-indexed.txt"])
    resolution_delivered()
    refute_receive {:trace, _, :call, {Trailblazer.Graph.Resolve, :edges, _}}, 0
    refute_receive {:trace, _, :call, {Store, :put_edges, _}}, 0
    refute_receive {:trace, _, :call, {Trailblazer.Graph.Resolve, :tracked, _}}, 0
    refute_receive {:trace, _, :call, {Trailblazer.Graph.Resolve, :next, _}}, 0
    refute_receive {:trace, _, :call, {Store, :replace_resolved_sources, _}}, 0
  end

  test "J31: parsing, stale marking, recovery and deletion still resolve", %{
    root: root,
    opts: opts
  } do
    {:ok, pid} = Indexer.watch(root, opts)
    {:ok, repo} = Store.add_repo(root)
    trace_resolution(pid)
    path = Path.join(root, "lib/app.ex")
    source = File.read!(path)

    File.write!(path, source <> "\n# changed\n")
    assert {:ok, %{parsed: 1}} = Indexer.sync(root)
    assert_resolved(repo)

    File.write!(path, "defmodule Broken do")
    assert {:ok, %{parsed: 0, stale: 1}} = Indexer.sync(root)
    assert_resolved(repo)

    File.write!(path, source <> "\n# changed\n")
    assert {:ok, %{parsed: 1, stale: 0}} = Indexer.sync(root)
    assert_resolved(repo)
    assert [%{stale: false}] = Store.nodes_by_qualified(repo, "Mini.App.run/1")

    File.rm!(path)
    assert {:ok, %{parsed: 0, deleted: 1}} = Indexer.sync(root)
    assert_resolved(repo)
  end

  test "J31: unresolved edges and old indexer state force a zero-count resolve", %{
    root: root,
    opts: opts
  } do
    {:ok, pid} = Indexer.watch(root, opts)
    {:ok, repo} = Store.add_repo(root)
    trace_resolution(pid)

    for state <- [:pending, :old] do
      :ok = Store.put_edges(repo, [])

      :sys.replace_state(pid, fn s ->
        if state == :old,
          do: Map.delete(s, :edges_current),
          else: Map.put(s, :edges_current, false)
      end)

      assert {:ok, %{parsed: 0, deleted: 0, stale: 0}} = Indexer.sync(root)
      assert_resolved(repo)
      [run] = Store.nodes_by_qualified(repo, "Mini.App.run/1")
      assert length(Store.edges_from(run.id, ["calls"])) == 2
    end
  end

  test "J31: a zero-count retry resolves files written before a sync failed", %{
    root: root,
    opts: opts
  } do
    selection = MapSet.new(["lib/app.ex", "lib/store.ex"])
    [first, second] = Enum.to_list(selection)
    {:ok, fail} = Agent.start_link(fn -> false end)

    read = fn repo, path ->
      if path == second and Agent.get_and_update(fail, &{&1, false}), do: throw(:read_failed)
      Files.read(repo, path)
    end

    {:ok, pid} = Indexer.watch(root, Keyword.put(opts, :read_file, read))
    {:ok, repo} = Store.add_repo(root)
    trace_resolution(pid)
    original = File.read!(Path.join(root, second))

    File.write!(
      Path.join(root, first),
      "\ndefmodule J31 do\n def call, do: Mini.Store.put(:a, :b)\nend\n",
      [:append]
    )

    File.write!(Path.join(root, second), original <> "\n# changed\n")
    Agent.update(fail, fn _ -> true end)

    assert {:error, {:sync_failed, {:throw, :read_failed}}} =
             Indexer.ensure_fresh(root, selection)

    assert [_] = Store.nodes_by_qualified(repo, "J31.call/0")
    File.write!(Path.join(root, second), original)
    assert {:ok, %{parsed: 0, deleted: 0, stale: 0}} = Indexer.sync(root)
    assert_resolved(repo)
    [call] = Store.nodes_by_qualified(repo, "J31.call/0")
    assert length(Store.edges_from(call.id, ["calls"])) == 2
  end

  test "J31: an unchanged file missing its module still parses and resolves", %{
    root: root,
    opts: opts
  } do
    {:ok, pid} = Indexer.watch(root, opts)
    {:ok, repo} = Store.add_repo(root)
    source = File.read!(Path.join(root, "web/save.ts"))
    {:ok, parsed} = Trailblazer.Parse.TreeSitter.parse("web/save.ts", :typescript, source)
    hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
    :ok = Store.replace_file(repo, "web/save.ts", Map.put(parsed, :hash, hash))
    trace_resolution(pid)

    assert {:ok, %{parsed: 1}} = Indexer.sync(root)
    assert_resolved(repo)
    assert [%{kind: "module"}] = Store.nodes_by_qualified(repo, "web/save.ts")
  end

  test "pause/resume embeds in batches, vector failure keeps pending, graph remains available", %{
    root: root,
    opts: opts
  } do
    {:ok, _} = Indexer.watch(root, opts)
    refute_receive {:embedded, _, _}, 30
    assert Indexer.status(root).pending_vectors > 0
    :ok = Indexer.resume_embedding(root)
    assert_receive {:embedded, _, docs}, 1000
    assert length(docs) <= 16

    assert Enum.all?(docs, fn {title, text} ->
             is_binary(title) and String.length(text) <= 2400
           end)

    eventually(fn -> Indexer.status(root).pending_vectors == 0 end)
    assert Indexer.status(root).embedding == :running
  end

  test "embedder failure preserves pending and reports waiting", %{root: root, opts: opts} do
    {:ok, _} = Indexer.watch(root, Keyword.put(opts, :down, true))
    :ok = Indexer.resume_embedding(root)
    eventually(fn -> Indexer.status(root).embedding == :waiting_for_service end)
    assert Indexer.status(root).nodes > 0
    assert Indexer.status(root).pending_vectors > 0
  end

  test "Qdrant failure never marks vectors done", %{root: root, opts: opts} do
    {:ok, _} = Indexer.watch(root, Keyword.put(opts, :vectors_down, true))
    :ok = Indexer.resume_embedding(root)
    eventually(fn -> Indexer.status(root).embedding == :waiting_for_service end)
    assert Indexer.status(root).pending_vectors > 0
  end

  test "an omitted existing file is stale, not deleted; empty files deliberately leave index", %{
    root: root,
    opts: opts
  } do
    {:ok, mode} = Agent.start_link(fn -> :normal end)

    list = fn path ->
      files = Files.list(path)

      if Agent.get(mode, & &1) == :omit,
        do: Enum.reject(files, &(&1.path == "lib/app.ex")),
        else: files
    end

    {:ok, _} = Indexer.watch(root, Keyword.put(opts, :list_files, list))
    {:ok, repo} = Store.add_repo(root)
    [node] = Store.nodes_by_qualified(repo, "Mini.App.run/1")
    Agent.update(mode, fn _ -> :omit end)
    assert {:ok, %{deleted: 0, stale: 1}} = Indexer.sync(root)
    assert Store.node(node.id).stale
    File.write!(Path.join(root, "lib/app.ex"), "")
    assert {:ok, %{deleted: 1}} = Indexer.sync(root)
    assert Store.node(node.id) == nil
  end

  test "ensure_fresh re-parses immediately and stale success clears flags", %{
    root: root,
    opts: opts
  } do
    {:ok, _} = Indexer.watch(root, opts)
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Mini.App do\n def fresh, do: :ok\nend")
    assert :ok = Indexer.ensure_fresh(root, ["lib/app.ex"])
    {:ok, repo} = Store.add_repo(root)
    assert [%{stale: false}] = Store.nodes_by_qualified(repo, "Mini.App.fresh/0")
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

  defp trace_resolution(pid) do
    functions = [
      {Trailblazer.Graph.Resolve, :edges, 1},
      {Trailblazer.Graph.Resolve, :tracked, 1},
      {Trailblazer.Graph.Resolve, :next, 1},
      {Store, :put_edges, 2},
      {Store, :replace_resolved_sources, 3}
    ]

    for function <- functions, do: :erlang.trace_pattern(function, true, [:local])
    :erlang.trace(pid, true, [:call, :set_on_spawn])

    on_exit(fn ->
      for function <- functions, do: :erlang.trace_pattern(function, false, [:local])
      if Process.alive?(pid), do: :erlang.trace(pid, false, [:call, :set_on_spawn])
    end)
  end

  defp resolution_delivered do
    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}
  end

  defp assert_resolved(repo) do
    assert_receive {:trace, worker, :call, {Trailblazer.Graph.Resolve, :next, [^repo]}}
    assert_receive {:trace, ^worker, :call, {Store, :replace_resolved_sources, [^repo, _, batch]}}

    if batch.full,
      do:
        assert(
          MapSet.subset?(
            MapSet.new(Enum.map(Store.graph_snapshot(repo).nodes, & &1.key)),
            MapSet.new(batch.sources)
          )
        )
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
