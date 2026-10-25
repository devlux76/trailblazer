defmodule Trailblazer.Indexer.Supervisor do
  @moduledoc "Supervises one indexer per canonical repository path."
  use Supervisor
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Trailblazer.Indexer.Registry},
        Trailblazer.Watcher,
        {DynamicSupervisor, strategy: :one_for_one, name: Trailblazer.Indexer.Workers},
        # last: it needs the two above, and watches the remembered repos again
        Trailblazer.Indexer.Restore
      ],
      strategy: :one_for_all
    )
  end
end
