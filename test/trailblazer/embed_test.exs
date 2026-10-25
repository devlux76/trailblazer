defmodule Trailblazer.EmbedTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Embed

  defp opts(stub), do: [req_options: [plug: {Req.Test, stub}, retry: false]]

  defp vector(n, dims \\ 768), do: List.duplicate(n / 1, dims)

  defp reply(conn, inputs, fun \\ & &1) do
    data =
      inputs
      |> Enum.with_index()
      |> Enum.map(fn {_input, i} -> %{"index" => i, "embedding" => vector(i)} end)
      |> fun.()

    Req.Test.json(conn, %{"data" => data})
  end

  defp read_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  test "documents sends the model and ranger's document form, and keeps the order" do
    Req.Test.stub(:embed_order, fn conn ->
      {body, conn} = read_body(conn)
      assert body["model"] == "embeddinggemma-2"
      assert body["input"] == ["title: A | text: one", "title: B | text: two"]
      reply(conn, body["input"], &Enum.reverse/1)
    end)

    assert {:ok, [first, second]} =
             Embed.documents([{"A", "one"}, {"B", "two"}], opts(:embed_order))

    assert hd(first) == 0.0 and hd(second) == 1.0
  end

  test "documents are sent in batches of 16" do
    test_pid = self()

    Req.Test.stub(:embed_batches, fn conn ->
      {body, conn} = read_body(conn)
      send(test_pid, {:batch, length(body["input"])})
      reply(conn, body["input"])
    end)

    docs = for i <- 1..20, do: {"t#{i}", "x"}
    assert {:ok, vectors} = Embed.documents(docs, opts(:embed_batches))
    assert length(vectors) == 20
    assert_received {:batch, 16}
    assert_received {:batch, 4}
  end

  describe "a pool of embedders" do
    @urls ["http://fast.test/v1/embeddings", "http://slow.test/v1/embeddings"]

    defp pool(stub), do: Keyword.put(opts(stub), :urls, @urls)

    # Each vector carries the number in its document's title, so the order of
    # the whole result can be checked across chunks served by different hosts.
    defp numbered(conn, inputs) do
      data =
        inputs
        |> Enum.with_index()
        |> Enum.map(fn {input, i} ->
          [_, n] = Regex.run(~r/title: t(\d+) /, input)
          %{"index" => i, "embedding" => vector(String.to_integer(n))}
        end)

      Req.Test.json(conn, %{"data" => data})
    end

    test "chunks go to every embedder as each frees up, and the order is kept" do
      test_pid = self()

      Req.Test.stub(:embed_pool, fn conn ->
        {body, conn} = read_body(conn)
        send(test_pid, {:served, conn.host, length(body["input"])})
        if conn.host == "slow.test", do: Process.sleep(50)
        numbered(conn, body["input"])
      end)

      docs = for i <- 1..40, do: {"t#{i}", "x"}
      assert {:ok, vectors} = Embed.documents(docs, pool(:embed_pool))
      assert Enum.map(vectors, &hd/1) == Enum.map(1..40, &(&1 / 1))

      served = for _ <- 1..10, do: assert_receive({:served, _host, 4})
      hosts = Enum.frequencies(Enum.map(served, &elem(&1, 1)))
      assert hosts["fast.test"] > hosts["slow.test"]
      assert hosts["slow.test"] >= 1
    end

    test "a failing embedder's chunks are done by the others" do
      Req.Test.stub(:embed_pool_down, fn conn ->
        {body, conn} = read_body(conn)

        if conn.host == "slow.test",
          do: Plug.Conn.send_resp(conn, 503, "busy"),
          else: numbered(conn, body["input"])
      end)

      docs = for i <- 1..20, do: {"t#{i}", "x"}
      assert {:ok, vectors} = Embed.documents(docs, pool(:embed_pool_down))
      assert Enum.map(vectors, &hd/1) == Enum.map(1..20, &(&1 / 1))
    end

    test "a free embedder redoes a straggler's chunk, and the call does not wait for the straggler" do
      test_pid = self()

      Req.Test.stub(:embed_pool_straggler, fn conn ->
        {body, conn} = read_body(conn)
        send(test_pid, {:served, conn.host, body["input"]})
        if conn.host == "slow.test", do: Process.sleep(:infinity)
        numbered(conn, body["input"])
      end)

      docs = for i <- 1..12, do: {"t#{i}", "x"}
      started = System.monotonic_time(:millisecond)
      assert {:ok, vectors} = Embed.documents(docs, pool(:embed_pool_straggler))
      assert System.monotonic_time(:millisecond) - started < 1_000
      assert Enum.map(vectors, &hd/1) == Enum.map(1..12, &(&1 / 1))

      assert_received {:served, "slow.test", stuck}
      assert_received {:served, "fast.test", ^stuck}
    end

    test "a straggler that fails while its chunk is backed up does not fail the call" do
      Req.Test.stub(:embed_pool_late_fail, fn conn ->
        {body, conn} = read_body(conn)

        if conn.host == "slow.test" do
          Process.sleep(100)
          Plug.Conn.send_resp(conn, 500, "boom")
        else
          numbered(conn, body["input"])
        end
      end)

      docs = for i <- 1..4, do: {"t#{i}", "x"}
      assert {:ok, vectors} = Embed.documents(docs, pool(:embed_pool_late_fail))
      assert Enum.map(vectors, &hd/1) == Enum.map(1..4, &(&1 / 1))
    end

    test "the call fails only when every embedder has failed" do
      Req.Test.stub(:embed_pool_dead, &Plug.Conn.send_resp(&1, 500, "boom"))

      docs = for i <- 1..20, do: {"t#{i}", "x"}
      assert {:error, {:http, 500}} = Embed.documents(docs, pool(:embed_pool_dead))
    end

    test "queries go to the first embedder only" do
      test_pid = self()

      Req.Test.stub(:embed_pool_query, fn conn ->
        {body, conn} = read_body(conn)
        send(test_pid, {:host, conn.host})
        reply(conn, body["input"])
      end)

      assert {:ok, _} = Embed.query("where is put", pool(:embed_pool_query))
      assert_received {:host, "fast.test"}
      refute_received {:host, "slow.test"}
    end
  end

  test "query uses ranger's query form" do
    Req.Test.stub(:embed_query, fn conn ->
      {body, conn} = read_body(conn)
      assert body["input"] == ["task: code retrieval | query: where is put"]
      reply(conn, body["input"])
    end)

    assert {:ok, [+0.0 | _]} = Embed.query("where is put", opts(:embed_query))
  end

  test "a refused connection is embedder_down" do
    Req.Test.stub(:embed_down, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, :embedder_down} = Embed.documents([{"A", "one"}], opts(:embed_down))
    assert {:error, :embedder_down} = Embed.query("q", opts(:embed_down))
  end

  # D6 in the register: a 200 that does not hold one good vector per input is
  # not success, so nothing is marked embedded on its word.
  describe "D6: replies that are not what was asked for" do
    defp bad(stub, fun) do
      Req.Test.stub(stub, fn conn ->
        {body, conn} = read_body(conn)
        reply(conn, body["input"], fun)
      end)

      Embed.documents([{"A", "one"}, {"B", "two"}], opts(stub))
    end

    test "a missing vector is a bad response" do
      assert {:error, {:bad_response, _}} = bad(:embed_missing, &Enum.drop(&1, 1))
    end

    test "a repeated index is a bad response" do
      assert {:error, {:bad_response, _}} =
               bad(:embed_duplicate, &Enum.map(&1, fn d -> %{d | "index" => 0} end))
    end

    test "a vector of the wrong width is a bad response" do
      assert {:error, {:bad_response, _}} =
               bad(:embed_width, &Enum.map(&1, fn d -> %{d | "embedding" => [1.0]} end))
    end

    test "a vector of things that are not numbers is a bad response" do
      not_numbers = List.duplicate("x", 768)

      assert {:error, {:bad_response, _}} =
               bad(:embed_nan, &Enum.map(&1, fn d -> %{d | "embedding" => not_numbers} end))
    end

    test "a body that is not the expected shape is a bad response" do
      Req.Test.stub(:embed_shape, &Req.Test.json(&1, %{"error" => "busy"}))

      assert {:error, {:bad_response, _}} = Embed.documents([{"A", "one"}], opts(:embed_shape))
    end

    test "an HTTP error is reported with its status" do
      Req.Test.stub(:embed_500, &Plug.Conn.send_resp(&1, 500, "boom"))

      assert {:error, {:http, 500}} = Embed.documents([{"A", "one"}], opts(:embed_500))
    end

    test "one bad batch fails the whole call" do
      Req.Test.stub(:embed_second_bad, fn conn ->
        {body, conn} = read_body(conn)

        if length(body["input"]) == 16,
          do: reply(conn, body["input"]),
          else: reply(conn, body["input"], &Enum.drop(&1, 1))
      end)

      docs = for i <- 1..20, do: {"t#{i}", "x"}
      assert {:error, {:bad_response, _}} = Embed.documents(docs, opts(:embed_second_bad))
    end
  end

  describe "node_text" do
    test "a header of kind, name, signature and calls, then the source, within 2,400 characters" do
      node = %{kind: "function", qualified: "M.f/1", signature: "def f(x)"}
      calls = for i <- 1..10, do: "M.c#{i}/0"

      {title, text} = Embed.node_text(node, "def f(x) do\n  x\nend", calls)

      assert title == "M.f/1"

      assert text ==
               "function M.f/1 · def f(x) · calls: " <>
                 Enum.join(Enum.take(calls, 8), ", ") <> "\ndef f(x) do\n  x\nend"

      {_title, long} = Embed.node_text(node, String.duplicate("x", 5000), [])
      assert String.length(long) == 2400
    end

    test "a compact document keeps the header and cuts the source at the given limit" do
      node = %{kind: "function", qualified: "M.f/1", signature: "def f(x)"}
      {_title, text} = Embed.node_text(node, String.duplicate("x", 5000), ["M.g/0"], 300)
      assert String.length(text) == 300
      assert String.starts_with?(text, "function M.f/1 · def f(x) · calls: M.g/0\n")
    end
  end

  @tag :live
  test "live: the embedder returns one 768-wide vector per document" do
    assert {:ok, [vector]} = Embed.documents([{"Store.put", "def put(a, b)"}])
    assert length(vector) == 768
  end
end
