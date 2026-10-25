defmodule Trailblazer.EmbedCacheTest do
  use ExUnit.Case, async: false
  alias Trailblazer.{Indexer, Store}

  defmodule Embed do
    def documents(docs, opts) do
      send(opts[:observer], {:cache_embed, docs})

      if opts[:fail],
        do: {:error, :embedder_down},
        else: {:ok, Enum.map(docs, fn _ -> List.duplicate(0.25, 768) end)}
    end
  end

  defmodule Vectors do
    def ensure(_, _), do: :ok
    def delete(_, _, _), do: :ok

    def put(repo, points, opts) do
      send(opts[:observer], {:cache_points, repo, points})
      :ok
    end
  end

  test "identical definitions in different repos share cached float32 vectors; a changed model misses" do
    root = Path.join(System.tmp_dir!(), "trailblazer-cache-#{System.unique_integer([:positive])}")
    dirs = for i <- 1..3, do: root <> "-#{i}"
    prior = Application.fetch_env(:trailblazer, :embed_model)

    on_exit(fn ->
      for dir <- dirs do
        if pid = Indexer.whereis(dir), do: GenServer.stop(pid)
        File.rm_rf!(dir)
      end

      case prior do
        {:ok, value} -> Application.put_env(:trailblazer, :embed_model, value)
        :error -> Application.delete_env(:trailblazer, :embed_model)
      end
    end)

    opts = [filesystem: false, embed: Embed, vectors: Vectors, observer: self()]

    for dir <- dirs do
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "shared.ex"),
        "defmodule Cached#{System.unique_integer([:positive])} do end\n"
      )
    end

    [first, second, third] = dirs
    File.cp!(Path.join(first, "shared.ex"), Path.join(second, "shared.ex"))
    File.cp!(Path.join(first, "shared.ex"), Path.join(third, "shared.ex"))
    Application.put_env(:trailblazer, :embed_model, "cache-model-a")

    {:ok, _} = Indexer.watch(first, opts)
    assert_receive {:cache_embed, docs}, 1000
    assert_receive {:cache_points, ^first, points1}, 1000
    assert length(points1) == length(docs)

    {:ok, _} = Indexer.watch(second, opts)
    assert_receive {:cache_points, ^second, points2}, 1000
    refute_receive {:cache_embed, _}, 50
    assert Enum.map(points1, & &1.vector) == Enum.map(points2, & &1.vector)
    refute Enum.map(points1, & &1.id) == Enum.map(points2, & &1.id)

    [{title, text} | _] = docs
    hash = :crypto.hash(:sha256, "title: #{title} | text: #{text}") |> Base.encode16(case: :lower)
    assert byte_size(Store.embedding_cache_get("cache-model-a", hash)) == 768 * 4

    Application.put_env(:trailblazer, :embed_model, "cache-model-b")
    {:ok, _} = Indexer.watch(third, opts)
    assert_receive {:cache_embed, ^docs}, 1000
    assert_receive {:cache_points, ^third, _}, 1000
  end

  test "mixed hits and duplicate misses keep input order; failed misses are not cached" do
    tag = "cache-mixed-#{System.unique_integer([:positive])}"
    a = {tag, "a"}
    b = {tag, "b"}
    opts = [observer: self()]
    assert {:ok, [va]} = Trailblazer.EmbedCache.documents([a], Embed, opts)
    assert_receive {:cache_embed, [^a]}

    assert {:error, :embedder_down} =
             Trailblazer.EmbedCache.documents([a, b, a, b], Embed, Keyword.put(opts, :fail, true))

    assert_receive {:cache_embed, [^b]}

    assert {:ok, [^va, vb, ^va, vb]} =
             Trailblazer.EmbedCache.documents([a, b, a, b], Embed, opts)

    assert_receive {:cache_embed, [^b]}
    assert {:ok, [^vb, ^va]} = Trailblazer.EmbedCache.documents([b, a], Embed, opts)
    refute_receive {:cache_embed, _}, 30
  end
end
