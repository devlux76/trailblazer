defmodule Trailblazer.Watcher do
  @moduledoc """
  One native watcher for all repositories (E24, J10), one non-recursive watch per
  repository on its git directory (design §13.7, J26). Git records every commit,
  checkout, add, reset and branch switch by rewriting a file directly under that
  directory, so its state moving is what the watcher reports: `{:git_state,
  git_dir}` to every member of that repository. Uncommitted edits touch nothing
  under the git directory and are found by `git status` when someone asks.

  Membership changes replace the watch list; after native readiness every indexer
  rescans to close the restart gap. Members and the watcher are monitored.
  """
  use GenServer
  require Logger
  alias Trailblazer.{Anomaly, Backstop, Config, Events, Git}

  # Every commit, checkout, add, reset and branch switch rewrites one of these
  # directly in the git directory; everything else there is git's bookkeeping.
  @git_state_files ~w(index HEAD ORIG_HEAD MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD packed-refs)

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    GenServer.start_link(
      __MODULE__,
      [],
      [timeout: :infinity] ++ if(name, do: [name: name], else: [])
    )
  end

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: :infinity}

  def add(path, pid, opts \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:add, Path.expand(path), pid, opts}, :infinity)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       members: %{},
       watcher: nil,
       dirs: [],
       native: false,
       opts: [],
       following: :off,
       reason: nil,
       backstop: nil
     }}
  end

  @impl true
  def handle_call({:add, path, pid, opts}, from, s) do
    {s, callers} = collect_adds(enroll(s, path, pid, opts), [from])
    s = restart(s)
    for caller <- callers, do: GenServer.reply(caller, {s.following, s.reason})
    {:noreply, s}
  end

  defp enroll(s, path, pid, opts) do
    member =
      s.members
      |> Map.get_lazy(pid, fn -> %{ref: Process.monitor(pid), path: path} end)
      |> Map.merge(%{path: path, git_dir: git_dir(path)})

    %{s | members: Map.put(s.members, pid, member), opts: opts}
  end

  # A linked worktree watches its own `.git/worktrees/<name>`; a path that is
  # not a work tree (design §13.7.7) reconciles by stat and gets no watch, and a
  # git that cannot be run at all is no more of an error than that.
  defp git_dir(path) do
    case invoke(fn -> Git.git_dir(path) end) do
      {:ok, dir} -> String.trim_trailing(dir, "/")
      _ -> nil
    end
  end

  # Only collect calls already queued; no debounce clock delays membership.
  defp collect_adds(s, callers) do
    receive do
      {:"$gen_call", from, {:add, path, pid, opts}} ->
        collect_adds(enroll(s, path, pid, opts), [from | callers])
    after
      0 -> {s, callers}
    end
  end

  @impl true
  def handle_info({:watcher_backend, worker, backend}, %{watcher: {worker, _}} = s) do
    send(backend, :begin)
    {:noreply, s}
  end

  def handle_info(
        {:file_event, worker, :ready},
        %{watcher: {worker, _}, following: :starting} = s
      ) do
    case Backstop.disarm(s.backstop) do
      :ok -> {:noreply, ready(%{s | backstop: nil})}
      :fired -> {:noreply, failed(s, :readiness_after_backstop, false)}
    end
  end

  def handle_info({:file_event, worker, {path, _flags}}, %{watcher: {worker, _}} = s)
      when is_binary(path) do
    {:noreply, moved(s, path)}
  end

  # A git directory removed between the existence check and inotifywait's
  # start (a worktree being deleted) makes it refuse every directory. Watch
  # the ones still there; each retry has strictly fewer directories.
  def handle_info({:file_event, worker, {:error, reason}}, %{watcher: {worker, _}} = s) do
    if match?(%{ready: false}, reason) and not Enum.all?(Map.get(s, :dirs, []), &File.dir?/1),
      do: {:noreply, restart(s)},
      else: {:noreply, failed(s, reason)}
  end

  def handle_info({:file_event, worker, :overflow}, %{watcher: {worker, _}} = s) do
    Anomaly.report(:watcher_overflow, :shared, %{
      git_dirs: s.members |> Map.values() |> Enum.map(& &1.git_dir) |> Enum.uniq()
    })

    for {pid, _} <- s.members, do: send(pid, {:watcher_resync, worker})
    {:noreply, s}
  end

  def handle_info({:file_event, worker, :stop}, %{watcher: {worker, _}} = s),
    do: {:noreply, failed(s, :stopped)}

  def handle_info({:backstop, ref, id}, %{backstop: ref} = s) when not is_nil(ref),
    do: {:noreply, failed(s, {:startup_backstop, id}, false)}

  def handle_info({:DOWN, ref, :process, pid, reason}, s) do
    cond do
      s.watcher == {pid, ref} ->
        {:noreply, failed(%{s | watcher: nil}, {:watcher_down, reason})}

      match?(%{ref: ^ref}, s.members[pid]) ->
        {:noreply, restart(%{s | members: Map.delete(s.members, pid)})}

      true ->
        {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s), do: stop(s)

  # Git state moved for a repository: every member of that repository is told
  # which git directory moved, and decides what to reconcile. Every other name
  # (index.lock, COMMIT_EDITMSG, FETCH_HEAD, an object) is git's own business.
  defp moved(s, path) do
    path = String.trim_trailing(path, "/")
    dir = Path.dirname(path)

    if Path.basename(path) in @git_state_files do
      for {pid, %{git_dir: ^dir}} <- s.members, do: send(pid, {:git_state, dir})
    end

    s
  end

  defp restart(s) do
    s = stop(s)

    # A member whose git directory is gone (its worktree was removed) gets no
    # watch, like a path that is not a work tree; one missing directory would
    # otherwise stop inotifywait for every repository.
    dirs =
      s.members
      |> Map.values()
      |> Enum.map(& &1.git_dir)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.filter(&File.dir?/1)
      |> Enum.sort()

    # Map.put: a state hot-loaded from before `dirs` existed has no such key.
    s = Map.put(s, :dirs, dirs)

    if dirs == [] do
      %{s | following: :off, reason: nil}
    else
      native? = not Keyword.has_key?(s.opts, :start_watcher)

      start =
        Keyword.get(s.opts, :start_watcher, fn dirs ->
          Trailblazer.Watcher.Inotify.start_link(
            dirs: dirs,
            owner: self(),
            executable: s.opts[:watcher_executable]
          )
        end)

      subscribe =
        Keyword.get(
          s.opts,
          :subscribe_watcher,
          if(native?, do: fn _ -> :ok end, else: &FileSystem.subscribe/1)
        )

      case invoke(fn -> start.(dirs) end) do
        {:ok, pid} ->
          s = %{
            s
            | watcher: {pid, Process.monitor(pid)},
              native: native?,
              following: :starting,
              reason: nil
          }

          case invoke(fn -> subscribe.(pid) end) do
            :ok ->
              if native? do
                ref =
                  Backstop.arm(
                    :watcher_start,
                    dirs,
                    {:ms, Config.get(:backstop_watcher_ms)},
                    fn -> %{git_dirs: dirs} end
                  )

                %{s | backstop: ref}
              else
                ready(s)
              end

            other ->
              failed(s, {:subscribe, other})
          end

        other ->
          failed(s, {:start, other})
      end
    end
  end

  defp invoke(fun) do
    fun.()
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp ready(s) do
    for {pid, m} <- s.members do
      send(pid, {:watcher_status, :events, nil})
      send(pid, {:watcher_resync, elem(s.watcher, 0)})
      Events.publish({:repo, m.path}, %{event: :watcher_ready})
    end

    %{s | following: :events, reason: nil}
  end

  defp failed(s, reason, report? \\ true) do
    outcome = if s.backstop, do: Backstop.disarm(s.backstop), else: :ok
    s = stop(%{s | backstop: nil})
    text = inspect(reason, limit: 20, printable_limit: 2000)

    for {pid, m} <- s.members do
      Logger.error(
        "trailblazer: no live file watcher for #{m.path}: #{text}; polling for changes"
      )

      send(pid, {:watcher_status, :polling, text})
      Events.publish({:repo, m.path}, %{event: :watcher_down, reason: text})

      if report? and outcome == :ok do
        evidence = %{reason: text}

        evidence =
          if is_map(reason) and Map.has_key?(reason, :capacity),
            do: Map.put(evidence, :capacity, reason.capacity),
            else: evidence

        Anomaly.report(:watcher_down, m.path, evidence)
      end
    end

    %{s | following: :polling, reason: text}
  end

  defp stop(s) do
    if s.backstop, do: Backstop.disarm(s.backstop)

    if s.watcher do
      {pid, ref} = s.watcher

      if s.native do
        stop_ref =
          Backstop.arm(:watcher_stop, :shared, {:ms, Config.get(:backstop_watcher_ms)}, fn ->
            %{watcher: inspect(pid)}
          end)

        send(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} ->
            if Backstop.disarm(stop_ref) == :fired,
              do: Logger.error("trailblazer: watcher stopped after its backstop fired")

          {:backstop, ^stop_ref, id} ->
            Process.exit(pid, :kill)
            receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
            Backstop.disarm(stop_ref)
            Logger.error("trailblazer: watcher shutdown failed, anomaly #{inspect(id)}")
        end
      else
        Process.exit(pid, :shutdown)
        receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
      end
    end

    %{s | watcher: nil, backstop: nil}
  end
end
