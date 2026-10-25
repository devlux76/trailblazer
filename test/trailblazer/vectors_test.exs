defmodule Trailblazer.VectorsTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Vectors

  @repo "/home/mirai/projects/sojourney"

  defp opts(stub), do: [req_options: [plug: {Req.Test, stub}, retry: false]]

  defp read_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {if(body == "", do: nil, else: Jason.decode!(body)), conn}
  end

  defp completed(conn), do: Req.Test.json(conn, %{"result" => %{"status" => "completed"}})

  test "the collection is named for the model, the repository's path and the store" do
    state = "/home/mirai/.local/share/trailblazer"

    hex =
      :crypto.hash(:sha, "embeddinggemma-2\n" <> @repo <> "\n" <> state)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    assert Vectors.collection(@repo, state) == "trailblazer_" <> hex
  end

  # E10 in the register: two stores (state directories) give a repository's
  # nodes different ids, so they must never share a collection.
  test "E10: two stores never share a repository's collection" do
    refute Vectors.collection(@repo, "/tmp/store-a") == Vectors.collection(@repo, "/tmp/store-b")

    assert Vectors.collection(@repo) ==
             Vectors.collection(@repo, Trailblazer.Config.get(:state_dir))
  end

  test "ensure creates a cosine collection of 768 when there is none" do
    test_pid = self()
    name = Vectors.collection(@repo)

    Req.Test.stub(:vec_ensure, fn conn ->
      {body, conn} = read_body(conn)
      send(test_pid, {conn.method, conn.request_path, body})

      case conn.method do
        "GET" -> Plug.Conn.send_resp(conn, 404, ~s({"status":{"error":"Not found"}}))
        "PUT" -> Req.Test.json(conn, %{"result" => true})
      end
    end)

    assert :ok = Vectors.ensure(@repo, opts(:vec_ensure))
    assert_received {"GET", "/collections/" <> ^name, nil}

    assert_received {"PUT", "/collections/" <> ^name,
                     %{"vectors" => %{"size" => 768, "distance" => "Cosine"}}}
  end

  test "ensure refuses a collection of another width" do
    Req.Test.stub(:vec_width, fn conn ->
      Req.Test.json(conn, %{
        "result" => %{"config" => %{"params" => %{"vectors" => %{"size" => 384}}}}
      })
    end)

    assert {:error, {:dims, 384}} = Vectors.ensure(@repo, opts(:vec_width))
  end

  test "put sends integer ids with their payloads and waits for completion" do
    test_pid = self()

    Req.Test.stub(:vec_put, fn conn ->
      {body, conn} = read_body(conn)
      send(test_pid, {conn.method, conn.request_path, conn.query_string, body})
      completed(conn)
    end)

    points = [%{id: 7, vector: [0.5], payload: %{"path" => "lib/a.ex"}}]
    assert :ok = Vectors.put(@repo, points, opts(:vec_put))

    assert_received {"PUT", path, "wait=true", %{"points" => [point]}}
    assert String.ends_with?(path, "/points")
    assert point == %{"id" => 7, "vector" => [0.5], "payload" => %{"path" => "lib/a.ex"}}
  end

  test "put refuses ids that are not positive integers, before sending" do
    assert {:error, {:bad_id, "7"}} =
             Vectors.put(@repo, [%{id: "7", vector: [0.5], payload: %{}}], opts(:vec_unused))
  end

  # D6/E7 in the register: an accepted operation is not a finished one.
  test "an operation Qdrant has only acknowledged is not success" do
    Req.Test.stub(:vec_ack, &Req.Test.json(&1, %{"result" => %{"status" => "acknowledged"}}))

    assert {:error, {:not_completed, "acknowledged"}} =
             Vectors.put(@repo, [%{id: 1, vector: [0.5], payload: %{}}], opts(:vec_ack))

    assert {:error, {:not_completed, "acknowledged"}} =
             Vectors.delete(@repo, [1], opts(:vec_ack))
  end

  test "delete names the points and waits" do
    test_pid = self()

    Req.Test.stub(:vec_delete, fn conn ->
      {body, conn} = read_body(conn)
      send(test_pid, {conn.request_path, conn.query_string, body})
      completed(conn)
    end)

    assert :ok = Vectors.delete(@repo, [3, 4], opts(:vec_delete))
    assert_received {path, "wait=true", %{"points" => [3, 4]}}
    assert String.ends_with?(path, "/points/delete")
  end

  test "putting or deleting nothing sends nothing" do
    assert :ok = Vectors.put(@repo, [], opts(:vec_unused))
    assert :ok = Vectors.delete(@repo, [], opts(:vec_unused))
  end

  test "nearest returns ids and scores, nearest first" do
    Req.Test.stub(:vec_nearest, fn conn ->
      {body, conn} = read_body(conn)
      assert body["limit"] == 2 and body["query"] == [0.1]

      Req.Test.json(conn, %{
        "result" => %{"points" => [%{"id" => 9, "score" => 0.9}, %{"id" => 2, "score" => 0.4}]}
      })
    end)

    assert {:ok, [{9, 0.9}, {2, 0.4}]} = Vectors.nearest(@repo, [0.1], 2, opts(:vec_nearest))
  end

  test "scores restricts the query to the ids with has_id" do
    Req.Test.stub(:vec_scores, fn conn ->
      {body, conn} = read_body(conn)
      assert body["filter"] == %{"must" => [%{"has_id" => [1, 2]}]}
      assert body["limit"] == 2

      Req.Test.json(conn, %{"result" => %{"points" => [%{"id" => 2, "score" => 0.7}]}})
    end)

    assert {:ok, %{2 => 0.7}} = Vectors.scores(@repo, [0.1], [1, 2], opts(:vec_scores))
    assert {:ok, %{}} = Vectors.scores(@repo, [0.1], [], opts(:vec_unused))
  end

  test "a refused connection is qdrant_down" do
    Req.Test.stub(:vec_down, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, :qdrant_down} = Vectors.ensure(@repo, opts(:vec_down))
    assert {:error, :qdrant_down} = Vectors.nearest(@repo, [0.1], 3, opts(:vec_down))

    assert {:error, :qdrant_down} =
             Vectors.put(@repo, [%{id: 1, vector: [0.1], payload: %{}}], opts(:vec_down))
  end

  test "a reply without the expected shape is a bad response" do
    Req.Test.stub(:vec_shape, &Req.Test.json(&1, %{"result" => %{"nope" => []}}))

    assert {:error, {:bad_response, _}} = Vectors.nearest(@repo, [0.1], 3, opts(:vec_shape))
  end

  # D6, Codex's repro of c11a7f7: a point that is not an object is a bad
  # response, not a crash.
  test "D6: a point that is not an object is a bad response" do
    Req.Test.stub(:vec_points, &Req.Test.json(&1, %{"result" => %{"points" => [123]}}))

    assert {:error, {:bad_response, _}} = Vectors.nearest(@repo, [0.1], 3, opts(:vec_points))
  end

  @tag :live
  test "live: embed one document, put it, find it with nearest" do
    repo = "/tmp/trailblazer-live-#{System.unique_integer([:positive])}"
    {:ok, [vector]} = Trailblazer.Embed.documents([{"Store.put", "def put(a, b)"}])

    try do
      assert :ok = Vectors.ensure(repo)
      assert :ok = Vectors.put(repo, [%{id: 1, vector: vector, payload: %{"q" => "Store.put"}}])
      assert {:ok, [{1, score} | _]} = Vectors.nearest(repo, vector, 1)
      assert score > 0.99
    after
      Vectors.drop(repo)
    end
  end
end
