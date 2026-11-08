defmodule Trailblazer.StoreVectorsTest do
  use ExUnit.Case, async: false

  alias Trailblazer.Store

  @store_key "elixir:module:lib/store.ex#Mini.Store"
  @put_key "elixir:function:lib/store.ex#Mini.Store.put/2"

  setup do
    path = Path.join("/tmp/trailblazer-store-test", "repo-#{System.unique_integer([:positive])}")
    {:ok, repo_id} = Store.add_repo(path)
    %{repo_id: repo_id}
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
end
