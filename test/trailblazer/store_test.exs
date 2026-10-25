defmodule Trailblazer.StoreTest do
  use ExUnit.Case, async: false

  alias Trailblazer.Store

  @store_key "elixir:module:lib/store.ex#Mini.Store"
  @put_key "elixir:function:lib/store.ex#Mini.Store.put/2"
  @app_key "elixir:module:lib/app.ex#Mini.App"
  @run_key "elixir:function:lib/app.ex#Mini.App.run/0"

  setup do
    path = Path.join("/tmp/trailblazer-store-test", "repo-#{System.unique_integer([:positive])}")
    {:ok, repo_id} = Store.add_repo(path)
    %{repo_id: repo_id}
  end

  test "absolute, dotted, relative and symlinked repo paths share one id" do
    root = Path.join(System.tmp_dir!(), "trailblazer-canonical-#{System.os_time(:nanosecond)}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    File.mkdir_p!(Path.join(repo, "nested"))
    File.ln_s!("repo", Path.join(root, "linked"))
    File.ln_s!("repo/nested", Path.join(root, "nested_link"))
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, id} = Store.add_repo(repo)
    assert {:ok, ^id} = Store.add_repo(repo <> "/.")
    assert {:ok, ^id} = Store.add_repo(Path.join(root, "linked"))
    assert {:ok, ^id} = Store.add_repo(Path.join(root, "nested_link/.."))
    assert {:ok, ^id} = File.cd!(root, fn -> Store.add_repo("repo") end)
    assert [%{id: ^id, path: ^repo}] = Enum.filter(Store.repos(), &(&1.id == id))
  end

  test "a foreign edge endpoint is refused without replacing existing edges", %{repo_id: repo} do
    :ok = replace(repo, "lib/store.ex", "h", [node_attrs(@store_key)], [])
    [local] = Store.nodes_in_file(repo, "lib/store.ex")
    {:ok, other_repo} = Store.add_repo("/tmp/foreign-#{System.unique_integer([:positive])}")
    :ok = replace(other_repo, "lib/store.ex", "h", [node_attrs(@store_key)], [])
    [foreign] = Store.nodes_in_file(other_repo, "lib/store.ex")
    edge = %{from_id: local.id, to_id: local.id, kind: "calls", uncertain: false}
    assert :ok = Store.put_edges(repo, [edge])
    before = Store.edges_from(local.id)

    for bad <- [%{edge | to_id: foreign.id}, %{edge | from_id: foreign.id}] do
      assert {:error, {:foreign_node, id}} = Store.put_edges(repo, [edge, bad])
      assert id == foreign.id
      assert Store.edges_from(local.id) == before
    end
  end

  test "batched graph reads retain every node and exclude foreign repository links", %{
    repo_id: repo
  } do
    nodes = for i <- 1..805, do: node_attrs("elixir:function:lib/big.ex#Big.f#{i}/0")
    assert :ok = replace(repo, "lib/big.ex", "large", nodes, [])
    ids = repo |> Store.nodes_in_file("lib/big.ex") |> Enum.map(& &1.id)
    assert Store.nodes([]) == []
    assert MapSet.new(Enum.map(Store.nodes(ids ++ ids), & &1.id)) == MapSet.new(ids)

    {:ok, foreign_repo} =
      Store.add_repo("/tmp/foreign-graph-#{System.unique_integer([:positive])}")

    assert :ok = replace(foreign_repo, "lib/big.ex", "other", Enum.take(nodes, 2), [])
    [foreign, other] = Store.nodes_in_file(foreign_repo, "lib/big.ex")

    assert :ok =
             Store.put_edges(foreign_repo, [
               %{from_id: foreign.id, to_id: other.id, kind: "calls", uncertain: false}
             ])

    first = hd(ids)
    last = List.last(ids)
    edge = %{from_id: first, to_id: last, kind: "calls", uncertain: true}
    assert :ok = Store.put_edges(repo, [Map.put(edge, :line, 1), Map.put(edge, :line, 2)])
    assert Store.adjacent_edges(repo, ids ++ [foreign.id]) == [edge]
    assert Store.adjacent_edges(repo, [foreign.id]) == []
    assert Store.adjacent_edges(repo, []) == []
  end

  test "adjacent edges can leave out uncertain calls from sites with too many targets", %{
    repo_id: repo
  } do
    nodes =
      for name <- ~w(caller wide1 wide2 wide3 narrow1 narrow2 sure) do
        %{
          key: "elixir:function:g.ex#M.#{name}/0",
          lang: "elixir",
          kind: "function",
          name: name,
          qualified: "M.#{name}/0",
          path: "g.ex",
          start_line: 1,
          end_line: 1,
          signature: "def #{name}",
          text_hash: name
        }
      end

    assert :ok = Store.replace_file(repo, "g.ex", %{hash: "g", nodes: nodes, refs: []})
    id = Map.new(Store.nodes_in_file(repo, "g.ex"), &{&1.name, &1.id})

    call = fn to, line, uncertain ->
      %{from_id: id["caller"], to_id: id[to], kind: "calls", uncertain: uncertain, line: line}
    end

    # Line 1 resolves to three candidates, line 2 to two, line 3 to one certain target.
    assert :ok =
             Store.put_edges(repo, [
               call.("wide1", 1, true),
               call.("wide2", 1, true),
               call.("wide3", 1, true),
               call.("narrow1", 2, true),
               call.("narrow2", 2, true),
               call.("sure", 3, false)
             ])

    targets = fn edges -> edges |> Enum.map(& &1.to_id) |> Enum.sort() end
    narrow = targets.(Enum.map(~w(narrow1 narrow2 sure), &%{to_id: id[&1]}))
    everything = targets.(Enum.map(~w(wide1 wide2 wide3 narrow1 narrow2 sure), &%{to_id: id[&1]}))

    assert targets.(Store.adjacent_edges(repo, [id["caller"]], max_targets: 2)) == narrow
    # Reached from the callee's side, the site is still judged by all its targets.
    assert Store.adjacent_edges(repo, [id["wide2"]], max_targets: 2) == []
    assert targets.(Store.adjacent_edges(repo, [id["caller"]])) == everything
  end

  test "a leading tilde repo path expands to the user home" do
    name = "trailblazer-missing-#{System.unique_integer([:positive])}"
    assert {:ok, id} = Store.add_repo(Path.join(System.user_home!(), name))
    assert {:ok, ^id} = Store.add_repo("~/" <> name)
  end

  test "a repo gets one id per path", %{repo_id: repo_id} do
    path = Enum.find(Store.repos(), &(&1.id == repo_id)).path

    assert {:ok, ^repo_id} = Store.add_repo(path)
  end

  test "ambiguous parser targets survive a real store round trip", %{repo_id: repo_id} do
    {:ok, parsed} =
      Trailblazer.Parse.Elixir.parse(
        "a.ex",
        "defmodule M do\n import Foo\n import Bar\n def run, do: f()\nend"
      )

    assert :ok = Store.replace_file(repo_id, "a.ex", Map.put(parsed, :hash, "file-hash"))

    assert [
             %{target: "Foo.f", ambiguous: true, from_key: "elixir:function:a.ex#M.run/0"},
             %{target: "Bar.f", ambiguous: true, from_key: "elixir:function:a.ex#M.run/0"}
           ] = Enum.filter(Store.refs(repo_id), &(&1.kind == "calls"))

    assert Enum.all?(
             Enum.reject(Store.refs(repo_id), &(&1.kind == "calls")),
             &(&1.ambiguous == false)
           )
  end

  test "a list target is refused before any replacement is written", %{repo_id: repo_id} do
    old = ref(@store_key, "calls", "Old.f", 0, 1)
    :ok = replace(repo_id, "lib/store.ex", "old", [node_attrs(@store_key)], [old])
    bad = ref(@store_key, "calls", ["Foo.f", "Bar.f"], 0, 2)

    assert {:error, {:bad_ref_target, ^bad}} =
             replace(
               repo_id,
               "lib/store.ex",
               "new",
               [node_attrs(@store_key, text_hash: "changed"), node_attrs(@put_key)],
               [ref(@store_key, "calls", "New.f", 0, 1), bad]
             )

    assert [%{key: @store_key, text_hash: "hash-" <> _}] =
             Store.nodes_in_file(repo_id, "lib/store.ex")

    assert [%{target: "Old.f", ambiguous: false}] = Store.refs(repo_id)
  end

  test "replacing a file keeps a node's id and takes its new text hash", %{repo_id: repo_id} do
    :ok = replace(repo_id, "lib/store.ex", "file-1", [node_attrs(@store_key)], [])

    assert [%{id: id, text_hash: "hash-" <> _}] = Store.nodes_in_file(repo_id, "lib/store.ex")

    :ok =
      replace(
        repo_id,
        "lib/store.ex",
        "file-2",
        [node_attrs(@store_key, text_hash: "hash-after-the-edit")],
        []
      )

    assert [%{id: ^id, text_hash: "hash-after-the-edit"}] =
             Store.nodes_in_file(repo_id, "lib/store.ex")
  end

  test "replacing a file drops what it no longer holds and leaves other files alone", %{
    repo_id: repo_id
  } do
    :ok =
      replace(
        repo_id,
        "lib/store.ex",
        "file-1",
        [node_attrs(@store_key), node_attrs(@put_key)],
        [ref(@store_key, "references", "Mini.App", nil, 2)]
      )

    :ok =
      replace(
        repo_id,
        "lib/app.ex",
        "file-1",
        [node_attrs(@app_key)],
        [ref(@app_key, "calls", "Mini.Store.put", 2, 4)]
      )

    :ok =
      replace(
        repo_id,
        "lib/store.ex",
        "file-2",
        [node_attrs(@store_key)],
        [ref(@store_key, "calls", "Mini.App.run", 0, 6)]
      )

    assert [%{key: @store_key}] = Store.nodes_in_file(repo_id, "lib/store.ex")
    assert [%{key: @app_key}] = Store.nodes_in_file(repo_id, "lib/app.ex")

    assert [
             %{from_key: @app_key, kind: "calls", target: "Mini.Store.put", arity: 2, line: 4},
             %{from_key: @store_key, kind: "calls", target: "Mini.App.run", arity: 0, line: 6}
           ] = Store.refs(repo_id) |> Enum.sort_by(& &1.line)
  end

  test "deleting a file takes its nodes, its refs and every edge to or from them", %{
    repo_id: repo_id
  } do
    :ok = replace(repo_id, "lib/store.ex", "file-1", [node_attrs(@store_key)], [])

    :ok =
      replace(repo_id, "lib/app.ex", "file-1", [node_attrs(@app_key)], [
        ref(@app_key, "calls", "Mini.Store", nil, 4)
      ])

    [store] = Store.nodes_in_file(repo_id, "lib/store.ex")
    [app] = Store.nodes_in_file(repo_id, "lib/app.ex")

    :ok =
      Store.put_edges(repo_id, [
        %{from_id: app.id, to_id: store.id, kind: "calls", uncertain: false, line: 4}
      ])

    assert [%{from_id: from_id, to_id: to_id, kind: "calls", uncertain: false, line: 4}] =
             Store.edges_from([app.id], ["calls"])

    assert from_id == app.id
    assert to_id == store.id

    :ok = Store.delete_file(repo_id, "lib/store.ex")

    assert Store.nodes_in_file(repo_id, "lib/store.ex") == []
    assert [%{key: @app_key}] = Store.nodes_in_file(repo_id, "lib/app.ex")
    assert [%{from_key: @app_key}] = Store.refs(repo_id)
    assert Store.edges_from([app.id], ["calls"]) == []
    assert Store.edges_to([app.id], ["calls"]) == []
    assert Store.edges_to([app.id]) == []
  end

  test "mark_stale marks one file's nodes, and the next replace of that file clears it", %{
    repo_id: repo_id
  } do
    :ok = replace(repo_id, "lib/store.ex", "file-1", [node_attrs(@store_key)], [])
    :ok = replace(repo_id, "lib/app.ex", "file-1", [node_attrs(@app_key)], [])

    :ok = Store.mark_stale(repo_id, "lib/store.ex")

    assert [%{stale: true}] = Store.nodes_in_file(repo_id, "lib/store.ex")
    assert [%{stale: false}] = Store.nodes_in_file(repo_id, "lib/app.ex")

    :ok =
      replace(
        repo_id,
        "lib/store.ex",
        "file-2",
        [node_attrs(@store_key, text_hash: "hash-after-the-fix")],
        []
      )

    assert [%{stale: false, text_hash: "hash-after-the-fix"}] =
             Store.nodes_in_file(repo_id, "lib/store.ex")
  end

  test "pending_vectors are the nodes whose vector is not their current text", %{repo_id: repo_id} do
    :ok =
      replace(
        repo_id,
        "lib/store.ex",
        "file-1",
        [node_attrs(@store_key), node_attrs(@put_key)],
        []
      )

    assert [%{key: @put_key}, %{key: @store_key}] =
             repo_id |> Store.pending_vectors(10) |> Enum.sort_by(& &1.key)

    [store_node] = Store.nodes_by_qualified(repo_id, "Mini.Store")
    :ok = Store.vector_done([{store_node.id, store_node.text_hash}])

    assert [%{key: @put_key}] = Store.pending_vectors(repo_id, 10)

    :ok =
      replace(
        repo_id,
        "lib/store.ex",
        "file-2",
        [node_attrs(@store_key, text_hash: "hash-after-the-edit"), node_attrs(@put_key)],
        []
      )

    assert [
             %{key: @put_key},
             %{
               key: @store_key,
               text_hash: "hash-after-the-edit",
               vector_hash: "hash-" <> @store_key
             }
           ] = repo_id |> Store.pending_vectors(10) |> Enum.sort_by(& &1.key)
  end

  test "a node changed while its vector was in flight stays pending", %{repo_id: repo_id} do
    :ok = replace(repo_id, "lib/store.ex", "file-1", [node_attrs(@store_key)], [])

    assert [%{id: id} = read] = Store.pending_vectors(repo_id, 10)

    # the worker is holding the node it read; the file is indexed again under it
    :ok =
      replace(
        repo_id,
        "lib/store.ex",
        "file-2",
        [node_attrs(@store_key, text_hash: "hash-after-the-edit")],
        []
      )

    assert %{id: ^id, text_hash: "hash-after-the-edit"} = Store.node(id)

    # the vector that comes back is the one of the text the worker read
    :ok = Store.vector_done([{id, read.text_hash}])

    assert [%{id: ^id, text_hash: "hash-after-the-edit", vector_hash: hash}] =
             Store.pending_vectors(repo_id, 10)

    assert hash == read.text_hash

    :ok = Store.vector_done([{id, "hash-after-the-edit"}])

    assert [] = Store.pending_vectors(repo_id, 10)
  end

  test "pending_vectors stops at the limit it is given", %{repo_id: repo_id} do
    :ok =
      replace(
        repo_id,
        "lib/store.ex",
        "file-1",
        [node_attrs(@store_key), node_attrs(@put_key)],
        []
      )

    assert [%{key: @store_key}] = Store.pending_vectors(repo_id, 1)
  end

  test "reads find nodes by name and by qualified name", %{repo_id: repo_id} do
    :ok =
      replace(
        repo_id,
        "lib/store.ex",
        "file-1",
        [node_attrs(@store_key), node_attrs(@put_key)],
        []
      )

    assert [%{key: @store_key}] = Store.nodes_by_name(repo_id, "Store")
    assert [%{key: @put_key, name: "put"}] = Store.nodes_by_name(repo_id, "put")
    assert [%{key: @put_key}] = Store.nodes_by_qualified(repo_id, "Mini.Store.put/2")
    assert [] = Store.nodes_by_qualified(repo_id, "Mini.Store.put/3")
  end

  test "reads find edges by kind and in both directions", %{repo_id: repo_id} do
    :ok =
      replace(
        repo_id,
        "lib/store.ex",
        "file-1",
        [node_attrs(@store_key), node_attrs(@put_key)],
        [ref(@put_key, "implements", "docs/design.md#2", nil, 8)]
      )

    :ok =
      replace(
        repo_id,
        "lib/app.ex",
        "file-1",
        [node_attrs(@run_key)],
        [ref(@run_key, "calls", "Mini.Store.put/2", 2, 4)]
      )

    [store] = Store.nodes_by_qualified(repo_id, "Mini.Store")
    [put] = Store.nodes_by_qualified(repo_id, "Mini.Store.put/2")
    [run] = Store.nodes_by_qualified(repo_id, "Mini.App.run/0")

    :ok =
      Store.put_edges(repo_id, [
        %{from_id: run.id, to_id: put.id, kind: "calls", uncertain: false, line: 4},
        %{from_id: put.id, to_id: store.id, kind: "contains", uncertain: true, line: 8}
      ])

    assert [%{from_id: from_id, to_id: to_id, kind: "calls", uncertain: false, line: 4}] =
             Store.edges_from([run.id], ["calls"])

    assert from_id == run.id
    assert to_id == put.id

    assert [%{to_id: to_id, kind: "contains", uncertain: true, line: 8}] =
             Store.edges_to([store.id], ["contains"])

    assert to_id == store.id
    assert length(Store.edges_from([run.id, put.id])) == 2
    assert Store.edges_from([run.id], ["implements"]) == []
  end

  test "put_edges replaces the repo's edges", %{repo_id: repo_id} do
    :ok =
      replace(
        repo_id,
        "lib/store.ex",
        "file-1",
        [node_attrs(@store_key), node_attrs(@put_key)],
        []
      )

    :ok = replace(repo_id, "lib/app.ex", "file-1", [node_attrs(@run_key)], [])

    [store] = Store.nodes_by_qualified(repo_id, "Mini.Store")
    [put] = Store.nodes_by_qualified(repo_id, "Mini.Store.put/2")
    [run] = Store.nodes_by_qualified(repo_id, "Mini.App.run/0")

    :ok =
      Store.put_edges(repo_id, [
        %{from_id: run.id, to_id: put.id, kind: "calls", uncertain: false, line: 4}
      ])

    :ok =
      Store.put_edges(repo_id, [
        %{from_id: put.id, to_id: store.id, kind: "contains", uncertain: false, line: 1}
      ])

    assert Store.edges_from([run.id], ["calls"]) == []

    assert [%{kind: "contains", from_id: from_id, to_id: to_id}] =
             Store.edges_from([put.id], ["contains"])

    assert from_id == put.id
    assert to_id == store.id
  end

  test "refs carry the node they come from, by id as well as by key", %{repo_id: repo_id} do
    :ok =
      replace(
        repo_id,
        "lib/app.ex",
        "file-1",
        [node_attrs(@run_key)],
        [ref(@run_key, "calls", "Mini.Store.put/2", 2, 4)]
      )

    [run] = Store.nodes_by_qualified(repo_id, "Mini.App.run/0")

    assert [
             %{
               from_key: @run_key,
               from_id: from_id,
               kind: "calls",
               target: "Mini.Store.put/2",
               arity: 2,
               line: 4
             }
           ] =
             Store.refs(repo_id)

    assert from_id == run.id
  end

  test "refs outside a definition are kept with no node id", %{repo_id: repo_id} do
    :ok =
      replace(
        repo_id,
        "lib/app.ex",
        "file-1",
        [node_attrs(@run_key)],
        [ref(nil, "implements", "docs/design.md#6", nil, 1)]
      )

    assert [%{from_key: nil, from_id: nil, target: "docs/design.md#6"}] = Store.refs(repo_id)
  end

  # E19: llama.cpp's 178k edges, one insert each, ran past the connection's
  # timeout and took the Store down. Edges go in batches; every one lands.
  test "E19: many edges are written in batches, all of them, replacing the old", %{repo_id: repo} do
    nodes = for i <- 1..60, do: node_attrs("elixir:function:lib/big.ex#Big.f#{i}/0")
    :ok = replace(repo, "lib/big.ex", "h", nodes, [])
    ids = repo |> Store.nodes_in_file("lib/big.ex") |> Enum.map(& &1.id)

    edges =
      for from <- ids,
          to <- ids,
          from != to,
          do: %{from_id: from, to_id: to, kind: "calls", uncertain: false, line: 1}

    assert length(edges) == 3540
    {us, :ok} = :timer.tc(fn -> Store.put_edges(repo, edges) end)
    assert length(Store.edges_from(ids)) == 3540
    assert us < 10_000_000

    :ok = Store.put_edges(repo, Enum.take(edges, 501))
    assert length(Store.edges_from(ids)) == 501
  end

  defp replace(repo_id, path, hash, nodes, refs) do
    Store.replace_file(repo_id, path, %{hash: hash, nodes: nodes, refs: refs})
  end

  defp node_attrs(key, attrs \\ []) do
    [lang, kind, rest] = String.split(key, ":", parts: 3)
    [path, qualified] = String.split(rest, "#", parts: 2)

    Map.merge(
      %{
        key: key,
        lang: lang,
        kind: kind,
        name: name_of(qualified),
        qualified: qualified,
        path: path,
        start_line: 1,
        end_line: 2,
        signature: "def #{qualified}",
        text_hash: "hash-" <> key
      },
      Map.new(attrs)
    )
  end

  defp name_of(qualified) do
    qualified
    |> String.split(".")
    |> List.last()
    |> String.split("/")
    |> hd()
  end

  defp ref(from_key, kind, target, arity, line) do
    %{from_key: from_key, kind: kind, target: target, arity: arity, line: line}
  end
end
