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

  alias Trailblazer.{
    Anomaly,
    Config,
    Events,
    Files,
    Store,
    Embed,
    Vectors,
    EmbedGate,
    EmbedHealth,
    Watcher
  }

  alias Trailblazer.Graph.Resolve
  require Logger

  # A change to one of these can change ignored but indexed vendored trees
  # (deps/, vendor/), which git does not report (J25).
  @lockfiles ~w(mix.lock bun.lock bun.lockb package-lock.json yarn.lock pnpm-lock.yaml
                Cargo.lock poetry.lock uv.lock go.sum Gemfile.lock composer.lock)
  @file_module_languages [:javascript, :typescript, :tsx, :python, :c, :cpp, :go]

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

  defp queue_sync(s, selection, waiter \\ nil) do
    waiters = if waiter, do: s.sync_waiters ++ [waiter], else: s.sync_waiters

    %{s | dirty: merge_dirty(s.dirty, selection), sync_waiters: waiters, sync_error: nil}
    |> start_sync()
  end

  defp merge_dirty(:all, _), do: :all
  defp merge_dirty(_, :all), do: :all
  defp merge_dirty(a, b), do: MapSet.union(a, b)

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

  # Also revisit last sync's status paths: a dirty -> clean transition is
  # absent from both the committed diff and today's status (J33).
  defp from_git(s, selection) do
    git = Keyword.get(s.opts, :git, Trailblazer.Git)
    previous = Map.get(s, :git_paths, MapSet.new())

    with {:ok, head} <- git.head(s.path),
         {:ok, status} <- git.status(s.path),
         current = MapSet.new(status.changed ++ status.removed ++ status.untracked),
         {:ok, ignored} <-
           git.ignored(s.path, MapSet.to_list(MapSet.difference(previous, current))) do
      # J29 keeps newly ignored files out of reconciliation; pending-vector
      # cleanup owns their removal. Only absent status paths need this probe.
      previous = MapSet.difference(previous, MapSet.new(ignored))

      selection =
        case committed(git, s, head) do
          {:ok, committed} ->
            paths = committed ++ MapSet.to_list(MapSet.union(previous, current))

            if Enum.any?(paths, &(Path.basename(&1) in @lockfiles)),
              do: :all,
              else: merge_dirty(selection, MapSet.new(paths))

          {:all, _} ->
            :all
        end

      {selection, oid(head), current}
    else
      # Retain prior paths on a failed git probe so the next attempt can retry.
      {:error, :not_a_work_tree} -> {:all, nil, previous}
      {:error, _} -> {:all, s.head, previous}
    end
  end

  defp committed(_git, _s, :unborn), do: {:ok, []}
  defp committed(_git, %{head: nil}, head), do: {:all, head}
  defp committed(_git, %{head: same}, same), do: {:ok, []}

  defp committed(git, s, head) do
    case git.changed(s.path, s.head) do
      {:ok, %{changed: changed, removed: removed}} -> {:ok, changed ++ removed}
      {:error, _} -> {:all, head}
    end
  end

  defp oid(:unborn), do: nil
  defp oid(head), do: head

  defp sync_files(s, selection) do
    try do
      list =
        cond do
          selection == :all ->
            Keyword.get(s.opts, :list_files, &Files.list/1).(s.path)

          seam = s.opts[:list_files] ->
            Enum.filter(seam.(s.path), &MapSet.member?(selection, &1.path))

          true ->
            Files.entries(s.path, selection)
        end

      priority = Enum.map(list, &Map.get(&1, :mtime, 0)) |> Enum.max(fn -> 0 end)
      s = %{s | embed_priority: max(priority, s.embed_priority)}
      known = Store.files(s.id) |> Map.new(&{&1.path, &1.hash})

      # J28: the module paths only, not the whole graph, on every sync
      modules = MapSet.new(Store.module_paths(s.id))

      listed = Map.new(list, &{&1.path, &1})

      paths =
        if selection == :all, do: Enum.uniq(Map.keys(known) ++ Map.keys(listed)), else: selection

      plan = Enum.map(paths, &plan(&1, s, listed, known, modules))
      outcomes = parse_outcomes(plan, s)

      {counts, s} =
        Enum.reduce(plan, {%{parsed: 0, deleted: 0, stale: 0}, s}, &write(&1, &2, outcomes))

      # J31: every graph write above increments a count, including file-module
      # upgrades and stale recovery. A failed/interrupted sync may have written
      # files without resolving; old hot-loaded state also resolves once.
      if counts == %{parsed: 0, deleted: 0, stale: 0} and Map.get(s, :edges_current, false) and
           Store.resolution_current?(s.id) do
        {{:ok, counts}, s}
      else
        # J34 selects durable affected owners on compatible coverage, otherwise
        # rebuilding a full baseline. No filesystem/embedding scope changes.
        resolved = Resolve.next(s.id)

        case Store.replace_resolved_sources(s.id, resolved.revision, resolved) do
          :ok -> {{:ok, counts}, Map.put(s, :edges_current, true)}
          error -> {error, Map.put(s, :edges_current, false)}
        end
      end
    rescue
      e in [File.Error, RuntimeError] ->
        {{:error, {:listing_failed, Exception.message(e)}}, Map.put(s, :edges_current, false)}

      # any other exception in a sync is that sync's error, never the indexer's end (E16)
      e ->
        {{:error, {:sync_failed, Exception.message(e)}}, Map.put(s, :edges_current, false)}
    catch
      # so is an exit (a Store call that times out, a callee that exits): the
      # transient indexer would otherwise be restarted into the same exit until
      # its supervisor, and Restore with it, went down (Codex's review of a90709e)
      kind, reason when kind in [:exit, :throw] ->
        {{:error, {:sync_failed, {kind, reason}}}, Map.put(s, :edges_current, false)}
    end
  end

  defp stale(s, path, counts) do
    Store.mark_stale(s.id, path)
    {Map.update!(counts, :stale, &(&1 + 1)), %{s | stale: MapSet.put(s.stale, path)}}
  end

  defp delete(s, path, counts) do
    Store.delete_file(s.id, path)
    {Map.update!(counts, :deleted, &(&1 + 1)), %{s | stale: MapSet.delete(s.stale, path)}}
  end

  # What a path of this sync needs, decided from the listing, the indexed
  # hashes and the stale set alone: no file is read and nothing is written, so
  # the plan is the order the writes below keep.
  defp plan(path, s, listed, known, modules) do
    cond do
      Map.has_key?(listed, path) ->
        file = listed[path]

        needs_module =
          file.lang in @file_module_languages and
            not MapSet.member?(modules, path)

        if known[path] == file.hash and not MapSet.member?(s.stale, path) and
             not needs_module do
          :skip
        else
          {:parse, path, file.lang}
        end

      Map.has_key?(known, path) ->
        case File.lstat(Path.join(s.path, path)) do
          {:error, :enoent} ->
            {:delete, path}

          {:ok, %File.Stat{type: :regular, size: size}} when size == 0 or size > 400_000 ->
            {:delete, path}

          _ ->
            {:stale, path}
        end

      true ->
        :none
    end
  end

  # Reading and parsing is what the parse pool is for (Q3): the files that need
  # it are read and parsed at the same time, `parse_workers` of them, and each
  # answers its own path whatever order it finishes in. Elixir and Markdown
  # parse in-process and ride the same stream. Only the reading and the parsing
  # are here; the store writes are not, and wait below for the plan's order.
  # An `{:exit, reason}` is the stream's own verdict on a parse that could not
  # answer, and this sync is that exit, exactly as it was before.
  defp parse_outcomes(plan, s) do
    wanted = for {:parse, path, lang} <- plan, do: {path, lang}

    wanted
    |> Task.async_stream(
      fn {path, lang} -> {path, parse_one(s, path, lang)} end,
      max_concurrency: Config.get(:parse_workers),
      ordered: true,
      timeout: :infinity
    )
    |> Stream.map(fn
      {:ok, pair} -> pair
      {:exit, reason} -> exit(reason)
    end)
    |> Map.new()
  end

  defp parse_one(s, path, lang) do
    with {:ok, source} <- read(s, path),
         {:ok, parsed} <- parse_safely(s, path, lang, source) do
      parsed = file_module(parsed, path, lang, source)

      refs = parsed.refs ++ Trailblazer.Parse.Citations.scan(path, source, parsed.nodes)

      module_key =
        if lang in @file_module_languages, do: "#{lang}:module:#{path}##{path}"

      refs =
        if module_key,
          do:
            Enum.map(refs, fn ref ->
              if is_nil(ref.from_key), do: %{ref | from_key: module_key}, else: ref
            end),
          else: refs

      {:ok, %{hash: hash(source), nodes: parsed.nodes, refs: refs}}
    end
  rescue
    # Raised in a task of its own: handed back to this sync's write pass, so a
    # whole sync still answers {:sync_failed, _} and never a crashed worker
    # (E16).
    e -> {:raised, e, __STACKTRACE__}
  catch
    kind, reason -> {:raised, {kind, reason}}
  end

  # The store writes, one path at a time, in the order the plan was made in, so
  # the counts, the stale set and every stored row are what they were.
  defp write(:skip, acc, _outcomes), do: acc
  defp write(:none, acc, _outcomes), do: acc
  defp write({:delete, path}, {counts, s}, _outcomes), do: delete(s, path, counts)
  defp write({:stale, path}, {counts, s}, _outcomes), do: stale(s, path, counts)

  defp write({:parse, path, _lang}, {counts, s}, outcomes) do
    case Map.fetch!(outcomes, path) do
      {:ok, file} ->
        :ok = Store.replace_file(s.id, path, file)
        {Map.update!(counts, :parsed, &(&1 + 1)), %{s | stale: MapSet.delete(s.stale, path)}}

      {:error, _} ->
        stale(s, path, counts)

      {:raised, {:exit, reason}} ->
        exit(reason)

      {:raised, {:throw, reason}} ->
        throw(reason)

      {:raised, e, stack} ->
        reraise e, stack
    end
  end

  defp read(s, path), do: Keyword.get(s.opts, :read_file, &Files.read/2).(s.path, path)

  defp file_module(parsed, path, lang, source)
       when lang in @file_module_languages do
    lines = String.split(source, "\n")
    last = max(1, length(lines) - if(List.last(lines) == "", do: 1, else: 0))

    module = %{
      key: "#{lang}:module:#{path}##{path}",
      lang: Atom.to_string(lang),
      kind: "module",
      name: path,
      qualified: path,
      path: path,
      start_line: 1,
      end_line: last,
      signature: path,
      text_hash: hash(Enum.take(lines, last) |> Enum.join("\n"))
    }

    children = parsed.refs |> Enum.filter(&(&1.kind == "contains")) |> MapSet.new(& &1.target)

    contains =
      parsed.nodes
      |> Enum.reject(&MapSet.member?(children, &1.qualified))
      |> Enum.map(fn node ->
        %{
          from_key: module.key,
          kind: "contains",
          target: node.qualified,
          arity: nil,
          line: node.start_line,
          ambiguous: false
        }
      end)

    %{parsed | nodes: [module | parsed.nodes], refs: parsed.refs ++ contains}
  end

  defp file_module(parsed, _, _, _), do: parsed

  # A parser that raises on one file must not take the repository down (E16):
  # the file is stale, as after a syntax error, and the crash is logged.
  defp parse_safely(s, path, lang, source) do
    Keyword.get(s.opts, :parse, &parse_file/3).(path, lang, source)
  rescue
    e ->
      Logger.warning(
        "trailblazer: the parser raised on #{path} in #{s.path}: #{Exception.message(e)}"
      )

      {:error, {:parser_raised, Exception.message(e)}}
  end

  @doc false
  def parse_file(path, :elixir, source), do: Trailblazer.Parse.Elixir.parse(path, source)
  def parse_file(path, :markdown, source), do: Trailblazer.Parse.Markdown.parse(path, source)
  def parse_file(path, lang, source), do: Trailblazer.Parse.TreeSitter.parse(path, lang, source)
  defp hash(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

  # J29: a file indexed while git reported it, then ignored (a .gitignore or
  # .git/info/exclude entry added later), changes without git ever saying so,
  # and its pending definitions would wait for a sync that never comes. It is
  # settled the way the full listing would: an ignored file is not listed, so
  # it is deleted (a full sync would only mark it stale, still pending), and an
  # ignored file in a vendored tree, which is listed, is read again. Changed
  # files git does report are left to the sync their change starts. Once per
  # path and content, so a file that keeps changing cannot loop.
  defp resync_ignored(s) do
    done = Map.get(s, :resynced, MapSet.new())
    changed = MapSet.difference(Map.get(s, :changed_unsynced, MapSet.new()), done)
    s = Map.put(s, :changed_unsynced, MapSet.new())
    paths = changed |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    git = Keyword.get(s.opts, :git, Trailblazer.Git)

    case paths != [] && git.ignored(s.path, paths) do
      {:ok, [_ | _] = ignored} ->
        {vendored, unlisted} = Enum.split_with(ignored, &Files.vendored?/1)
        Enum.each(unlisted, &Store.delete_file(s.id, &1))
        s = if unlisted == [], do: s, else: Map.put(s, :edges_current, false)
        s = Map.put(s, :resynced, MapSet.union(done, changed))
        s = if vendored == [], do: s, else: queue_sync(s, MapSet.new(vendored))
        # the deletions leave vectors to remove
        kick(s)

      _ ->
        s
    end
  end

  defp kick(%{sync_job: job} = s) when not is_nil(job), do: s
  defp kick(%{store_waiting: true} = s), do: s
  defp kick(%{job: job} = s) when not is_nil(job), do: s
  defp kick(%{waiting: true} = s), do: s

  defp kick(s) do
    deleted = Store.pending_vector_deletes(s.id)
    known = Store.files(s.id) |> Map.new(&{&1.path, &1.hash})

    # 16 definitions per embedder, so every device in the pool has work.
    size = 16 * length(Embed.urls(s.opts))

    nodes =
      if s.paused,
        do: [],
        else: Store.pending_vectors(s.id, size, exclude_stale: true, after_id: s.cursor)

    # A file that no longer matches what was indexed is skipped, and noted with
    # what is on disk now (J29, below).
    {batch, changed} =
      Enum.reduce(nodes, {[], Map.get(s, :changed_unsynced, MapSet.new())}, fn node,
                                                                               {batch, changed} ->
        case read(s, node.path) do
          {:ok, source} ->
            disk = hash(source)

            if disk == known[node.path] do
              text =
                source
                |> String.split("\n")
                |> Enum.slice(node.start_line - 1, node.end_line - node.start_line + 1)
                |> Enum.join("\n")

              calls =
                Store.edges_from(node.id, ["calls"])
                |> Enum.map(&Store.node(&1.to_id))
                |> Enum.reject(&is_nil/1)
                |> Enum.map(& &1.qualified)

              {[{node, Embed.node_text(node, text, calls, Config.doc_limit(s.path))} | batch],
               changed}
            else
              {batch, MapSet.put(changed, {node.path, disk})}
            end

          _ ->
            {batch, MapSet.put(changed, {node.path, :unreadable})}
        end
      end)

    batch = Enum.reverse(batch)
    # Map.put, not %{s | ...}: indexers already running when this code is
    # loaded have no such key yet.
    s = Map.put(s, :changed_unsynced, changed)
    s = if nodes == [], do: s, else: %{s | cursor: List.last(nodes).id}

    cond do
      batch == [] and deleted == [] and nodes != [] ->
        kick(s)

      batch == [] and deleted == [] ->
        :ok = EmbedGate.update(s.embed_priority, false)

        # What is still pending has a file that changed since it was read:
        # the sync that follows the change kicks again (no timer). Git reports
        # no change to an ignored file, so those get a sync here (J29).
        resync_ignored(%{s | cursor: 0})

      true ->
        :ok = EmbedGate.update(s.embed_priority, batch != [])
        parent = self()

        {pid, ref} =
          :erlang.spawn_opt(
            fn ->
              vectors = Keyword.get(s.opts, :vectors, Vectors)
              embed = Keyword.get(s.opts, :embed, Embed)
              pairs = Enum.map(batch, fn {n, _} -> {n.id, n.text_hash} end)

              result =
                with :ok <- vectors.ensure(s.path, s.opts),
                     :ok <- vectors.delete(s.path, deleted, s.opts),
                     :ok <- embed_batch(Map.put(s, :owner, parent), batch, embed, vectors) do
                  :ok
                end

              send(parent, {:batch_done, self(), result, pairs, deleted})
            end,
            [:link, :monitor]
          )

        %{s | job: {pid, ref}}
    end
  end

  defp embed_batch(_, [], _, _), do: :ok

  defp embed_batch(s, batch, embed, vectors) do
    :ok = EmbedGate.acquire(s.owner)

    # The HTTP has no client timeout: one backstop guards the batch, and only
    # the requests run in the guarded process, so the gate is always released.
    limit = {:ms, Config.get(:backstop_embed_batch_ms)}
    evidence = fn -> %{definitions: length(batch)} end

    try do
      case Trailblazer.Backstop.guard(:embed_batch, s.path, limit, evidence, fn ->
             put_batch(s, batch, embed, vectors)
           end) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    after
      EmbedGate.release()
    end
  end

  defp put_batch(s, batch, embed, vectors) do
    with {:ok, values} <-
           Trailblazer.EmbedCache.documents(Enum.map(batch, &elem(&1, 1)), embed, s.opts),
         true <- length(values) == length(batch) do
      points =
        Enum.zip_with(batch, values, fn {n, _}, v ->
          %{id: n.id, vector: v, payload: %{path: n.path, kind: n.kind}}
        end)

      vectors.put(s.path, points, s.opts)
    else
      false -> {:error, :bad_batch}
      error -> error
    end
  end

  # The embedder or Qdrant failed: EmbedHealth probes and publishes :up.
  defp retry(s, reason) do
    :ok = EmbedGate.update(s.embed_priority, false)
    EmbedHealth.down(reason)
    %{s | waiting: true}
  end
end
