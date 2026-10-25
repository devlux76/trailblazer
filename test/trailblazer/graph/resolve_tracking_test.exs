defmodule Trailblazer.Graph.ResolveTrackingTest do
  use ExUnit.Case, async: false
  alias Trailblazer.{Store, Graph.Resolve}

  setup do
    {:ok, repo} = Store.add_repo("/tmp/resolve-track-#{System.unique_integer([:positive])}")
    %{repo: repo}
  end

  test "tracked full resolve preserves the oracle and records misses through reexports", %{
    repo: repo
  } do
    put(repo, "app.ts", [node("app.ts", "run")], [
      ref("app.ts", "run", "./barrel#f"),
      ref("app.ts", "run", "missing")
    ])

    put(repo, "barrel.ts", [], [%{from_key: nil, kind: "references", target: "./leaf#f", line: 1}])

    put(repo, "leaf.ts", [node("leaf.ts", "f")], [])
    assert Code.ensure_loaded?(Resolve) and function_exported?(Resolve, :tracked, 1)
    result = Resolve.tracked(repo)
    assert result.edges == Resolve.edges(repo)
    tokens = result.dependencies[key("app.ts", "run")]

    for token <- [
          {:source, key("app.ts", "run")},
          {:exists, "barrel"},
          {:exists, "barrel.ts"},
          {:nodes, "barrel.ts"},
          {:imports, "barrel.ts", "f"},
          {:exists, "leaf.ts"},
          {:nodes, "leaf.ts"},
          {:imports, "leaf.ts", "f"},
          {:imports, "app.ts", "missing"},
          {:qualified, "missing"},
          {:name, "typescript", "missing"}
        ] do
      assert token in tokens, inspect(token)
    end

    assert :ok = Store.replace_resolved_sources(repo, result.revision, result)
    state = Store.resolution_state(repo)
    assert state.complete and state.version == 1 and state.lookup_version == 1
    assert state.pending == [] and state.changed == []
    assert state.resolved_revision == state.revision
    assert key("app.ts", "run") in Store.resolution_readers(repo, [{:imports, "leaf.ts", "f"}])

    assert result.dependencies |> Map.keys() |> Enum.sort() ==
             Store.resolution_dependencies(repo) |> Map.keys() |> Enum.sort()

    assert Store.resolution_current?(repo)
  end

  test "source misses, doc suffixes, C precedence and certainty lookups are traced", %{repo: repo} do
    put(repo, "app.ts", [node("app.ts", "run")], [
      %{ref("app.ts", "run", "design.md#2") | kind: "implements"},
      %{ref("app.ts", "gone", "x") | from_key: "missing-owner"}
    ])

    doc = %{
      node("nested/docs/design.md", "2")
      | kind: "doc_section",
        qualified: "nested/docs/design.md#2"
    }

    put(repo, doc.path, [doc], [])
    c = %{node("src/a.c", "main") | lang: "c"}
    put(repo, c.path, [c], [%{from_key: c.key, kind: "imports", target: "util.h", line: 1}])

    mod = %{
      node("include/util.h", "include/util.h")
      | kind: "module",
        qualified: "include/util.h",
        lang: "c"
    }

    put(repo, mod.path, [mod], [])
    result = Resolve.tracked(repo)
    assert result.edges == Resolve.edges(repo)
    assert {:source, "missing-owner"} in result.dependencies["missing-owner"]
    assert {:doc_suffix, "design.md#2"} in result.dependencies[key("app.ts", "run")]
    assert {:imports, "app.ts", "design.md#2"} in result.dependencies[key("app.ts", "run")]

    for token <- [
          {:exists, "src/util.h"},
          {:exists, "util.h"},
          {:file_suffix, "util.h"},
          {:nodes, "include/util.h"}
        ] do
      assert token in result.dependencies[c.key]
    end
  end

  test "incremental selection resolves only pending owners and preserves unrelated edges", %{
    repo: repo
  } do
    for n <- 1..40, do: put(repo, "pad/#{n}.ts", [node("pad/#{n}.ts", "pad#{n}")], [])
    put(repo, "a.ts", [node("a.ts", "a")], [ref("a.ts", "a", "b")])
    put(repo, "b.ts", [node("b.ts", "b")], [])
    baseline = Resolve.tracked(repo)
    :ok = Store.replace_resolved_sources(repo, baseline.revision, baseline)
    [a] = Store.nodes_in_file(repo, "a.ts")
    original_edges = Store.edges_from(a.id)
    put(repo, "b.ts", [%{node("b.ts", "b") | text_hash: "body edit"}], [])
    result = Resolve.next(repo)
    refute result.full
    assert result.sources == [key("b.ts", "b")]
    assert result.stats.refs == 0
    assert :ok = Store.replace_resolved_sources(repo, result.revision, result)
    assert Store.edges_from(a.id) == original_edges
    put(repo, "b.ts", [node("b.ts", "renamed")], [])
    result = Resolve.next(repo)
    refute result.full
    assert key("a.ts", "a") in result.sources
    assert :ok = Store.replace_resolved_sources(repo, result.revision, result)
    assert Store.edges_from(a.id) == []
    assert Store.resolution_current?(repo)
  end

  test "missing, incompatible and broad coverage uses the full fallback", %{repo: repo} do
    put(repo, "a.ts", [node("a.ts", "a")], [])
    result = Resolve.next(repo)
    assert result.full and result.stats.fallback == :coverage
    :ok = Store.replace_resolved_sources(repo, result.revision, result)
    put(repo, "a.ts", [node("a.ts", "renamed")], [])
    result = Resolve.next(repo)
    assert result.full and result.stats.fallback == :workload
  end

  test "seeded mutations satisfy oracle equality and the read-set completeness implication", %{
    repo: repo
  } do
    Process.put(:incremental_batches, 0)
    for n <- 1..48, do: put(repo, "pad/#{n}.ts", [node("pad/#{n}.ts", "pad#{n}")], [])

    for seed <- [17, 311, 902] do
      :rand.seed(:exsss, {seed, seed + 1, seed + 2})

      for n <- 1..5 do
        path = "s#{seed}/#{n}.ts"

        put(repo, path, [node(path, "f#{rem(n, 3)}")], [
          ref(path, "f#{rem(n, 3)}", "f#{rem(n + 1, 3)}")
        ])
      end

      initial = Resolve.tracked(repo)
      assert :ok = Store.replace_resolved_sources(repo, initial.revision, initial)

      Enum.reduce(1..16, initial, fn step, old ->
        path = "s#{seed}/#{:rand.uniform(5)}.ts"
        old_graph = Store.graph_snapshot(repo)

        if rem(step, 5) == 0 do
          Store.delete_file(repo, path)
        else
          name = "f#{:rand.uniform(3) - 1}"

          target =
            if rem(step, 3) == 0, do: "./#{:rand.uniform(5)}#f0", else: "f#{:rand.uniform(3) - 1}"

          put(repo, path, [node(path, name)], [
            %{ref(path, name, target) | ambiguous: rem(step, 7) == 0, line: step}
          ])
        end

        new = Resolve.tracked(repo)
        changed = MapSet.new(Store.resolution_state(repo).changed)
        local = for n <- old_graph.nodes, n.path == path, do: n.key
        local = MapSet.new(local ++ Enum.map(Store.nodes_in_file(repo, path), & &1.key))
        old_ids = Map.new(old_graph.nodes, &{&1.id, &1.key})
        new_ids = Map.new(Store.graph_snapshot(repo).nodes, &{&1.id, &1.key})

        for {owner, tokens} <- old.dependencies, not MapSet.member?(local, owner) do
          before = edges_for(old.edges, old_ids, owner)
          after_edges = edges_for(new.edges, new_ids, owner)

          if MapSet.disjoint?(MapSet.new(tokens), changed),
            do:
              assert(
                before == after_edges,
                "untracked change, seed #{seed}, step #{step}, source #{owner}"
              )

          if before != after_edges, do: assert(owner in Store.resolution_state(repo).pending)
        end

        assert MapSet.new(new.edges) == MapSet.new(Resolve.edges(repo))
        selected = Resolve.next(repo)

        if not selected.full,
          do: Process.put(:incremental_batches, Process.get(:incremental_batches) + 1)

        assert :ok = Store.replace_resolved_sources(repo, selected.revision, selected)

        assert Enum.flat_map(Store.graph_snapshot(repo).nodes, &Store.edges_from(&1.id))
               |> Enum.map(&Map.take(&1, [:from_id, :to_id, :kind, :line, :uncertain]))
               |> MapSet.new() == MapSet.new(new.edges)

        new
      end)
    end

    assert Process.get(:incremental_batches) >= 24
  end

  test "Elixir arity and containment keep their qualified dependency keys", %{repo: repo} do
    {:ok, parsed} =
      Trailblazer.Parse.Elixir.parse(
        "m.ex",
        "defmodule M do; def run, do: f(); def f, do: :ok; end"
      )

    :ok = Store.replace_file(repo, "m.ex", Map.put(parsed, :hash, "elixir"))
    tracked = Resolve.tracked(repo)
    assert tracked.edges == Resolve.edges(repo)
    [run] = Store.nodes_by_qualified(repo, "M.run/0")
    assert {:qualified, "M.f/0"} in tracked.dependencies[run.key]

    for ref <- Store.refs(repo), ref.kind == "contains" do
      assert {:qualified, ref.target} in tracked.dependencies[ref.from_key]
    end
  end

  test "a legacy lookup baseline is rebuilt without reparsing files", %{repo: repo} do
    put(repo, "legacy/a.ts", [node("legacy/a.ts", "a")], [ref("legacy/a.ts", "a", "missing")])
    before = Store.graph_snapshot(repo)

    {:returned, _} =
      GenServer.call(
        Store,
        {:run, :write,
         fn conn ->
           for table <- [
                 "resolve_path",
                 "resolve_file_suffix",
                 "resolve_doc_suffix",
                 "resolve_import"
               ] do
             Exqlite.query!(conn, "DELETE FROM #{table} WHERE repo_id=?", [repo])
           end
         end},
        :infinity
      )

    result = Resolve.tracked(repo)
    assert result.lookups != nil
    assert :ok = Store.replace_resolved_sources(repo, result.revision, result)
    assert Store.graph_snapshot(repo) == before
    assert Store.resolution_state(repo).lookup_version == 1

    {:returned, [["legacy/a.ts"]]} =
      GenServer.call(
        Store,
        {:run, :read,
         fn conn ->
           Exqlite.query!(conn, "SELECT path FROM resolve_path WHERE repo_id=?", [repo]).rows
         end},
        :infinity
      )
  end

  defp edges_for(edges, ids, owner),
    do: edges |> Enum.filter(&(ids[&1.from_id] == owner)) |> MapSet.new()

  defp key(path, name), do: "typescript:function:#{path}##{name}"

  defp node(path, name),
    do: %{
      key: key(path, name),
      lang: "typescript",
      kind: "function",
      name: name,
      qualified: name,
      path: path,
      start_line: 1,
      end_line: 1,
      text_hash: name,
      signature: name
    }

  defp ref(path, name, target),
    do: %{from_key: key(path, name), kind: "calls", target: target, line: 1, ambiguous: false}

  defp put(repo, path, nodes, refs),
    do: Store.replace_file(repo, path, %{hash: inspect({nodes, refs}), nodes: nodes, refs: refs})
end
