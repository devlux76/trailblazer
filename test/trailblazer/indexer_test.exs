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
