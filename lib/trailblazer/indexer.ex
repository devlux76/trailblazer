defmodule Trailblazer.Indexer do
  @moduledoc """
  One incremental graph per watched repository. Graph syncs are serialized;
  a sync reads and parses the files that need it at the same time, `parse_workers`
  of them, through the parse pool, and writes the store one path at a time in the
  order the sync listed them. Embedding and vector writes run separately in
  batches of sixteen. Only a confirmed missing path is deleted; listing/read
  failures retain stale nodes.

  What changed comes from git (design §13.7): each sync asked for by `fresh/1`,
  by the repository's git directory moving, or at start asks git for the
  commits since the indexed HEAD and for the work tree's status, and reads only
  those files. No indexed HEAD, a commit that is gone, a changed lockfile or a
  directory that is not a work tree means a full sync. Nothing polls.

  `watch/2` accepts `:embed` and `:vectors` modules (the production modules by
  default), with options forwarded to them. `embedding: :paused` starts with
  embedding paused. `:filesystem`, `:list_files` and `:read_file` are test seams.
  The shared watcher uses `:start_watcher` (root list) and `:subscribe_watcher`
  injection seams; filesystem failures expose `:watch_error` in status.
  """
  use GenServer
  alias Trailblazer.{Anomaly, EmbedGate, EmbedHealth, Events, Files, Store, Watcher}
  import Trailblazer.Indexer.Embedding, only: [kick: 1, retry: 2]
  import Trailblazer.Indexer.GitSync, only: [from_git: 2]
  import Trailblazer.Indexer.Sync, only: [merge_dirty: 2, sync_files: 2]

  # A watch that succeeded is remembered, so the service watches the repository
  # again when it starts (E11); a failed first watch is not. Trailblazer's own
  # repository may be watched (G5, operator 2026-10-22): whoever fixes Trailblazer
  # then has its graph and vectors. Working on it (run) is still refused.
  def watch(repo, opts \\ []) do
    with {:ok, path} <- Files.canonical_path(repo),
         {:ok, id} <- Store.add_repo(path),
         {:ok, pid} <- start_watch(path, id, opts) do
      :ok = Store.set_watched(id, true)
      {:ok, pid}
    end
  end

  defp start_watch(path, id, opts) do
    case Registry.lookup(__MODULE__.Registry, path) do
      [{pid, _}] ->
        ready(pid)

      [] ->
        case DynamicSupervisor.start_child(__MODULE__.Workers, {__MODULE__, {path, id, opts}}) do
          {:ok, pid} ->
            ready(pid)

          {:error, {:already_started, pid}} ->
            ready(pid)

          error ->
            error
        end
    end
  end

  defp ready(pid) do
    case GenServer.call(pid, :ready, :infinity) do
      {:ok, _} ->
        {:ok, pid}

      error ->
        DynamicSupervisor.terminate_child(__MODULE__.Workers, pid)
        error
    end
  end

  def whereis(repo) do
    with {:ok, path} <- Files.canonical_path(repo),
         [{pid, _}] <- Registry.lookup(__MODULE__.Registry, path),
         do: pid,
         else: (_ -> nil)
  end

  def watched?(repo), do: is_pid(whereis(repo))
  def sync(repo), do: call(repo, :sync)
  def ensure_fresh(repo, paths), do: call(repo, {:fresh, paths})

  @doc """
  Brings the graph up to date with git before the caller answers anything:
  waits for the next sync that starts after this call (J19). Returns
  `{:ok, %{generation, head, parsed, deleted, stale}}`.
  """
  def fresh(repo), do: call(repo, :fresh)
  def status(repo), do: call(repo, :status)
  def pause_embedding(repo), do: call(repo, :pause)
  def resume_embedding(repo), do: call(repo, :resume)

  defp call(repo, msg) do
    case whereis(repo) do
      nil -> {:error, :not_watched}
      pid -> GenServer.call(pid, msg, :infinity)
    end
  end

  def child_spec(arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :transient}

  def start_link({path, id, opts}) do
    GenServer.start_link(__MODULE__, {path, id, opts},
      name: {:via, Registry, {__MODULE__.Registry, path}}
    )
  end

  @impl true
  def init({path, id, opts}) do
    Process.flag(:trap_exit, true)
    :ok = EmbedGate.update(0, false)
    Events.subscribe(:store)
    Events.subscribe(:embedder)
    store = Process.whereis(Store)

    {watcher, following, watch_error} =
      if Keyword.get(opts, :filesystem, true) do
        {following, reason} = Watcher.add(path, self(), opts)
        {Process.whereis(Watcher), following, reason}
      else
        {nil, :off, nil}
      end

    head = Store.indexed_head(id)
    # J27: a repository restored at boot waits for its first git change or
    # request: no reconcile, no embedding, until something asks for it.
    deferred = opts[:defer] == true

    {:ok,
     %{
       path: path,
       id: id,
       opts: opts,
       watcher: watcher,
       embed_priority: 0,
       following: following,
       watch_error: watch_error,
       # J28: one query, not the whole graph (22 snapshots at boot read 11 GB)
       stale: MapSet.new(Store.stale_paths(id)),
       paused: opts[:embedding] == :paused or deferred,
       deferred: deferred,
       waiting: false,
       job: nil,
       sync_job: nil,
       # At start git says what changed since the indexed HEAD; without one,
       # the first sync is a full one.
       dirty: MapSet.new(),
       git: not deferred,
       generation: 0,
       head: head,
       git_paths: MapSet.new(Store.indexed_dirty(id)),
       sync_waiters: [],
       ready_waiters: [],
       resync_watchers: [],
       sync_error: nil,
       store: store,
       store_monitor: Process.monitor(store),
       store_waiting: false,
       cursor: 0,
       initial_result: if(deferred, do: {:ok, :deferred})
     }, {:continue, :sync}}
  end

  @impl true
  def handle_continue(:sync, s), do: {:noreply, start_sync(s)}

  @impl true
  def handle_call(:ready, from, %{initial_result: nil} = s),
    do: {:noreply, %{s | ready_waiters: [from | s.ready_waiters]}}

  def handle_call(:ready, _, s), do: {:reply, s.initial_result, s}

  def handle_call(:sync, from, s),
    do: {:noreply, queue_sync(wake(s), :all, {from, :sync})}

  def handle_call(:fresh, from, s), do: {:noreply, queue_git(wake(s), {from, :git})}

  def handle_call({:fresh, []}, _, s), do: {:reply, :ok, s}

  def handle_call({:fresh, paths}, from, s),
    do: {:noreply, queue_sync(wake(s), MapSet.new(paths), {from, :fresh})}

  def handle_call(:status, _, s) do
    # J28: counted by the database; status is asked on every ranger run
    counts = Store.counts(s.id)

    result = %{
      syncing: s.sync_job != nil,
      deferred: s.deferred,
      head: s.head,
      generation: s.generation,
      sync_error: s.sync_error,
      files: length(Store.files(s.id)),
      nodes: counts.nodes,
      edges: counts.edges,
      pending_vectors: length(Store.pending_vectors(s.id, 2_147_483_647)),
      stale_files: MapSet.size(s.stale),
      following: s.following,
      watch_error: s.watch_error,
      embed_priority: s.embed_priority,
      embedding:
        cond(
          do: (
            s.job != nil and EmbedGate.queued?(elem(s.job, 0)) -> :queued
            s.paused -> :paused
            s.waiting -> :waiting_for_service
            true -> :running
          )
        )
    }

    {:reply, result, s}
  end

  def handle_call(:pause, _, s), do: {:reply, :ok, %{s | paused: true}}

  def handle_call(:resume, _, s),
    do: {:reply, :ok, kick(%{s | paused: false, waiting: false, cursor: 0})}

  @impl true
  # Without a live watch the repository is only colder: every request still
  # reconciles from git first, so nothing polls (design §13.7).
  def handle_info({:watcher_status, following, reason}, s),
    do: {:noreply, %{s | following: following, watch_error: reason}}

  # J27: a deferred repository has nothing to catch up on; it reconciles
  # when it wakes. (The shared watcher resyncs every member on each restart,
  # and a boot restarts it once per repository added.)
  def handle_info({:watcher_resync, watcher}, %{deferred: true} = s) do
    Events.publish({:repo, s.path}, %{event: :watcher_resynced, watcher: watcher})
    {:noreply, s}
  end

  def handle_info({:watcher_resync, watcher}, s) do
    s = %{s | resync_watchers: Enum.uniq([watcher | s.resync_watchers])}
    {:noreply, queue_git(s)}
  end

  def handle_info({:git_state, _git_dir}, s), do: {:noreply, queue_git(wake(s))}

  def handle_info({:file_event, _, {path, flags}}, s) do
    selection = if :isdir in flags, do: :all, else: MapSet.new([Path.relative_to(path, s.path)])
    {:noreply, queue_sync(wake(s), selection)}
  end

  def handle_info(:changed, s), do: {:noreply, queue_sync(wake(s), :all)}

  def handle_info({:sync_done, pid, result, updated}, %{sync_job: %{pid: pid} = job} = s) do
    Process.demonitor(job.ref, [:flush])
    s = %{s | sync_job: nil}

    if s.store_waiting or s.store != job.store do
      s = Map.put(s, :edges_current, false)
      # A store restart can lose an unacknowledged batch (J13). Keep the
      # producer's input and waiters until the new store's ready event.
      s = %{
        s
        | dirty: merge_dirty(s.dirty, job.selection),
          git: s.git or job.git,
          sync_waiters: job.waiters ++ s.sync_waiters,
          resync_watchers: Enum.uniq(job.watchers ++ s.resync_watchers)
      }

      {:noreply, start_sync(s)}
    else
      s = Map.merge(s, updated)
      s = if match?({:ok, _}, result), do: %{s | generation: s.generation + 1}, else: s
      :ok = EmbedGate.update(s.embed_priority, :keep)

      for {from, kind} <- job.waiters do
        reply =
          case {kind, result} do
            {:fresh, {:ok, _}} ->
              :ok

            {:git, {:ok, counts}} ->
              {:ok, Map.merge(counts, %{generation: s.generation, head: s.head})}

            _ ->
              result
          end

        GenServer.reply(from, reply)
      end

      s =
        if s.initial_result == nil do
          for from <- s.ready_waiters, do: GenServer.reply(from, result)
          %{s | initial_result: result, ready_waiters: []}
        else
          s
        end

      for watcher <- job.watchers,
          do: Events.publish({:repo, s.path}, %{event: :watcher_resynced, watcher: watcher})

      Events.publish({:repo, s.path}, %{
        event: :sync_done,
        result: result,
        generation: s.generation,
        head: s.head
      })

      s =
        if match?({:ok, _}, result),
          do: %{s | sync_error: nil},
          else: %{
            s
            | sync_error: result,
              dirty: merge_dirty(s.dirty, job.selection),
              git: s.git or job.git
          }

      {:noreply, s |> start_sync() |> kick()}
    end
  end

  def handle_info({:trailblazer_event, :store, {:ready, store}}, s) do
    Process.demonitor(s.store_monitor, [:flush])
    s = %{s | store: store, store_monitor: Process.monitor(store), store_waiting: false}
    s = Map.put(s, :edges_current, false)
    {:noreply, queue_sync(s, :all)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{store_monitor: ref} = s),
    do: {:noreply, %{s | store_waiting: true, dirty: :all}}

  def handle_info({:DOWN, ref, :process, pid, reason}, %{sync_job: %{ref: ref, pid: pid}} = s) do
    Anomaly.report(:index_sync, s.path, %{reason: inspect(reason)})

    handle_info(
      {:sync_done, pid, {:error, {:sync_worker_down, reason}}, %{}},
      Map.put(s, :edges_current, false)
    )
  end

  def handle_info(:embed, s), do: {:noreply, kick(%{s | waiting: false, cursor: 0})}

  # EmbedHealth says the embedder answers again: resume, no timer of our own.
  def handle_info({:trailblazer_event, :embedder, %{state: :up}}, s),
    do: {:noreply, kick(%{s | waiting: false, cursor: 0})}

  def handle_info({:batch_done, pid, result, pairs, deleted}, %{job: {pid, ref}} = s) do
    Process.demonitor(ref, [:flush])
    s = %{s | job: nil}

    case result do
      :ok ->
        if pairs != [], do: EmbedHealth.ok()
        Store.vector_done(pairs)
        Store.vector_deleted(s.id, deleted)
        # A sync can delete a node while this worker is writing its point.
        # Tombstones remain queued until a later worker removes those points.
        {:noreply, kick(%{s | waiting: false})}

      {:error, reason} ->
        {:noreply, retry(s, reason)}
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{job: {_, ref}} = s),
    do: {:noreply, retry(%{s | job: nil}, {:embed_worker_down, reason})}

  def handle_info({:EXIT, pid, reason}, %{watcher: pid} = s),
    do: {:stop, {:watcher_down, reason}, s}

  def handle_info(_, s), do: {:noreply, s}
  @impl true
  def terminate(_, s) do
    if s.job, do: Process.exit(elem(s.job, 0), :shutdown)
    if s.sync_job, do: Process.exit(s.sync_job.pid, :shutdown)
    :ok
  end

  # J27: the first request or git change wakes a deferred repository: it
  # reconciles from git and its embedding starts (unless paused by option).
  defp wake(%{deferred: true} = s),
    do: %{s | deferred: false, git: true, paused: s.opts[:embedding] == :paused}

  defp wake(s), do: s

  defp queue_git(s, waiter \\ nil), do: queue_sync(%{s | git: true}, MapSet.new(), waiter)

  @doc false
  def queue_sync(s, selection, waiter \\ nil) do
    waiters = if waiter, do: s.sync_waiters ++ [waiter], else: s.sync_waiters

    %{s | dirty: merge_dirty(s.dirty, selection), sync_waiters: waiters, sync_error: nil}
    |> start_sync()
  end

  defp start_sync(%{sync_job: job} = s) when not is_nil(job), do: s
  defp start_sync(%{store_waiting: true} = s), do: s
  defp start_sync(%{sync_error: error} = s) when not is_nil(error), do: s

  defp start_sync(s) do
    if not s.git and s.dirty != :all and MapSet.size(s.dirty) == 0 do
      s
    else
      selection = s.dirty
      git? = s.git
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          {selection, head, git_paths} =
            if git?,
              do: from_git(s, selection),
              else: {selection, s.head, Map.get(s, :git_paths, MapSet.new())}

          {result, updated} = sync_files(%{s | cursor: 0}, selection)

          # Recorded only after every file of the sync is written: a sync that
          # failed leaves the old HEAD, and the next one diffs from there.
          if match?({:ok, _}, result) and git? and
               (head != s.head or git_paths != Map.get(s, :git_paths, MapSet.new())),
             do: :ok = Store.set_indexed_git_state(s.id, head, MapSet.to_list(git_paths))

          updated =
            updated |> Map.take([:stale, :embed_priority, :edges_current]) |> Map.put(:head, head)

          updated =
            if match?({:ok, _}, result) and git?,
              do: Map.put(updated, :git_paths, git_paths),
              else: updated

          send(parent, {:sync_done, self(), result, updated})
        end)

      job = %{
        pid: pid,
        ref: ref,
        store: s.store,
        selection: selection,
        git: git?,
        waiters: s.sync_waiters,
        watchers: s.resync_watchers
      }

      Events.publish({:repo, s.path}, %{event: :sync_started})

      %{
        s
        | sync_job: job,
          dirty: MapSet.new(),
          git: false,
          sync_waiters: [],
          resync_watchers: [],
          cursor: 0
      }
    end
  end

  @doc false
  defdelegate parse_file(path, lang, source), to: Trailblazer.Indexer.Parse
end
