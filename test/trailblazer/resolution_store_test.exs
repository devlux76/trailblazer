defmodule Trailblazer.ResolutionStoreTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Store

  setup do
    {:ok, repo} = Store.add_repo("/tmp/resolve-store-#{System.unique_integer([:positive])}")
    put(repo, "a.ts", "a", "b")
    put(repo, "b.ts", "b", nil)

    %{
      repo: repo,
      a: hd(Store.nodes_in_file(repo, "a.ts")),
      b: hd(Store.nodes_in_file(repo, "b.ts"))
    }
  end

  test "file mutations durably record revisions, source work and exact lookup memberships", %{
    repo: repo,
    a: a
  } do
    assert function_exported?(Store, :resolution_state, 1)
    state = Store.resolution_state(repo)
    assert state.revision == 2
    assert a.key in state.pending
    assert {:name, "typescript", "a"} in state.changed
    assert Store.resolution_readers(repo, [{:name, "typescript", "a"}]) == []

    assert [["a.ts", 1, 1], ["b.ts", 1, 0]] ==
             sql(
               "SELECT path,node_count,ref_count FROM resolve_path WHERE repo_id=? ORDER BY path",
               [repo]
             )

    assert [["a.ts"], ["b.ts"]] ==
             sql("SELECT suffix FROM resolve_file_suffix WHERE repo_id=? ORDER BY suffix", [repo])

    old_revision = state.revision
    put(repo, "a.ts", "a", "b")
    assert Store.resolution_state(repo).revision == old_revision
    Store.mark_stale(repo, "a.ts")
    assert Store.resolution_state(repo).revision == old_revision
  end

  test "scoped replacement leaves other sources intact and replay preserves edge identities", %{
    repo: repo,
    a: a,
    b: b
  } do
    Store.put_edges(repo, [edge(a, b), edge(b, a)])
    before_b = Store.edges_from(b.id)
    rev = Store.resolution_state(repo).revision
    batch = batch(a, [edge(a, b)], [{:source, a.key}, {:name, "typescript", "b"}])
    assert :ok = Store.replace_resolved_sources(repo, rev, batch)
    first = Store.edges_from(a.id)
    assert :ok = Store.replace_resolved_sources(repo, rev, batch)
    assert Store.edges_from(a.id) == first
    assert Store.edges_from(b.id) == before_b
    assert Store.resolution_readers(repo, [{:name, "typescript", "b"}]) == [a.key]
    assert :ok = Store.replace_resolved_sources(repo, rev, batch(a, [], [{:source, a.key}]))
    assert Store.edges_from(a.id) == []
    assert Store.edges_from(b.id) == before_b
  end

  test "unchanged full results retain coverage and rows across input revisions", %{
    repo: repo,
    a: a
  } do
    first = Trailblazer.Graph.Resolve.tracked(repo)
    assert :ok = Store.replace_resolved_sources(repo, first.revision, first)
    edges = Store.edges_from(a.id)
    coverage = sql("SELECT * FROM resolve_source WHERE repo_id=? ORDER BY owner_key", [repo])
    deps = sql("SELECT * FROM resolve_dependency ORDER BY 1,2", [])
    trigger = "resolve_unchanged_#{repo}"

    write_sql(
      "CREATE TRIGGER #{trigger} BEFORE INSERT ON resolve_dependency BEGIN SELECT RAISE(ABORT,'rewrote unchanged dependency'); END"
    )

    try do
      # Body changes advance graph revision but leave resolver inputs and outputs unchanged.
      n = %{a | text_hash: "body-only"}

      :ok =
        Store.replace_file(repo, "a.ts", %{
          hash: "body-only",
          nodes: [n],
          refs: [%{from_key: a.key, kind: "calls", target: "b", line: 1}]
        })

      result = Trailblazer.Graph.Resolve.tracked(repo)
      assert result.revision > first.revision
      assert :ok = Store.replace_resolved_sources(repo, result.revision, result)
      assert :ok = Store.replace_resolved_sources(repo, result.revision, result)
      assert Store.edges_from(a.id) == edges

      assert sql("SELECT * FROM resolve_source WHERE repo_id=? ORDER BY owner_key", [repo]) ==
               coverage

      assert sql("SELECT * FROM resolve_dependency ORDER BY 1,2", []) == deps
      assert Store.resolution_state(repo).pending == []
      assert Store.resolution_current?(repo)
    after
      write_sql("DROP TRIGGER #{trigger}")
    end
  end

  test "read-set-only changes update coverage and legacy edge writes invalidate fingerprints", %{
    repo: repo,
    a: a,
    b: b
  } do
    rev = Store.resolution_state(repo).revision
    one = batch(a, [edge(a, b)], [{:source, a.key}])
    assert :ok = Store.replace_resolved_sources(repo, rev, one)
    two = %{one | dependencies: %{a.key => [{:source, a.key}, {:exists, "missing.ts"}]}}
    assert :ok = Store.replace_resolved_sources(repo, rev, two)
    assert Store.resolution_readers(repo, [{:exists, "missing.ts"}]) == [a.key]
    Store.put_edges(repo, [])
    rev = Store.resolution_state(repo).revision
    assert :ok = Store.replace_resolved_sources(repo, rev, two)
    assert length(Store.edges_from(a.id)) == 1
    assert :ok = Store.replace_resolved_sources(repo, rev, batch(a, [], []))
    assert Store.resolution_readers(repo, [{:exists, "missing.ts"}]) == []
  end

  test "first coverage and read-set-only updates preserve already correct edge rows", %{
    repo: repo,
    a: a,
    b: b
  } do
    Store.put_edges(repo, [edge(a, b)])
    edges = Store.edges_from(a.id)
    rev = Store.resolution_state(repo).revision
    assert :ok = Store.replace_resolved_sources(repo, rev, batch(a, [edge(a, b)], []))
    assert Store.edges_from(a.id) == edges

    assert :ok =
             Store.replace_resolved_sources(
               repo,
               rev,
               batch(a, [edge(a, b)], [{:exists, "new-miss"}])
             )

    assert Store.edges_from(a.id) == edges
  end

  test "a full replay repairs an intervening scoped result", %{repo: repo, a: a} do
    full = Trailblazer.Graph.Resolve.tracked(repo)
    assert :ok = Store.replace_resolved_sources(repo, full.revision, full)
    assert :ok = Store.replace_resolved_sources(repo, full.revision, batch(a, [], []))
    assert Store.edges_from(a.id) == []
    assert :ok = Store.replace_resolved_sources(repo, full.revision, full)
    assert length(Store.edges_from(a.id)) == 1
  end

  test "stale revision, foreign endpoints, out-of-scope edges and incomplete coverage publish nothing",
       %{repo: repo, a: a, b: b} do
    Store.put_edges(repo, [edge(a, b)])
    rev = Store.resolution_state(repo).revision
    snapshot = Store.edges_from(a.id)
    {:ok, other} = Store.add_repo("/tmp/resolve-other-#{repo}")
    put(other, "other.ts", "other", nil)
    foreign = hd(Store.nodes_in_file(other, "other.ts"))

    for payload <- [
          batch(a, [edge(a, foreign)], []),
          batch(a, [edge(b, a)], []),
          %{batch(a, [], []) | dependencies: %{}}
        ] do
      assert {:error, _} = Store.replace_resolved_sources(repo, rev, payload)
      assert Store.edges_from(a.id) == snapshot
    end

    put(repo, "c.ts", "c", nil)
    assert {:error, :stale_revision} = Store.replace_resolved_sources(repo, rev, batch(a, [], []))
    assert Store.edges_from(a.id) == snapshot
  end

  test "file writes queue negative readers, preserve bindings with nil sources, and remove stale lookup rows",
       %{repo: repo, a: a} do
    rev = Store.resolution_state(repo).revision

    assert :ok =
             Store.replace_resolved_sources(
               repo,
               rev,
               batch(a, [], [{:exists, "pkg/a.ts"}, {:imports, "barrel.ts", "f"}])
             )

    node = node("pkg/a.ts", "f")
    refs = [%{from_key: nil, kind: "references", target: "./target#f", line: 1}]
    :ok = Store.replace_file(repo, "pkg/a.ts", %{hash: "one", nodes: [node], refs: []})
    assert a.key in Store.resolution_state(repo).pending
    :ok = Store.replace_file(repo, "barrel.ts", %{hash: "barrel", nodes: [], refs: refs})

    assert [["barrel.ts", "f", "./target#f"]] ==
             sql("SELECT path,member,target FROM resolve_import WHERE repo_id=?", [repo])

    assert [[0, 1]] ==
             sql(
               "SELECT node_count,ref_count FROM resolve_path WHERE repo_id=? AND path='barrel.ts'",
               [repo]
             )

    Store.delete_file(repo, "pkg/a.ts")

    assert [] ==
             sql("SELECT path FROM resolve_file_suffix WHERE repo_id=? AND path='pkg/a.ts'", [
               repo
             ])

    Store.delete_file(repo, "barrel.ts")
    assert [] == sql("SELECT path FROM resolve_import WHERE repo_id=?", [repo])
  end

  test "edge and dependency publication roll back together on SQL failure", %{
    repo: repo,
    a: a,
    b: b
  } do
    Store.put_edges(repo, [edge(a, b)])
    rev = Store.resolution_state(repo).revision
    old = Store.edges_from(a.id)
    before = Store.resolution_state(repo)
    trigger = "resolve_fail_#{repo}"

    write_sql(
      "CREATE TRIGGER #{trigger} BEFORE INSERT ON resolve_dependency WHEN (SELECT repo_id FROM resolve_source WHERE id=NEW.source_id)=#{repo} BEGIN SELECT RAISE(ABORT,'injected resolution failure'); END"
    )

    try do
      assert_raise Exqlite.Error, fn ->
        Store.replace_resolved_sources(repo, rev, batch(a, [], [{:source, a.key}]))
      end

      assert Store.edges_from(a.id) == old
      assert Store.resolution_state(repo) == before
    after
      write_sql("DROP TRIGGER #{trigger}")
    end
  end

  test "pending work and bindings survive a store restart", %{repo: repo} do
    before = Store.resolution_state(repo)
    :ok = Supervisor.terminate_child(Trailblazer.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(Trailblazer.Supervisor, Store)
    assert Store.resolution_state(repo) == before
    assert length(sql("SELECT path FROM resolve_path WHERE repo_id=?", [repo])) == 2
  end

  test "resolution metadata reads do not queue behind a held writer", %{repo: repo} do
    parent = self()

    writer =
      Task.async(fn ->
        request(:write, fn _conn ->
          send(parent, {:held_writer, self()})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:held_writer, holder}

    reader =
      Task.async(fn -> send(parent, {:resolution_read, Store.resolution_current?(repo)}) end)

    try do
      assert_receive {:resolution_read, false}
    after
      send(holder, :release)
      Task.await(writer, :infinity)
      Task.await(reader, :infinity)
    end
  end

  test "a failed lookup update rolls back the whole file mutation", %{repo: repo} do
    before = Store.graph_snapshot(repo)
    metadata = Store.resolution_state(repo)
    trigger = "resolve_file_fail_#{repo}"

    write_sql(
      "CREATE TRIGGER #{trigger} BEFORE INSERT ON resolve_path WHEN NEW.repo_id=#{repo} BEGIN SELECT RAISE(ABORT,'injected file metadata failure'); END"
    )

    try do
      assert_raise Exqlite.Error, fn -> put(repo, "a.ts", "changed", "new") end
      assert Store.graph_snapshot(repo) == before
      assert Store.resolution_state(repo) == metadata
    after
      write_sql("DROP TRIGGER #{trigger}")
    end
  end

  defp batch(a, edges, tokens),
    do: %{
      version: 1,
      sources: [a.key],
      edges: edges,
      dependencies: %{a.key => tokens},
      full: false
    }

  defp edge(a, b), do: %{from_id: a.id, to_id: b.id, kind: "calls", line: 1, uncertain: false}

  defp node(path, name),
    do: %{
      key: "typescript:function:#{path}##{name}",
      lang: "typescript",
      kind: "function",
      name: name,
      qualified: name,
      path: path,
      start_line: 1,
      end_line: 1,
      text_hash: name
    }

  defp put(repo, path, name, target) do
    n = node(path, name)
    refs = if target, do: [%{from_key: n.key, kind: "calls", target: target, line: 1}], else: []
    Store.replace_file(repo, path, %{hash: inspect({name, target}), nodes: [n], refs: refs})
  end

  defp sql(statement, args),
    do: request(:read, fn conn -> Exqlite.query!(conn, statement, args).rows end)

  defp write_sql(statement),
    do: request(:write, fn conn -> Exqlite.query!(conn, statement, []) end)

  defp request(mode, fun) do
    case GenServer.call(Store, {:run, mode, fun}, :infinity) do
      {:returned, value} -> value
      {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end
end
