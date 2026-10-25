defmodule Trailblazer.LoopCLITest do
  use ExUnit.Case, async: true
  alias Trailblazer.CLI

  setup do
    dir =
      Path.join(System.tmp_dir!(), "trailblazer-loop-cli-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "endpoint.json"),
      Jason.encode!(%{url: "http://127.0.0.1:1", token: "test"})
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "parse repeated file/design flags, check and no-wait; case needs no repository" do
    assert {:ok, "run", body, flags} =
             CLI.parse([
               "run",
               "--repo",
               "/fixture",
               "fix",
               "--file",
               "a.ex",
               "--file",
               "b.ex",
               "--design",
               "Keep API",
               "--design",
               "No network",
               "--check",
               "mix test",
               "--no-wait"
             ])

    assert body == %{
             "repo" => "/fixture",
             "request" => "fix",
             "files" => ["a.ex", "b.ex"],
             "design" => ["Keep API", "No network"],
             "check" => "mix test"
           }

    assert flags[:wait] == false
    assert {:ok, "case", %{"case" => "abc"}, _} = CLI.parse(["case", "abc"])
  end

  # B3: run follows its case's events (no polling) and exits by the report.
  test "run follows the case to its report and exits according to the result", %{dir: dir} do
    for status <- ["fixed", "failed", "unverified"] do
      Req.Test.stub(:loop_cli, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(body)

        case conn.request_path do
          "/run" ->
            assert body["request"] == "fix"
            Req.Test.json(conn, %{case: "abc"})

          "/case" ->
            assert body == %{"case" => "abc", "follow" => true}

            conn =
              conn
              |> Plug.Conn.put_resp_content_type("application/x-ndjson")
              |> Plug.Conn.send_chunked(200)

            {:ok, conn} = Plug.Conn.chunk(conn, ~s({"case":"abc"}\n))

            {:ok, conn} =
              Plug.Conn.chunk(conn, ~s({"event":{"seq":1,"kind":"attempt","data":{}}}\n))

            {:ok, conn} =
              Plug.Conn.chunk(
                conn,
                Jason.encode!(%{report: %{status: status, case: "abc"}}) <> "\n"
              )

            conn
        end
      end)

      {code, text} =
        CLI.run(["run", "--repo", "/fixture", "fix"],
          state_dir: dir,
          on_event: fn _ -> :ok end,
          req_options: [plug: {Req.Test, :loop_cli}]
        )

      assert code == if(status == "fixed", do: 0, else: 1)
      assert Jason.decode!(text) == %{"case" => "abc", "status" => status}
    end
  end

  test "no-wait prints case id immediately; case prints summary without full events", %{dir: dir} do
    Req.Test.stub(:loop_nowait, fn conn ->
      assert conn.request_path == "/run"
      Req.Test.json(conn, %{case: "abc"})
    end)

    assert {0, text} =
             CLI.run(["run", "--repo", "/fixture", "fix", "--no-wait"],
               state_dir: dir,
               req_options: [plug: {Req.Test, :loop_nowait}]
             )

    assert Jason.decode!(text) == %{"case" => "abc"}

    Req.Test.stub(:loop_case, fn conn ->
      assert conn.request_path == "/case"

      Req.Test.json(conn, %{
        case: "abc",
        status: "failed",
        report: %{status: "failed"},
        record: %{task: %{request: "fix"}, events: [%{data: "large prompt"}]}
      })
    end)

    assert {0, text} =
             CLI.run(["case", "abc"], state_dir: dir, req_options: [plug: {Req.Test, :loop_case}])

    summary = Jason.decode!(text)
    assert summary["status"] == "failed"
    refute Map.has_key?(summary, "record")
    assert summary["task"] == %{"request" => "fix"}
  end
end
