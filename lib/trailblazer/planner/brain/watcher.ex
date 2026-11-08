defmodule Trailblazer.Planner.Brain.Watcher do
  @moduledoc "The brain's board watcher: one inotify watch per admitted repository's git-bug refs."

  alias Trailblazer.Watcher.Inotify

  @doc false
  def start_watcher(state) do
    cond do
      fun = state.start_watcher ->
        %{state | watcher: fun.(state.config)}

      watch_dirs(state.config) == [] ->
        %{state | watcher: {:down, :no_watchable_repositories}}

      true ->
        case GenServer.start_link(Inotify, owner: self(), dirs: watch_dirs(state.config)) do
          {:ok, pid} ->
            %{state | watcher: {:ok, %{pid: pid, ref: Process.monitor(pid)}}}

          {:error, reason} ->
            %{state | watcher: {:down, reason}}
        end
    end
  end

  # Where the refs exist they are watched; otherwise the git directory is (a
  # claim's first label creates refs/bugs inside it). A path with neither is
  # not a git repository and cannot be watched.
  defp watch_dirs(config) do
    repos = (config && Map.get(config, :repos)) || %{}

    Enum.flat_map(Map.keys(repos), fn repo ->
      refs = Path.join([repo, ".git", "refs", "bugs"])
      git = Path.join([repo, ".git"])

      cond do
        File.dir?(refs) -> [refs]
        File.dir?(git) -> [git]
        true -> []
      end
    end)
  end

  @doc false
  def watcher_pid(state) do
    case state.watcher do
      {:ok, %{pid: pid}} -> pid
      _ -> nil
    end
  end
end
