defmodule Trailblazer.Planner.Brain.Lease do
  @moduledoc "The brain's planner lease: the Vortex resource acquire and release for one planning attempt."

  alias Trailblazer.Config

  # The real resource boundary: the lease is the caller's own id. A planner on
  # its own server shares no CPU, so it holds nothing and releases at once.
  def acquire(id) do
    if Config.get(:planner_lease), do: lease(id), else: {:ok, id}
  end

  defp lease(id) do
    case Trailblazer.Vortex.Resource.acquire(
           id,
           Trailblazer.Vortex.Resource,
           Config.get(:planner_model)
         ) do
      :ok -> {:ok, id}
      {:ok, lease} -> {:ok, lease}
      :blocked -> :blocked
    end
  end

  def release(lease) do
    if Config.get(:planner_lease), do: unlease(lease), else: :ok
  end

  defp unlease(lease),
    do:
      Trailblazer.Vortex.Resource.release(
        lease,
        Trailblazer.Vortex.Resource,
        Config.get(:planner_model)
      )
end
