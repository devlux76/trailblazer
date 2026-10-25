defmodule Trailblazer.API.EndpointFile do
  @moduledoc "Owns the API credential and publishes it atomically in a private file."
  use GenServer
  alias Trailblazer.Config
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def token, do: GenServer.call(__MODULE__, :token)
  def ready, do: GenServer.call(__MODULE__, :ready)
  @impl true
  def init(opts) do
    token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    {:ok,
     %{
       token: token,
       path: Path.join(Keyword.get(opts, :state_dir, Config.get(:state_dir)), "endpoint.json"),
       published: false
     }, {:continue, :publish}}
  end

  @impl true
  def handle_continue(:publish, s) do
    {_, listener, _, _} =
      Enum.find(Supervisor.which_children(Trailblazer.API.Server), fn {id, _, _, _} ->
        id == :http
      end)

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
    {:noreply, publish(s, port)}
  end

  @impl true
  def format_status(status), do: Map.update!(status, :state, &Map.put(&1, :token, "[REDACTED]"))

  @impl true
  def handle_call(:ready, _, s), do: {:reply, :ok, s}
  def handle_call(:token, _, s), do: {:reply, s.token, s}

  defp publish(s, port) do
    File.mkdir_p!(Path.dirname(s.path))
    temp = s.path <> "." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    {:ok, io} = File.open(temp, [:write, :binary, :exclusive])

    try do
      File.chmod!(temp, 0o600)
      IO.binwrite(io, Jason.encode!(%{url: "http://127.0.0.1:#{port}", token: s.token}))
      File.close(io)
      File.rename!(temp, s.path)
    after
      File.close(io)
      File.rm(temp)
    end

    # written, then announced, so a waiter reads the new file (design §13.3)
    :ok = Trailblazer.Events.publish(:api, {:endpoint, s.path})
    %{s | published: true}
  end

  @impl true
  def terminate(_, s) do
    if s.published, do: File.rm(s.path)
    :ok
  end
end
