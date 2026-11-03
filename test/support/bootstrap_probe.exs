# Runs in a separate VM so the real application bootstrap is exercised.
import Plug.Test
[root, expected] = System.argv()
Application.put_env(:trailblazer, :serve_api, false)
Application.put_env(:trailblazer, :embed_probe, fn -> {:error, :offline} end)
{:ok, _} = Application.ensure_all_started(:trailblazer)

defmodule BootstrapEmbed do
  def documents(docs, _), do: {:ok, Enum.map(docs, fn _ -> [1.0] end)}
  def query(_, _), do: {:error, :offline}
end

defmodule BootstrapVectors do
  def ensure(_, _), do: :ok
  def delete(_, _, _), do: :ok
  def put(_, _, _), do: :ok
end

opts =
  Trailblazer.API.init(
    token: "bootstrap-test",
    indexer_opts: [
      filesystem: false,
      embedding: :paused,
      embed: BootstrapEmbed,
      vectors: BootstrapVectors
    ],
    query_opts: [embed: BootstrapEmbed, vectors: BootstrapVectors]
  )

request = fn op, params ->
  conn(:post, "/" <> op, Jason.encode!(params))
  |> Plug.Conn.put_req_header("authorization", "Bearer bootstrap-test")
  |> Plug.Conn.put_req_header("content-type", "application/json")
  |> Trailblazer.API.call(opts)
end

watch = request.("watch", %{repo: root})
unless watch.status == 200, do: raise("watch failed: #{watch.resp_body}")
status = request.("status", %{repo: root})
unless status.status == 200, do: raise("status failed")
body = Jason.decode!(status.resp_body)

unless body["vortex"]["state"] == expected,
  do: raise("wrong messaging status: #{inspect(body["vortex"])}")

where = request.("where", %{repo: root, name: "Mini.Store.put/2"})

unless where.status == 200 and Jason.decode!(where.resp_body) != [],
  do: raise("core query unavailable")

trail =
  request.("trail", %{
    repo: root,
    request: "Mini.Store.put/2",
    files: ["lib/store.ex"],
    budget: 300
  })

unless trail.status == 200 and Jason.decode!(trail.resp_body)["text"] != "",
  do: raise("trail unavailable")

if expected == "unavailable" do
  unless Process.whereis(Trailblazer.Loop.Runner) == nil,
    do: raise("unsafe standalone runner started")

  unless Process.whereis(Trailblazer.Vortex.Bridge) == nil, do: raise("broken bridge started")

  unless Process.whereis(Trailblazer.Planner.Supervisor) == nil,
    do: raise("planner started with broken authority")

  task = %{repo: root, request: "must not run"}

  unless Trailblazer.Loop.Runner.submit(task) == {:error, :vortex_unavailable},
    do: raise("coder did not fail closed")

  run = request.("run", %{repo: root, request: "must not run", check: "true"})

  unless run.status == 503 and Jason.decode!(run.resp_body)["error"] == "vortex_unavailable",
    do: raise("API did not name unavailable authority")
else
  unless Process.whereis(Trailblazer.Loop.Runner), do: raise("standalone runner missing")
end

# A settings read must not turn into a fresh file parse after boot.
if path = System.get_env("TRAILBLAZER_VORTEX_CONFIG"),
  do: File.write!(path, "broken after bootstrap")

unless request.("status", %{repo: root}).status == 200,
  do: raise("post-boot corruption broke indexing")

IO.puts("BOOTSTRAP_OK")
