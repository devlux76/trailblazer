defmodule Trailblazer.Vortex.Supervisor do
  @moduledoc "A failed resource owner revokes its dependent runner and bridge."
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)
  @impl true
  def init(opts) do
    Supervisor.init(
      [
        {Trailblazer.Vortex.Resource, []},
        {Trailblazer.Loop.Runner, recover: true},
        {Trailblazer.Vortex.Bridge, opts}
      ],
      strategy: :rest_for_one
    )
  end
end
