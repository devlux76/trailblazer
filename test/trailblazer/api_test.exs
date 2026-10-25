defmodule Trailblazer.APITest do
  use ExUnit.Case, async: false
  import Plug.Test
  alias Trailblazer.{API, Indexer}

  defmodule Embed do
    def documents(docs, _), do: {:ok, Enum.map(docs, fn _ -> [1.0] end)}
    def query(_, _), do: {:error, :embedder_down}
  end

  defmodule Vectors do
    def ensure(_, _), do: :ok
    def delete(_, _, _), do: :ok
    def put(_, _, _), do: :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "trailblazer-api-#{System.unique_integer([:positive])}")
    File.cp_r!(Path.expand("../fixtures/mini", __DIR__), root)

    opts =
      API.init(
        token: "test-secret",
        indexer_opts: [embed: Embed, vectors: Vectors, filesystem: false, embedding: :paused],
        query_opts: [embed: Embed, vectors: Vectors]
      )

    on_exit(fn ->
      if pid = Indexer.whereis(root), do: GenServer.stop(pid)
      File.rm_rf!(root)
    end)

    %{root: root, opts: opts}
  end

  defp request(opts, op, body, token \\ "test-secret") do
    conn(:post, "/" <> op, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(fn conn ->
      if token,
        do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token),
        else: conn
    end)
    |> API.call(opts)
  end

  test "credentials, watched identity and fixture query", %{root: root, opts: opts} do
    assert request(opts, "status", %{repo: root}, nil).status == 401
    assert request(opts, "status", %{repo: root}, "wrong").status == 401
    missing = request(opts, "where", %{repo: root, name: "put"})
    assert missing.status == 409
    assert Jason.decode!(missing.resp_body)["hint"] == "trailblazer watch <repo>"
    assert request(opts, "watch", %{repo: root}).status == 200
    response = request(opts, "where", %{repo: root <> "/.", name: "put"})
    assert response.status == 200
    assert length(Jason.decode!(response.resp_body)) == 2
    assert request(opts, "status", %{repo: root}).status == 200
    assert request(opts, "uses", %{repo: root, name: "Mini.Store.put/2"}).status == 200
    assert request(opts, "impact", %{repo: root, name: "saveHikes", depth: 3}).status == 200
    assert request(opts, "stale_citations", %{repo: root}).status == 200
    assert request(opts, "search", %{repo: root, text: "saveHikes", limit: 3}).status == 200

    assert request(opts, "read", %{repo: root, path: "../escape", first: 1, last: 3}).status ==
             400

    assert request(opts, "where", %{repo: root, name: "nobody"}).resp_body == "[]"
    assert request(opts, "not_an_op", %{repo: root}).status == 404

    trail =
      request(opts, "trail", %{
        repo: root,
        request: "saving hikes fails",
        files: ["web/app.ts"],
        budget: 200
      })

    assert trail.status == 200
    assert Jason.decode!(trail.resp_body)["tokens"] <= 200

    assert request(opts, "read", %{repo: root, path: "lib/app.ex", first: 1, last: 1}).status ==
             200

    assert request(opts, "watch", %{repo: root <> "/missing"}).status == 503
    assert request(opts, "status", %{repo: root <> "/missing"}).status == 409
  end

  # Design §13.7: every answer reconciles first, with no watcher and no wait.
  test "a query sees a file written just before it; a vanished root is an error",
       %{root: root, opts: opts} do
    assert request(opts, "watch", %{repo: root}).status == 200

    File.write!(
      Path.join(root, "lib/just_now.ex"),
      "defmodule Mini.JustNow do; def hi, do: 1; end"
    )

    response = request(opts, "where", %{repo: root, name: "Mini.JustNow.hi/0"})
    assert response.status == 200
    assert [_] = Jason.decode!(response.resp_body)

    File.rm_rf!(root)
    refute request(opts, "where", %{repo: root, name: "Mini.JustNow.hi/0"}).status == 200
  end

  test "bad JSON, bodies and arguments never reach the services", %{root: root, opts: opts} do
    for body <- [
          nil,
          [],
          42,
          true,
          %{},
          %{repo: []},
          %{repo: root, line: "1", path: "lib/app.ex"}
        ] do
      assert request(opts, "where", body).status == 400
    end

    request(opts, "watch", %{repo: root})

    for {op, args} <- [
          {"where", %{name: []}},
          {"where", %{path: "lib/app.ex", line: 0}},
          {"uses", %{id: -1}},
          {"impact", %{id: 1, depth: -1}},
          {"read", %{path: "lib/app.ex", first: 3, last: 1}},
          {"search", %{text: "x", limit: 0}},
          {"trail", %{request: "x", files: [3]}},
          {"trail", %{request: "x", budget: 0}}
        ] do
      assert request(opts, op, Map.put(args, :repo, root)).status == 400
    end

    bad =
      conn(:post, "/watch", "{")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer test-secret")
      |> API.call(opts)

    assert bad.status == 400
    assert request(opts, "status", %{repo: root}).status == 200
  end

  test "endpoint publication is private, uses the actual loopback port and keeps token out of logs" do
    dir =
      Path.join(System.tmp_dir!(), "trailblazer-endpoint-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        pid = start_supervised!({Trailblazer.API.Server, [port: 0, state_dir: dir]})
        assert is_pid(pid)
        endpoint = Jason.decode!(File.read!(Path.join(dir, "endpoint.json")))
        assert endpoint["token"] =~ ~r/^[a-f0-9]{64}$/
        assert endpoint["url"] =~ ~r{^http://127\.0\.0\.1:[1-9][0-9]*$}
        assert Bitwise.band(File.stat!(Path.join(dir, "endpoint.json")).mode, 0o777) == 0o600
        send(self(), {:token, endpoint["token"]})

        refute inspect(:sys.get_status(Trailblazer.API.EndpointFile), limit: :infinity) =~
                 endpoint["token"]

        assert {:ok, %Req.Response{status: 401}} =
                 Req.post(endpoint["url"] <> "/status", json: %{repo: "/tmp"}, retry: false)
      end)

    assert_received {:token, token}
    refute logs =~ token
  end

  test "credential restart republishes the listener's actual endpoint" do
    dir =
      Path.join(System.tmp_dir!(), "trailblazer-restart-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    start_supervised!({Trailblazer.API.Server, [port: 0, state_dir: dir]})
    old = Jason.decode!(File.read!(Path.join(dir, "endpoint.json")))
    path = Path.join(dir, "endpoint.json")
    :ok = Trailblazer.Events.subscribe(:api)
    Process.exit(Process.whereis(Trailblazer.API.EndpointFile), :kill)

    # B9: the restarted writer announces the new file; no polling
    assert_receive {:trailblazer_event, :api, {:endpoint, ^path}}
    assert Jason.decode!(File.read!(path))["token"] != old["token"]
    current = Jason.decode!(File.read!(Path.join(dir, "endpoint.json")))

    assert {:ok, %Req.Response{status: 401}} =
             Req.post(current["url"] <> "/status", json: %{}, retry: false)
  end
end
