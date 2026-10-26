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

    children = [{Task.Supervisor, name: tasks}, {Trailblazer.Planner.Companion, companion}]

    children =
      case Trailblazer.Config.get(:planner) do
        nil ->
          children

        config ->
          children ++
            [
              {Trailblazer.Planner.Research, [config: config]},
              {Trailblazer.Planner.Brain,
               Keyword.merge(Keyword.get(opts, :brain_opts, []),
                 config: config,
                 tasks: tasks,
                 name: Keyword.get(opts, :brain_name, Trailblazer.Planner.Brain)
               )}
            ]
      end

    Supervisor.init(
      children,
      strategy: :one_for_all
    )
  end
end
