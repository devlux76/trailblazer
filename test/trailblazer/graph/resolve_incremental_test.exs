defmodule Trailblazer.Graph.ResolveIncrementalTest do
  use ExUnit.Case, async: false
  alias Trailblazer.{Store, Graph.Resolve}

  setup do
    {:ok, repo} = Store.add_repo("/tmp/incremental-#{System.unique_integer([:positive])}")
    # Enough untouched source groups that small adversarial batches stay below
    # the workload fallback. These definitions have no references.
    put(repo, "padding.ts", for(n <- 1..200, do: node("padding.ts", "pad#{n}")), [])
    %{repo: repo}
  end

  test "homonyms cross the cap, language families stay separate, missing sources and final refs recover",
       %{repo: r} do
    put(r, "caller.ts", [node("caller.ts", "run")], [ref("caller.ts", "run", "f")])
    baseline(r)

    for i <- 1..10 do
      path = "#{i}.ts"
      put(r, path, [node(path, "f")], [])
      check(r)
    end

    [caller] = Store.nodes_in_file(r, "caller.ts")
    assert length(Store.edges_from(caller.id)) == 8

    for i <- 1..10 do
      Store.delete_file(r, "#{i}.ts")
      check(r)
    end

    put(r, "py.py", [%{node("py.py", "f") | lang: "python"}], [])
    check(r)
    assert Store.edges_from(caller.id) == []
    put(r, "caller.ts", [node("caller.ts", "run")], [])
    check(r)
    put(r, "missing.ts", [], [ref("missing.ts", "missing", "f")])
    check(r)

    put(r, "missing.ts", [node("missing.ts", "missing"), node("missing.ts", "f")], [
      ref("missing.ts", "missing", "f")
    ])

    check(r)
  end

  test "negative import probes, JS precedence, transitive barrels and shared cached reads", %{
    repo: r
  } do
    for name <- ["a", "b"],
        do:
          put(r, "#{name}.ts", [node("#{name}.ts", name)], [ref("#{name}.ts", name, "./barrel#f")])

    put(r, "barrel.ts", [], [forwarding("./leaf#f")])
    put(r, "leaf/index.ts", [node("leaf/index.ts", "f")], [])
    baseline(r)

    for {path, nodes, refs} <- [
          {"leaf.ts", [node("leaf.ts", "f")], []},
          {"barrel.ts", [], [forwarding("./other#f")]},
          {"other.ts", [node("other.ts", "f")], [forwarding("./barrel#f")]},
          {"barrel.ts", [], [forwarding("./a#f")]},
          {"a.ts", [node("a.ts", "a"), node("a.ts", "f")], [ref("a.ts", "a", "./barrel#f")]}
        ] do
      put(r, path, nodes, refs)
      check(r)
    end

    Store.delete_file(r, "leaf.ts")
    check(r)
    put(r, "hash#part.ts", [node("hash#part.ts", "f")], [])
    put(r, "a.ts", [node("a.ts", "a")], [ref("a.ts", "a", "./hash#part#f")])
    check(r)
  end

  test "local imports hide global names and default-export eligibility is an input", %{repo: r} do
    put(r, "app.ts", [node("app.ts", "run")], [ref("app.ts", "run", "alias")])
    put(r, "global.ts", [node("global.ts", "alias")], [])
    put(r, "target.ts", [node("target.ts", "other")], [])
    baseline(r)

    put(r, "app.ts", [node("app.ts", "run")], [
      ref("app.ts", "run", "alias"),
      forwarding("./target#alias")
    ])

    check(r)
    put(r, "target.ts", [node("target.ts", "alias")], [])
    check(r)
    put(r, "app.ts", [node("app.ts", "run")], [ref("app.ts", "run", "./target#default")])
    check(r)

    put(
      r,
      "target.ts",
      [%{node("target.ts", "alias") | signature: "export default function alias()"}],
      []
    )

    check(r)
    put(r, "target.ts", [node("target.ts", "alias")], [])
    check(r)
  end

  test "Python precedence and escaping/external specs use exact indexed buckets", %{repo: r} do
    run = %{node("pkg/run.py", "run") | lang: "python"}
    put(r, run.path, [run], [ref(run.path, "run", "util#load")])
    put(r, "util.py", [%{node("util.py", "load") | lang: "python"}], [])
    baseline(r)
    put(r, "pkg/util.py", [%{node("pkg/util.py", "load") | lang: "python"}], [])
    check(r)
    Store.delete_file(r, "pkg/util.py")
    check(r)
    put(r, run.path, [run], [ref(run.path, "run", ".util#load")])
    check(r)
    put(r, "pkg/util/__init__.py", [%{node("pkg/util/__init__.py", "load") | lang: "python"}], [])
    check(r)

    put(r, "external.ts", [node("external.ts", "run")], [
      ref("external.ts", "run", "os#load"),
      ref("external.ts", "run", "../../escape#load")
    ])

    check(r)
  end

  test "C exact ref-only paths supersede suffixes; doc exact paths supersede suffix matches", %{
    repo: r
  } do
    c = %{node("src/a.c", "main") | lang: "c"}
    put(r, c.path, [c], [%{ref(c.path, "main", "util.h") | kind: "imports"}])
    header = fn path -> %{node(path, path) | lang: "cpp", kind: "module", qualified: path} end
    put(r, "include/util.h", [header.("include/util.h")], [])

    put(r, "app.ts", [node("app.ts", "run")], [
      %{ref("app.ts", "run", "design.md#2") | kind: "implements"}
    ])

    doc = fn path -> %{node(path, "section") | kind: "doc_section", qualified: path <> "#2"} end
    put(r, "nested/design.md", [doc.("nested/design.md")], [])
    baseline(r)

    for {path, ns, rs} <- [
          {"other/util.h", [header.("other/util.h")], []},
          {"util.h", [header.("util.h")], []},
          {"src/util.h", [], [forwarding("./missing#f")]},
          {"other/design.md", [doc.("other/design.md")], []},
          {"design.md", [doc.("design.md")], []},
          {"design.md", [], []}
        ] do
      put(r, path, ns, rs)
      check(r)
    end

    Store.delete_file(r, "src/util.h")
    check(r)
  end

  test "Elixir arity, line, ambiguity, stale/recovery and a multi-file undo batch", %{repo: r} do
    parse = fn text ->
      {:ok, parsed} = Trailblazer.Parse.Elixir.parse("m.ex", text)
      Store.replace_file(r, "m.ex", Map.put(parsed, :hash, text))
    end

    parse.("defmodule M do; def run, do: f(); def f, do: :ok; end")
    baseline(r)
    Store.mark_stale(r, "m.ex")
    check(r)
    parse.("defmodule M do\n def run, do: f(1)\n def f(x), do: x\nend")
    check(r)

    put(r, "line.ts", [node("line.ts", "run"), node("line.ts", "f")], [
      %{ref("line.ts", "run", "f") | line: nil, ambiguous: true}
    ])

    check(r)

    put(r, "line.ts", [node("line.ts", "run"), node("line.ts", "f")], [
      %{ref("line.ts", "run", "f") | line: 9}
    ])

    put(r, "undo.ts", [node("undo.ts", "f")], [])
    Store.delete_file(r, "undo.ts")
    check(r)
  end

  test "coverage/version gates and a broken mutation ledger take full fallback", %{repo: r} do
    baseline(r)

    for {column, value} <- [{"complete", 0}, {"version", 0}, {"lookup_version", 0}] do
      sql(:write, fn c ->
        Exqlite.query!(c, "UPDATE resolve_revision SET #{column}=? WHERE repo_id=?", [value, r])
      end)

      result = Resolve.next(r)
      assert result.full and result.stats.fallback == :coverage
      :ok = Store.replace_resolved_sources(r, result.revision, result)
    end

    sql(:write, fn c ->
      Exqlite.query!(c, "UPDATE resolve_revision SET revision=revision+1 WHERE repo_id=?", [r])
    end)

    result = Resolve.next(r)
    assert result.full and result.stats.fallback == :ledger_gap
  end

  test "lookup volume is bounded even when only one source is pending", %{repo: r} do
    for name <- ["f", "g", "h"] do
      nodes = for i <- 1..90, do: %{node("#{name}.ts", name) | key: "#{name}:#{i}"}
      put(r, "#{name}.ts", nodes, [])
    end

    refs = for name <- ["f", "g", "h"], do: ref("app.ts", "run", name)
    put(r, "app.ts", [node("app.ts", "run")], refs)
    baseline(r)
    put(r, "app.ts", [%{node("app.ts", "run") | text_hash: "new body"}], refs)
    result = Resolve.next(r)
    assert result.full and result.stats.fallback == :lookup_volume
    assert MapSet.new(result.edges) == MapSet.new(Resolve.edges(r))
  end

  test "negative lookup probes are bounded even when they return no rows", %{repo: r} do
    refs = for n <- 1..80, do: ref("app.ts", "run", "missing#{n}")
    put(r, "app.ts", [node("app.ts", "run")], refs)
    baseline(r)
    put(r, "app.ts", [%{node("app.ts", "run") | text_hash: "body"}], refs)
    result = Resolve.next(r)
    assert result.full and result.stats.fallback == :lookup_volume
  end

  test "a small source set with many refs takes the workload fallback before fetching them", %{
    repo: r
  } do
    refs = for line <- 1..129, do: %{ref("app.ts", "run", "missing") | line: line}
    put(r, "app.ts", [node("app.ts", "run")], refs)
    baseline(r)
    put(r, "app.ts", [%{node("app.ts", "run") | text_hash: "body"}], refs)
    result = Resolve.next(r)
    assert result.full and result.stats.fallback == :workload
  end

  test "wildcard characters are literal and other repositories cannot add candidates", %{repo: r} do
    put(r, "app.ts", [node("app.ts", "run")], [ref("app.ts", "run", "f%_")])
    put(r, "local.ts", [node("local.ts", "f%_")], [])
    baseline(r)
    {:ok, other} = Store.add_repo("/tmp/incremental-other-#{r}")
    put(other, "other.ts", [node("other.ts", "f%_")], [])

    put(r, "app.ts", [%{node("app.ts", "run") | text_hash: "body"}], [ref("app.ts", "run", "f%_")])

    check(r)
    [run] = Store.nodes_in_file(r, "app.ts")
    [target] = Store.nodes_in_file(r, "local.ts")
    assert [%{to_id: id}] = Store.edges_from(run.id)
    assert id == target.id
  end

  test "one coherent snapshot stays old while another transaction mutates and CAS preserves pending",
       %{repo: r} do
    put(r, "app.ts", [node("app.ts", "run")], [])
    baseline(r)
    put(r, "app.ts", [%{node("app.ts", "run") | text_hash: "body"}], [])
    parent = self()

    task =
      Task.async(fn ->
        Store.resolution_selected(r, fn plan, lookup ->
          send(parent, {:snapshot, self()})
          receive do: (:continue -> :ok)
          assert lookup.({:qualified, "run"}, 100) != []
          assert lookup.({:qualified, "renamed"}, 100) == []

          assert catch_throw(lookup.({:unregistered, "token"}, 100)) ==
                   {:resolve_fallback, :untrackable_lookup}

          %{
            revision: plan.revision,
            version: 1,
            sources: plan.sources,
            edges: [],
            dependencies: Map.new(plan.sources, &{&1, []}),
            full: false
          }
        end)
      end)

    assert_receive {:snapshot, reader}

    try do
      put(r, "app.ts", [node("app.ts", "renamed")], [])
    after
      send(reader, :continue)
    end

    old = Task.await(task, :infinity)
    pending = Store.resolution_state(r).pending
    assert {:error, :stale_revision} = Store.replace_resolved_sources(r, old.revision, old)
    assert Store.resolution_state(r).pending == pending
    check(r)
  end

  test "scoped save failure rolls back and pending survives restart before a successful replay",
       %{repo: r} do
    put(r, "app.ts", [node("app.ts", "run"), node("app.ts", "f")], [ref("app.ts", "run", "f")])
    baseline(r)

    put(r, "app.ts", [node("app.ts", "run"), node("app.ts", "f")], [
      %{ref("app.ts", "run", "f") | line: 2}
    ])

    pending = Store.resolution_state(r).pending
    :ok = Supervisor.terminate_child(Trailblazer.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(Trailblazer.Supervisor, Store)
    assert Store.resolution_state(r).pending == pending
    result = Resolve.next(r)
    refute result.full
    trigger = "incremental_fail_#{r}"

    sql(:write, fn c ->
      Exqlite.query!(
        c,
        "CREATE TRIGGER #{trigger} BEFORE INSERT ON resolve_dependency WHEN (SELECT repo_id FROM resolve_source WHERE id=NEW.source_id)=#{r} BEGIN SELECT RAISE(ABORT,'scoped failure'); END",
        []
      )
    end)

    try do
      assert_raise Exqlite.Error, fn ->
        Store.replace_resolved_sources(r, result.revision, result)
      end

      assert Store.resolution_state(r).pending == pending
    after
      sql(:write, fn c -> Exqlite.query!(c, "DROP TRIGGER #{trigger}", []) end)
    end

    assert :ok = Store.replace_resolved_sources(r, result.revision, result)
    assert :ok = Store.replace_resolved_sources(r, result.revision, result)
    check(r)
  end

  test "incremental resolve and publication never request a full graph or rebuild its index", %{
    repo: r
  } do
    put(r, "app.ts", [node("app.ts", "run")], [ref("app.ts", "run", "f")])
    baseline(r)
    put(r, "app.ts", [node("app.ts", "run")], [ref("app.ts", "run", "new")])

    functions = [
      {Store, :graph_snapshot, 1},
      {Store, :resolution_snapshot, 1},
      {Trailblazer.Graph.Inputs, :index, 1}
    ]

    for fun <- functions, do: :erlang.trace_pattern(fun, true, [:local])
    :erlang.trace(:all, true, [:call])

    try do
      result = Resolve.next(r)
      refute result.full
      assert result.stats.refs == 1
      assert :ok = Store.replace_resolved_sources(r, result.revision, result)
    after
      :erlang.trace(:all, false, [:call])
      for fun <- functions, do: :erlang.trace_pattern(fun, false, [:local])
    end

    refute_receive {:trace, _, :call, _}, 0
  end

  defp sql(mode, fun) do
    case GenServer.call(Store, {:run, mode, fun}, :infinity) do
      {:returned, value} -> value
      {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  defp baseline(repo) do
    full = Resolve.tracked(repo)
    :ok = Store.replace_resolved_sources(repo, full.revision, full)
  end

  defp check(repo) do
    expected = MapSet.new(Resolve.edges(repo))
    # This also ensures the tests don't silently exercise only the fallback.
    selected = Resolve.next(repo)
    refute selected.full
    assert :ok = Store.replace_resolved_sources(repo, selected.revision, selected)

    actual =
      Store.graph_snapshot(repo).nodes
      |> Enum.flat_map(&Store.edges_from(&1.id))
      |> Enum.map(&Map.take(&1, [:from_id, :to_id, :kind, :line, :uncertain]))
      |> MapSet.new()

    assert actual == expected
    assert Store.resolution_current?(repo)
  end

  defp node(path, name),
    do: %{
      key: key(path, name),
      path: path,
      name: name,
      qualified: name,
      lang: "typescript",
      kind: "function",
      signature: name,
      start_line: 1,
      end_line: 1,
      text_hash: name
    }

  defp key(path, name), do: "typescript:function:#{path}##{name}"

  defp ref(path, name, target),
    do: %{
      from_key: key(path, name),
      kind: "calls",
      target: target,
      line: 1,
      arity: nil,
      ambiguous: false
    }

  defp forwarding(target),
    do: %{from_key: nil, kind: "references", target: target, line: 1, ambiguous: false}

  defp put(repo, path, nodes, refs),
    do: Store.replace_file(repo, path, %{hash: inspect({nodes, refs}), nodes: nodes, refs: refs})
end
