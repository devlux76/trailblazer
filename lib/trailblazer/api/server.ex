defmodule Trailblazer.API.Server do
  @moduledoc "Supervises the credential owner and the IPv4 loopback HTTP listener."
  use Supervisor

  def start_link(opts \\ []) do
    with {:ok, pid} <- Supervisor.start_link(__MODULE__, opts, name: __MODULE__) do
      :ok = Trailblazer.API.EndpointFile.ready()
      {:ok, pid}
    end
  end

  @impl true
  def init(opts) do
    http =
      Supervisor.child_spec(
        {Bandit,
         [
           plug: Trailblazer.API,
           ip: {127, 0, 0, 1},
           port: Keyword.get(opts, :port, Trailblazer.Config.get(:api_port)),
           startup_log: false
         ]},
        id: :http
      )

    Supervisor.init([{Trailblazer.API.EndpointFile, opts}, http], strategy: :one_for_all)
  end
end
