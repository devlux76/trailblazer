defmodule Trailblazer.TrailTest do
  use ExUnit.Case, async: false

  alias Trailblazer.{Store, Trail}

  defmodule NoFresh do
    def ensure_fresh(_repo, _files), do: :ok
  end

  defmodule FakeEmbed do
    def query(_text, _opts), do: {:ok, [0.1]}
  end

  defmodule DownEmbed do
    def query(_text, _opts), do: {:error, :embedder_down}
  end

  # Vectors that say saveHikes is close to anything asked and put is not.
  defmodule FakeVectors do
    def nearest(_repo, _vector, _limit, _opts), do: {:ok, Process.get(:nearest, [])}

    def scores(_repo, _vector, ids, _opts) do
      sims = Process.get(:sims, %{})
      {:ok, Map.new(ids, &{&1, Map.get(sims, &1, 0.5)})}
    end
  end

  # Like the real store: ids without a vector are absent from scores.
  defmodule SparseVectors do
    def nearest(_repo, _vector, _limit, _opts), do: {:ok, []}

    def scores(_repo, _vector, ids, _opts) do
      sims = Process.get(:sims, %{})
      {:ok, ids |> Enum.filter(&Map.has_key?(sims, &1)) |> Map.new(&{&1, sims[&1]})}
    end
  end

  defmodule DownVectors do
    def nearest(_repo, _vector, _limit, _opts), do: {:error, :qdrant_down}
    def scores(_repo, _vector, _ids, _opts), do: {:error, :qdrant_down}
  end

  setup do
    root = Path.expand("../fixtures/mini", __DIR__)
    dir = Path.join(System.tmp_dir!(), "trailblazer-trail-#{System.unique_integer([:positive])}")
    File.cp_r!(root, dir)

    # indexed the way the service indexes it (whole-file nodes included)
    {:ok, _pid} =
      Trailblazer.Indexer.watch(dir,
        embed: FakeEmbed,
        vectors: FakeVectors,
        filesystem: false,
        embedding: :paused
      )

    {:ok, repo_id} = Store.add_repo(dir)

    on_exit(fn ->
      if pid = Trailblazer.Indexer.whereis(dir), do: GenServer.stop(pid)
      File.rm_rf!(dir)
    end)

    id = fn qualified, path ->
      Enum.find(Store.nodes_by_qualified(repo_id, qualified), &(&1.path == path)).id
    end

    ids = %{
      save: id.("saveHikes", "web/save.ts"),
      put: id.("Mini.Store.put/2", "lib/store.ex"),
      run: id.("Mini.App.run/1", "lib/app.ex")
    }

    Process.put(:sims, %{ids.save => 0.9, ids.put => 0.3})

    %{dir: dir, ids: ids, opts: [indexer: NoFresh, embed: FakeEmbed, vectors: FakeVectors]}
  end

  defp rank_of(trail, qualified) do
    Enum.find_index(trail.items, &(&1.node.qualified == qualified))
  end

  test "repeated call sites do not trigger a database lookup for every edge", ctx do
    {:ok, repo} = Store.add_repo(ctx.dir)

    edges =
      for line <- 1..600,
          do: %{
            from_id: ctx.ids.put,
            to_id: ctx.ids.save,
            kind: "calls",
            uncertain: false,
            line: line
          }

    assert :ok = Store.put_edges(repo, edges)

    task =
      Task.async(fn ->
        receive do: (:go -> Trail.build(ctx.dir, "change Mini.Store.put/2", ctx.opts))
      end)

    :erlang.trace_pattern({Store, :node, 1}, true, [:local])
    :erlang.trace(task.pid, true, [:call])
    on_exit(fn -> :erlang.trace_pattern({Store, :node, 1}, false, [:local]) end)
    send(task.pid, :go)
    trail = Task.await(task, 30_000)
    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}
    lookups = node_lookups(task.pid, 0)

    assert Enum.any?(trail.items, &(&1.node.qualified == "Mini.Store.put/2"))
    assert Enum.any?(trail.items, &(&1.node.qualified == "saveHikes"))
    assert lookups <= 8, "#{lookups} single-node database lookups for two graph nodes"
  end

  defp node_lookups(pid, count) do
    receive do
      {:trace, ^pid, :call, {Store, :node, [_]}} -> node_lookups(pid, count + 1)
    after
      0 -> count
    end
  end

  test "dense trail ranking stays within a bounded CPU work budget", ctx do
    {repo, nodes} = graph_nodes(ctx.dir, for(i <- 1..150, do: "denseNode#{i}"))
    ids = Enum.map(nodes, & &1.id)

    edges =
      for a <- ids, b <- ids, a != b, do: %{from_id: a, to_id: b, kind: "calls", uncertain: false}

    assert :ok = Store.put_edges(repo, edges)

    {:reductions, before} = Process.info(self(), :reductions)
    trail = Trail.build(ctx.dir, "denseNode1", embed: DownEmbed, budget: 2000)
    {:reductions, after_} = Process.info(self(), :reductions)

    assert length(trail.items) == 150
    # The old scatter into a persistent map for every edge in every iteration
    # spent >10M reductions here. This measures CPU work, not laptop wall time.
    assert after_ - before < 8_000_000
  end

  test "ranking retains certain, contains and uncertain weights with a dangling seed", ctx do
    {repo, nodes} =
      graph_nodes(ctx.dir, [
        "rootSeed",
        "fullTarget",
        "containsTarget",
        "uncertainTarget",
        "danglingSeed"
      ])

    ids = Map.new(nodes, &{&1.name, &1.id})

    edges =
      for {target, kind, uncertain} <- [
            {"fullTarget", "calls", false},
            {"containsTarget", "contains", false},
            {"uncertainTarget", "calls", true}
          ],
          do: %{from_id: ids["rootSeed"], to_id: ids[target], kind: kind, uncertain: uncertain}

    assert :ok = Store.put_edges(repo, edges)

    trail = Trail.build(ctx.dir, "rootSeed danglingSeed", embed: DownEmbed, budget: 2000)

    assert Enum.map(trail.items, & &1.node.qualified) == [
             "rootSeed",
             "fullTarget",
             "danglingSeed",
             "containsTarget",
             "uncertainTarget"
           ]
  end

  test "the walk does not follow a call that resolved to more than two candidates", ctx do
    names = ["rootSeed", "wideA", "wideB", "wideC", "narrowA", "narrowB"]
    {repo, nodes} = graph_nodes(ctx.dir, names)
    ids = Map.new(nodes, &{&1.name, &1.id})

    call = fn to, line ->
      %{from_id: ids["rootSeed"], to_id: ids[to], kind: "calls", uncertain: true, line: line}
    end

    # One call site naming something three functions share; another naming something two share.
    edges = [
      call.("wideA", 10),
      call.("wideB", 10),
      call.("wideC", 10),
      call.("narrowA", 20),
      call.("narrowB", 20)
    ]

    assert :ok = Store.put_edges(repo, edges)

    trail = Trail.build(ctx.dir, "rootSeed", embed: DownEmbed, budget: 2000)

    assert Enum.map(trail.items, & &1.node.qualified) |> Enum.sort() == [
             "narrowA",
             "narrowB",
             "rootSeed"
           ]
  end

  defp graph_nodes(dir, names) do
    {:ok, repo} = Store.add_repo(dir)

    nodes =
      for {name, line} <- Enum.with_index(names, 1) do
        %{
          key: "typescript:function:graph.ts##{name}",
          lang: "typescript",
          kind: "function",
          name: name,
          qualified: name,
          path: "graph.ts",
          start_line: line,
          end_line: line,
          signature: "function #{name}() {}",
          text_hash: name
        }
      end

    File.write!(Path.join(dir, "graph.ts"), Enum.map_join(nodes, "\n", & &1.signature))
    assert :ok = Store.replace_file(repo, "graph.ts", %{hash: "graph", nodes: nodes, refs: []})
    {repo, Store.nodes_in_file(repo, "graph.ts")}
  end

  test "a request about saving hikes from web/app.ts ranks saveHikes above put", ctx do
    Process.put(:nearest, [{ctx.ids.save, 0.9}, {ctx.ids.put, 0.3}])

    trail =
      Trail.build(ctx.dir, "saving hikes fails", Keyword.merge(ctx.opts, files: ["web/app.ts"]))

    assert %Trail{} = trail
    save = rank_of(trail, "saveHikes")
    assert is_integer(save)
    put = rank_of(trail, "Mini.Store.put/2")
    assert is_nil(put) or save < put
    assert trail.notes == []
  end

  # L9 T1: the task's own file came twice, in full under Files and again as
  # the trail's largest item.
  test "a file named in omit seeds the walk but none of it is packed", ctx do
    opts = Keyword.merge(ctx.opts, files: ["web/app.ts"])
    with_file = Trail.build(ctx.dir, "saving hikes fails", opts)
    assert Enum.any?(with_file.items, &(&1.node.path == "web/app.ts"))

    omitted = Trail.build(ctx.dir, "saving hikes fails", Keyword.put(opts, :omit, ["web/app.ts"]))
    refute Enum.any?(omitted.items, &(&1.node.path == "web/app.ts"))
    refute omitted.text =~ "web/app.ts:"
    assert omitted.items != []
  end

  test "a path:line in the request seeds the definition at that line", ctx do
    trail = Trail.build(ctx.dir, "crash at lib/app.ex:4 in run", ctx.opts)

    assert %{node: %{qualified: "Mini.App.run/1"}, form: form} =
             Enum.find(trail.items, &(&1.node.qualified == "Mini.App.run/1"))

    assert form in [:full, :signature]
  end

  test "the trail of Mini.Store.put/2 carries the design section it implements", ctx do
    trail = Trail.build(ctx.dir, "change Mini.Store.put/2", ctx.opts)

    assert %{form: :section} =
             Enum.find(trail.items, &(&1.node.qualified == "docs/design.md#2"))

    assert trail.text =~ "docs/design.md:"
    assert trail.text =~ "Storage"
  end

  test "every item is headed with its path and lines", ctx do
    trail = Trail.build(ctx.dir, "change Mini.Store.put/2", ctx.opts)

    for item <- trail.items do
      assert trail.text =~ "#{item.node.path}:#{item.node.start_line}-#{item.node.end_line}"
    end
  end

  # Found by the release smoke test: Mini.App was packed in full and then
  # Mini.App.run inside it, so the same lines came twice.
  test "no lines are packed twice", ctx do
    trail =
      Trail.build(
        ctx.dir,
        "saving hikes fails in Mini.App.run",
        Keyword.merge(ctx.opts, files: ["lib/app.ex"])
      )

    full = Enum.filter(trail.items, &(&1.form == :full))

    for a <- full, b <- full, a != b, a.node.path == b.node.path do
      refute a.node.start_line <= b.node.start_line and b.node.end_line <= a.node.end_line,
             "#{a.node.qualified} holds #{b.node.qualified}, both in full"
    end

    # run is there, by itself or inside its module given in full
    assert trail.text =~ "def run(hikes)"
    assert length(String.split(trail.text, "def run(hikes)")) == 2
  end

  # Found by the acceptance run on sojourney (T15-T17).
  describe "packing, after the acceptance run" do
    test "a whole-file node is walked through but never packed", ctx do
      trail =
        Trail.build(ctx.dir, "saving hikes fails", Keyword.merge(ctx.opts, files: ["web/app.ts"]))

      refute Enum.any?(
               trail.items,
               &(&1.node.kind == "module" and &1.node.qualified == &1.node.path)
             )

      assert Enum.any?(trail.items, &(&1.node.qualified == "saveHikes"))
    end

    test "plain words do not seed by name; identifiers and backticked words do", ctx do
      down = Keyword.merge(ctx.opts, embed: DownEmbed, vectors: DownVectors)

      assert Trail.build(ctx.dir, "please load the page", down).items == []

      assert Enum.any?(
               Trail.build(ctx.dir, "please `load` the page", down).items,
               &(&1.node.qualified == "load")
             )

      assert Enum.any?(
               Trail.build(ctx.dir, "why does saveHikes fail", down).items,
               &(&1.node.qualified == "saveHikes")
             )
    end

    test "the last item is whole: the budget is never met by cutting text", ctx do
      for budget <- 20..300//5 do
        trail =
          Trail.build(
            ctx.dir,
            "change Mini.Store.put/2 and saveHikes",
            Keyword.merge(ctx.opts, budget: budget)
          )

        assert trail.tokens <= budget

        if last = List.last(trail.items) do
          ending = if last.form == :signature, do: last.node.signature, else: nil

          if ending,
            do:
              assert(
                String.ends_with?(trail.text, ending),
                "budget #{budget}: #{inspect(trail.text)}"
              )
        end
      end
    end
  end

  test "the trail fits its budget", ctx do
    trail =
      Trail.build(
        ctx.dir,
        "change Mini.Store.put/2 and saveHikes",
        Keyword.merge(ctx.opts, budget: 200)
      )

    assert trail.tokens <= 200
    assert trail.tokens == div(String.length(trail.text) + 3, 4)
  end

  test "H1: a budget too small for any item gives an empty trail, not a crash", ctx do
    trail = Trail.build(ctx.dir, "change Mini.Store.put/2", Keyword.merge(ctx.opts, budget: 1))

    assert trail.tokens <= 1
    assert trail.items == []
  end

  test "H1: a request that seeds nothing gives an empty trail", ctx do
    trail = Trail.build(ctx.dir, "zzzz qqqq", Keyword.merge(ctx.opts, vectors: DownVectors))

    assert trail.items == [] and trail.text == ""
    assert trail.notes == ["no vectors"]
  end

  test "with the vectors down the trail still builds and says so", ctx do
    trail =
      Trail.build(
        ctx.dir,
        "change Mini.Store.put/2",
        Keyword.merge(ctx.opts, embed: DownEmbed, vectors: DownVectors)
      )

    assert trail.notes == ["no vectors"]
    assert Enum.any?(trail.items, &(&1.node.qualified == "Mini.Store.put/2"))
  end

  test "unscored nodes are admitted only next to a seed, never across the whole walk", ctx do
    opts = Keyword.put(ctx.opts, :budget, 100_000)
    dense = Trail.build(ctx.dir, "change Mini.Store.put/2", opts)

    Process.put(:sims, %{})

    sparse =
      Trail.build(ctx.dir, "change Mini.Store.put/2", Keyword.put(opts, :vectors, SparseVectors))

    ids = fn t -> MapSet.new(t.items, & &1.node.id) end

    assert rank_of(sparse, "Mini.Store.put/2")
    assert MapSet.subset?(ids.(sparse), ids.(dense))
    assert MapSet.size(ids.(sparse)) < MapSet.size(ids.(dense))

    down =
      Trail.build(
        ctx.dir,
        "change Mini.Store.put/2",
        Keyword.merge(opts, embed: DownEmbed, vectors: DownVectors)
      )

    assert MapSet.subset?(ids.(down), ids.(dense))
  end

  describe "rerank" do
    test "keeps the pinned and the reranker's picks, drops the rest", ctx do
      opts = Keyword.put(ctx.opts, :budget, 100_000)
      plain = Trail.build(ctx.dir, "change Mini.Store.put/2", opts)

      reranked =
        Trail.build(
          ctx.dir,
          "change Mini.Store.put/2",
          Keyword.merge(opts,
            rerank: true,
            rerank_chat: fn _m, o ->
              send(self(), {:rerank_opts, o})
              {:ok, %{content: "1, 999"}}
            end
          )
        )

      names = fn t -> MapSet.new(t.items, & &1.node.qualified) end
      assert "Mini.Store.put/2" in names.(reranked)
      assert MapSet.subset?(names.(reranked), names.(plain))
      assert MapSet.size(names.(reranked)) < MapSet.size(names.(plain))
      assert Enum.any?(reranked.notes, &String.starts_with?(&1, "reranked"))
      assert_received {:rerank_opts, rerank_opts}
      assert rerank_opts[:model] == Trailblazer.Config.get(:rerank_model)
      refute rerank_opts[:tools]
    end

    test "a failing reranker leaves the trail as it was and says so", ctx do
      opts = Keyword.put(ctx.opts, :budget, 100_000)
      plain = Trail.build(ctx.dir, "change Mini.Store.put/2", opts)
      down = fn _messages, _opts -> {:error, :econnrefused} end

      failed =
        Trail.build(
          ctx.dir,
          "change Mini.Store.put/2",
          Keyword.merge(opts, rerank: true, rerank_chat: down)
        )

      assert Enum.map(failed.items, & &1.node.id) == Enum.map(plain.items, & &1.node.id)
      assert "rerank skipped: :econnrefused" in failed.notes
    end

    test "an answer naming no candidate is a failure, not an empty trail" do
      cands = [
        %{id: 7, path: "a.ex", start_line: 1, end_line: 2, qualified: "A.f/0", signature: "def f"}
      ]

      chat = fn _m, _o -> {:ok, %{content: "none of them"}} end

      assert {:error, :nothing_named} =
               Trailblazer.Trail.Rerank.select("x", cands, rerank_chat: chat)

      chat = fn _m, _o -> {:ok, %{content: "1, 1, 5"}} end
      assert {:ok, [7]} = Trailblazer.Trail.Rerank.select("x", cands, rerank_chat: chat)
    end
  end

  test "a non-seed far from the request is dropped", ctx do
    # renderList is reached from saveHikes but is not a seed and scores low
    Process.put(:sims, Map.put(Process.get(:sims), ctx.ids.save, 0.9))

    render =
      Enum.find(Store.nodes_by_qualified(elem(Store.add_repo(ctx.dir), 1), "renderList"), & &1)

    Process.put(:sims, Map.put(Process.get(:sims), render.id, 0.1))

    trail = Trail.build(ctx.dir, "saveHikes", ctx.opts)

    assert rank_of(trail, "saveHikes")
    assert is_nil(rank_of(trail, "renderList"))
  end

  test "a repository that is not registered is not watched", ctx do
    assert {:error, :not_watched} = Trail.build("/nonexistent/repo", "x", ctx.opts)
  end
end
