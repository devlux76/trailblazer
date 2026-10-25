defmodule Trailblazer.Vortex.TransportTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Vortex.Transport

  # A stand-in VORTEX service whose /attach streams NDJSON notices, one of
  # them split across two chunks, then closes the line.
  defmodule Line do
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/attach"} = conn, _) do
      conn = send_chunked(conn, 200)
      {:ok, conn} = chunk(conn, ~s({"attached":true,"cursor":4,"unread":0}\n{"cursor":5,"un))
      {:ok, conn} = chunk(conn, ~s(read":1}\n))
      {:ok, conn} = chunk(conn, ~s({"cursor":6,"unread":2}\n))
      conn
    end
  end

  setup do
    {:ok, server} = Bandit.start_link(plug: Line, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    dir = Path.join(System.tmp_dir!(), "tb-transport-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    endpoint = Path.join(dir, "endpoint.json")
    File.write!(endpoint, Jason.encode!(%{url: "http://127.0.0.1:#{port}", token: "t"}))
    on_exit(fn -> File.rm_rf(dir) end)
    %{endpoint: endpoint}
  end

  test "call routes attach to the streaming line: one notice per line, split chunks joined",
       ctx do
    assert {:ok, :closed} = Transport.call(ctx.endpoint, "attach", %{"notify" => self()})
    assert_received {:vortex_notice, 0}
    assert_received {:vortex_notice, 1}
    assert_received {:vortex_notice, 2}
    refute_received {:vortex_notice, _}
  end

  test "a missing service is an unavailable transport, not a crash" do
    assert {:error, :transport_unavailable} =
             Transport.call("/nonexistent/endpoint.json", "attach", %{"notify" => self()})
  end
end
