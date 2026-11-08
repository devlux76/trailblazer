defmodule Trailblazer.StoreReadsTest do
  use ExUnit.Case, async: false

  alias Trailblazer.Store

  @store_key "elixir:module:lib/store.ex#Mini.Store"
  @put_key "elixir:function:lib/store.ex#Mini.Store.put/2"
  @run_key "elixir:function:lib/app.ex#Mini.App.run/0"

  setup do
    path = Path.join("/tmp/trailblazer-store-test", "repo-#{System.unique_integer([:positive])}")
    {:ok, repo_id} = Store.add_repo(path)
    %{repo_id: repo_id}
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
