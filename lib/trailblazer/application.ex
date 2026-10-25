defmodule Trailblazer.Application do
  @moduledoc """
  Trailblazer's OTP application.

  Events, cases and backstops precede the graph's writer and WAL readers.
  Parsing, repository indexers and the loopback API follow the ready store.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Trailblazer.Events,
      Trailblazer.CaseStore,
      Trailblazer.Load,
      Trailblazer.Backstop,
      Trailblazer.Store,
      Trailblazer.Parse.TreeSitter,
      Trailblazer.EmbedGate,
      Trailblazer.EmbedHealth,
      Trailblazer.Indexer.Supervisor,
      {Trailblazer.Loop.Runner, recover: true}
    ]

    children =
      case Trailblazer.Config.get(:vortex) do
        nil ->
          children

        vortex ->
          if vortex[:resource_mode] == :dedicated do
            # Resource failure revokes the worker before a replacement grant.
            Enum.reject(children, &match?({Trailblazer.Loop.Runner, _}, &1)) ++
              [{Trailblazer.Vortex.Supervisor, vortex}] ++ planner_children()
          else
            children ++ [{Trailblazer.Vortex.Bridge, vortex}] ++ planner_children()
          end
      end

    children =
      if Application.get_env(:trailblazer, :serve_api, true),
        do: children ++ [Trailblazer.API.Server],
        else: children

    Supervisor.start_link(children, strategy: :one_for_one, name: Trailblazer.Supervisor)
  end

  # Planner assignments are supervised here, not by a detached script (trailblazer:9fa7ba4).
  defp planner_children,
    do: [{Task.Supervisor, name: Trailblazer.Planner.Tasks}, Trailblazer.Planner.Companion]
end
