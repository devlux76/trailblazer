defmodule Trailblazer.CLITest do
  use ExUnit.Case, async: true

  alias Trailblazer.CLI

  @repo "/home/mirai/projects/sojourney"

  describe "parse" do
    test "where takes a name, or a path:line" do
      assert {:ok, "where", %{"repo" => @repo, "name" => "put"}, _} =
               CLI.parse(["where", "put", "--repo", @repo])

      assert {:ok, "where", %{"repo" => @repo, "path" => "lib/a b.ex", "line" => 12}, _} =
               CLI.parse(["where", "lib/a b.ex:12", "--repo", @repo])
    end

    test "trail takes the request, repeated --file and a --budget" do
      assert {:ok, "trail", body, flags} =
               CLI.parse([
                 "trail",
                 "--repo",
                 @repo,
                 "saving hikes fails",
                 "--file",
                 "web/app.ts",
                 "--file",
                 "lib/store.ex",
                 "--budget",
                 "800",
                 "--text"
               ])

      assert body == %{
               "repo" => @repo,
               "request" => "saving hikes fails",
               "files" => ["web/app.ts", "lib/store.ex"],
               "budget" => 800
             }

      assert flags[:text]
    end

    test "read takes path:first-last" do
      assert {:ok, "read",
              %{"repo" => @repo, "path" => "lib/app.ex", "first" => 10, "last" => 20}, _} =
               CLI.parse(["read", "lib/app.ex:10-20", "--repo", @repo])
    end

    test "uses and impact take an id or a name; impact a --depth" do
      assert {:ok, "uses", %{"id" => 42}, _} = CLI.parse(["uses", "42", "--repo", @repo])

      assert {:ok, "uses", %{"name" => "Mini.Store.put/2"}, _} =
               CLI.parse(["uses", "Mini.Store.put/2", "--repo", @repo])

      assert {:ok, "impact", %{"name" => "run", "depth" => 2}, _} =
               CLI.parse(["impact", "run", "--depth", "2", "--repo", @repo])
    end

    test "search takes the text and a --limit; text that looks like a flag is text after --" do
      assert {:ok, "search", %{"text" => "save hikes", "limit" => 5}, _} =
               CLI.parse(["search", "save hikes", "--limit", "5", "--repo", @repo])

      assert {:ok, "search", %{"text" => "--version"}, _} =
               CLI.parse(["search", "--repo", @repo, "--", "--version"])
    end

    test "watch, status and stale_citations take only the repo" do
      for op <- ~w(watch status stale_citations) do
        assert {:ok, ^op, %{"repo" => @repo} = body, _} = CLI.parse([op, "--repo", @repo])
        assert map_size(body) == 1
      end
    end

    test "anomalies and ack are about the service: no repo, an integer id" do
      assert {:ok, "anomalies", body, _} = CLI.parse(["anomalies"])
      assert body == %{}
      assert {:ok, "anomalies", %{"all" => true}, _} = CLI.parse(["anomalies", "--all"])
      assert {:ok, "ack", %{"id" => 12}, _} = CLI.parse(["ack", "12"])
      assert {:error, _} = CLI.parse(["ack", "x"])
      assert {:error, _} = CLI.parse(["ack", "0"])
    end

    test "D4: bad arguments are errors, not crashes" do
      assert {:error, _} = CLI.parse([])
      assert {:error, _} = CLI.parse(["explode", "--repo", @repo])
      assert {:error, _} = CLI.parse(["read", "lib/app.ex:20-10", "--repo", @repo])
      assert {:error, _} = CLI.parse(["read", "lib/app.ex", "--repo", @repo])
      assert {:error, _} = CLI.parse(["impact", "run", "--depth", "x", "--repo", @repo])
      assert {:error, _} = CLI.parse(["where", "--repo", @repo])
    end

    test "--repo defaults to the git root of the current directory" do
      assert {:ok, "status", %{"repo" => repo}, _} = CLI.parse(["status"])
      # a worktree's .git is a file, a clone's a directory
      assert File.exists?(Path.join(repo, ".git"))
    end
  end

  describe "run" do
    setup do
      dir = Path.join(System.tmp_dir!(), "trailblazer-cli-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "no endpoint.json: not running, with the hint, exit 1", %{dir: dir} do
      assert {1, out} = CLI.run(["status", "--repo", @repo], state_dir: dir)

      assert Jason.decode!(out) == %{
               "error" => "trailblazer is not running",
               "hint" => "systemctl --user start trailblazer"
             }
    end

    test "a reply is printed as JSON; the token goes in the header", %{dir: dir} do
      File.write!(
        Path.join(dir, "endpoint.json"),
        ~s({"url": "http://127.0.0.1:1", "token": "secret"})
      )

      Req.Test.stub(:cli_ok, fn conn ->
        assert conn.request_path == "/where"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"repo" => @repo, "name" => "put"}
        Req.Test.json(conn, [%{"qualified" => "Mini.Store.put/2"}])
      end)

      assert {0, out} =
               CLI.run(["where", "put", "--repo", @repo],
                 state_dir: dir,
                 req_options: [plug: {Req.Test, :cli_ok}]
               )

      assert [%{"qualified" => "Mini.Store.put/2"}] = Jason.decode!(out)
    end

    test "an error reply exits 1, and trail --text prints the text alone", %{dir: dir} do
      File.write!(
        Path.join(dir, "endpoint.json"),
        ~s({"url": "http://127.0.0.1:1", "token": "t"})
      )

      Req.Test.stub(:cli_409, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          409,
          ~s({"error": "not watched", "hint": "trailblazer watch <repo>"})
        )
      end)

      assert {1, out} =
               CLI.run(["status", "--repo", @repo],
                 state_dir: dir,
                 req_options: [plug: {Req.Test, :cli_409}]
               )

      assert %{"error" => "not watched"} = Jason.decode!(out)

      Req.Test.stub(
        :cli_trail,
        &Req.Test.json(&1, %{"text" => "lib/a.ex:1-2\ndef a", "tokens" => 5})
      )

      assert {0, "lib/a.ex:1-2\ndef a"} =
               CLI.run(["trail", "why", "--text", "--repo", @repo],
                 state_dir: dir,
                 req_options: [plug: {Req.Test, :cli_trail}]
               )
    end

    defp ndjson(conn, items) do
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("application/x-ndjson")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(items, conn, fn item, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, Jason.encode!(item) <> "\n")
        conn
      end)
    end

    @stream [
      %{"case" => "c1", "task" => %{"request" => "fix it"}},
      %{"event" => %{"seq" => 1, "kind" => "attempt", "data" => %{"n" => 1}}},
      %{"event" => %{"seq" => 2, "kind" => "check", "data" => %{"status" => "pass"}}},
      %{"report" => %{"status" => "fixed", "case" => "c1"}}
    ]

    # B3: `run` polled /case every second; it follows the case's events now.
    test "case --follow prints each event as it comes and the report last", %{dir: dir} do
      File.write!(
        Path.join(dir, "endpoint.json"),
        ~s({"url": "http://127.0.0.1:1", "token": "t"})
      )

      Req.Test.stub(:cli_follow, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert conn.request_path == "/case"
        assert Jason.decode!(body) == %{"case" => "c1", "follow" => true}
        ndjson(conn, @stream)
      end)

      me = self()

      assert {0, out} =
               CLI.run(["case", "c1", "--follow"],
                 state_dir: dir,
                 req_options: [plug: {Req.Test, :cli_follow}],
                 on_event: &send(me, {:event, &1})
               )

      assert %{"status" => "fixed"} = Jason.decode!(out)
      assert_received {:event, %{"seq" => 1, "kind" => "attempt"}}
      assert_received {:event, %{"seq" => 2, "kind" => "check"}}
    end

    test "run submits, then follows its case to the report", %{dir: dir} do
      File.write!(
        Path.join(dir, "endpoint.json"),
        ~s({"url": "http://127.0.0.1:1", "token": "t"})
      )

      Req.Test.stub(:cli_run_follow, fn conn ->
        case conn.request_path do
          "/run" -> Req.Test.json(conn, %{"case" => "c1"})
          "/case" -> ndjson(conn, @stream)
        end
      end)

      assert {0, out} =
               CLI.run(["run", "fix it", "--repo", @repo],
                 state_dir: dir,
                 req_options: [plug: {Req.Test, :cli_run_follow}],
                 on_event: fn _ -> :ok end
               )

      assert %{"status" => "fixed", "case" => "c1"} = Jason.decode!(out)
    end

    test "a stream that ends without a report says so", %{dir: dir} do
      File.write!(
        Path.join(dir, "endpoint.json"),
        ~s({"url": "http://127.0.0.1:1", "token": "t"})
      )

      Req.Test.stub(:cli_cut, &ndjson(&1, Enum.take(@stream, 2)))

      assert {1, out} =
               CLI.run(["case", "c1", "--follow"],
                 state_dir: dir,
                 req_options: [plug: {Req.Test, :cli_cut}],
                 on_event: fn _ -> :ok end
               )

      assert %{"error" => "the case's stream ended without a report"} = Jason.decode!(out)
    end

    # L9: a run that timed out in the service printed `""` and nothing else.
    test "E23: an error with an empty body still says what happened", %{dir: dir} do
      File.write!(
        Path.join(dir, "endpoint.json"),
        ~s({"url": "http://127.0.0.1:1", "token": "t"})
      )

      Req.Test.stub(:cli_500, &Plug.Conn.send_resp(&1, 500, ""))

      assert {1, out} =
               CLI.run(["run", "fix it", "--no-wait", "--repo", @repo],
                 state_dir: dir,
                 req_options: [plug: {Req.Test, :cli_500}]
               )

      assert %{"error" => "the service answered HTTP 500"} = Jason.decode!(out)
    end

    test "read --text prints the lines themselves", %{dir: dir} do
      File.write!(
        Path.join(dir, "endpoint.json"),
        ~s({"url": "http://127.0.0.1:1", "token": "t"})
      )

      Req.Test.stub(:cli_read, &Req.Test.json(&1, "line one\nline two"))

      assert {0, "line one\nline two"} =
               CLI.run(["read", "a.ex:1-2", "--text", "--repo", @repo],
                 state_dir: dir,
                 req_options: [plug: {Req.Test, :cli_read}]
               )
    end

    test "the service down is reported like a missing endpoint", %{dir: dir} do
      File.write!(
        Path.join(dir, "endpoint.json"),
        ~s({"url": "http://127.0.0.1:1", "token": "t"})
      )

      Req.Test.stub(:cli_down, &Req.Test.transport_error(&1, :econnrefused))

      assert {1, out} =
               CLI.run(["status", "--repo", @repo],
                 state_dir: dir,
                 req_options: [plug: {Req.Test, :cli_down}]
               )

      assert %{"error" => "trailblazer is not running"} = Jason.decode!(out)
    end
  end
end
