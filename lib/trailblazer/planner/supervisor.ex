defmodule Trailblazer.Planner.Supervisor do
  @moduledoc "A companion restart stops its old verification tasks before recovery."
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    tasks = Keyword.get(opts, :tasks, Trailblazer.Planner.Tasks)

    companion =
      opts
      |> Keyword.drop([:name, :companion_name])
      |> Keyword.put(:tasks, tasks)
      |> Keyword.put(:name, Keyword.get(opts, :companion_name, Trailblazer.Planner.Companion))

    Supervisor.init(
      [{Task.Supervisor, name: tasks}, {Trailblazer.Planner.Companion, companion}],
      strategy: :one_for_all
    )
  end
end
