defmodule Trailblazer.Planner.Brain do
  @moduledoc """
  The OTP brain that turns ready board cards into supervised assignments
  (trailblazer:cf1c78a), whenever frontier agents are unavailable and the
  local model is idle.

  It wakes on real events only — the planner board's git-bug refs, a
  companion mirror, a resource release — coalesces notices, and while the
  worker is idle runs one planning cycle: read the board, journal the lease
  intent, take the dedicated resource lease, ask the local model for one
  bounded decision, release the lease, and dispatch the selection only if the
  board still reads exactly as it did when the decision was made. The journal
  (a row per board snapshot on cases.db) is written before each effect and
  read back after a restart: an interrupted cycle never repeats the model.

  Ownership is kept with a fence: a release the router could not confirm
  leaves the lease and the decision in the journal, an SSE listener on the
  router's own status stream is established before the cleanup is retried,
  and a recheck runs once the stream is live. A missing event triggers one
  bounded cleanup investigation. Unverifiable ownership remains fenced until
  a restart.
  """

  use GenServer
  require Logger
  alias Trailblazer.{Backstop, Config, Events}
  alias Trailblazer.Planner.{Board, Companion, Decision, Journal, Route}
  alias Trailblazer.Watcher.Inotify

  # An unload takes seconds; one minute without the router's announcement
  # triggers one cleanup investigation; unresolved ownership remains fenced.
  @drain_limit_ms 60_000

  # The child that dies when its port closes; a port's stdin EOF kills the
  # guarded child even when the child never reads stdin (curl does not).
  @guard ~S|exec 3<&0; "$0" "$@" & child=$!; (read -r ignored <&3; kill -KILL "$child" 2>/dev/null) & guard=$!; wait "$child"; result=$?; kill "$guard" 2>/dev/null; wait "$guard" 2>/dev/null; exit "$result"|

  # Terminal for a snapshot: never inferred again automatically. Only
  # `unavailable` invites a retry, on a later real event.
  @terminal ~w(wait error interrupted dispatched stale assign_failed)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "One wake request; notices coalesce while a cycle runs."
  def wake(pid), do: GenServer.cast(pid, :wake)

  @doc """
  `%{model:, state:, watcher:, last:, last_error:}` — the model name, the
  brain's state (`:disabled`, `:idle`, `:busy`, `:draining`, `:fenced`), the
  board watcher's health, the last journal row and the last failure. No
  secrets, no lease ids.
  """
  def status(pid), do: GenServer.call(pid, :status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      pid: self(),
      config: opts[:config],
      tasks: opts[:tasks] || Trailblazer.Planner.Tasks,
      board_fun: opts[:board] || (&Board.read/1),
      choose_fun: opts[:choose] || (&Decision.choose/1),
      assign_fun: opts[:assign] || (&Board.assign/2),
      research_fun: opts[:research] || (&Trailblazer.Planner.Research.dispatch(opts[:config], &1)),
      acquire_fun: opts[:acquire] || (&__MODULE__.acquire/1),
      release_fun: opts[:release] || (&__MODULE__.release/1),
      status_fun: opts[:bridge_status] || (&Trailblazer.Vortex.Bridge.status/0),
      start_watcher: opts[:start_watcher],
      start_sse: opts[:start_sse],
      drain_limit_ms: opts[:drain_limit_ms] || @drain_limit_ms,
      watcher: :off,
      watcher_ready: false,
      running: %{},
      busy: 0,
      dirty: false,
      state: if(opts[:config], do: :idle, else: :disabled),
      drain: nil,
      last_error: nil
    }

    Events.subscribe(:planner)
    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    if state.config do
      state
      |> then(&recover(Journal.unresolved(), &1))
      |> start_watcher()
      |> request_cycle()
      |> noreply()
    else
      noreply(state)
    end
  end

  # A lease left by an interrupted cycle: release it, then dispatch the
  # retained decision only if the board still reads the same. No model call.
  defp recover([], state), do: state

  defp recover([row | rest], state) do
    case state.release_fun.(row.lease) do
      :ok ->
        state =
          if is_binary(row.ref) and row.ref != "" do
            resume(%{fp: row.fingerprint, ref: row.ref, reason: row.reason}, state)
          else
            Journal.record(row.fingerprint, "", "interrupted", row.ref, row.reason)
            state
          end

        recover(rest, state)

      {:error, :release_unconfirmed} ->
        outcome = if row.ref in [nil, ""], do: :interrupted, else: :decided
        arm_drain(row.fingerprint, row.lease, outcome, row.ref, row.reason, state)

      {:error, reason} ->
        Logger.warning("trailblazer: planner lease recovery failed: #{inspect(reason)}")
        fence(%{state | last_error: "lease recovery failed: #{inspect(reason)}"})
    end
  end

  @impl true
  def handle_cast(:wake, state), do: noreply(request_cycle(state))

  @impl true
  def handle_call(:status, _, state) do
    {:reply,
     %{
       model: Config.get(:planner_model),
       state: state.state,
       watcher:
         case state.watcher do
           {:ok, _} -> if(state.watcher_ready, do: :ready, else: :starting)
           other -> other
         end,
       last:
         case Journal.latest() do
           nil -> nil
           row -> Map.drop(row, [:lease])
         end,
       last_error: state.last_error
     }, state}
  end

  @impl true
  def handle_info({:trailblazer_event, :planner, _}, state), do: noreply(request_cycle(state))

  # Task-to-brain notes from a cycle: a failed release, a failed board read.
  def handle_info({:drain, fp, lease, outcome, ref, reason}, state),
    do: noreply(arm_drain(fp, lease, outcome, ref, reason, state))

  def handle_info({:fence, reason}, state),
    do: noreply(fence(%{state | last_error: reason}))

  def handle_info({:cycle_note, {:last_error, text}}, state),
    do: noreply(%{state | last_error: text})

  # The board watcher's handshake and events.
  def handle_info({:watcher_backend, worker, backend}, state) do
    if watcher_pid(state) == worker, do: send(backend, :begin)

    noreply(state)
  end

  def handle_info({:file_event, worker, event}, state) do
    if watcher_pid(state) == worker do
      case event do
        :ready -> noreply(%{state | watcher_ready: true})
        {:error, reason} -> noreply(%{state | watcher: {:down, reason}})
        _ -> noreply(request_cycle(state))
      end
    else
      noreply(state)
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    if match?({:ok, %{pid: ^pid, ref: ^ref}}, state.watcher) do
      noreply(%{state | watcher: {:down, reason}})
    else
      if Map.has_key?(state.running, ref) do
        {:stop, {:planning_task_failed, reason}, state}
      else
        noreply(state)
      end
    end
  end

  # A cycle task's result: the next coalesced cycle may start.
  def handle_info({ref, :ok}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    done(ref, state)
  end

  # The drain's SSE stream: with -i the HTTP headers end at a blank line;
  # from then on the stream is live and its frames can be trusted.
  def handle_info({port, {:data, {kind, text}}}, %{drain: %{port: port}} = state) do
    text = state.drain.partial <> text

    if kind == :noeol,
      do: noreply(put_in(state.drain.partial, text)),
      else:
        noreply(sse_line(String.trim_trailing(text, "\r"), %{state.drain | partial: ""}, state))
  end

  # The stream ended without settling: the cleanup stays unverified.
  def handle_info({port, {:exit_status, _}}, %{drain: %{port: port, phase: phase}} = state) do
    unless phase == :settling do
      Logger.warning("trailblazer: the router's SSE stream ended without an unload")
      noreply(fence(state))
    else
      noreply(state)
    end
  end

  # No announcement within the bound: the cleanup stays unverified.
  def handle_info({:backstop, ref, anomaly}, %{drain: %{backstop: ref}} = state) do
    Logger.warning(
      "trailblazer: missing router unload notice; investigating once (#{inspect(anomaly)})"
    )

    if state.drain.phase == :settling do
      noreply(fence(state))
    else
      noreply(settle(%{state.drain | phase: :ready, deadline: true}, state))
    end
  end

  # The recheck the live stream triggered, or a frame-triggered retry.
  def handle_info({:drain_settled, token, result}, %{drain: %{settling: token}} = state) do
    case result do
      :ok ->
        drain = state.drain
        Backstop.disarm(drain.backstop)
        Port.close(drain.port)
        noreply(conclude(drain, %{state | last_error: nil}))

      {:error, :release_unconfirmed} ->
        # the stream is live; its unload frame will settle the lease
        drain = %{state.drain | phase: :ready}

        if drain.deadline do
          noreply(fence(state))
        else
          if drain.unloaded,
            do: noreply(settle(%{drain | unloaded: false}, state)),
            else: noreply(%{state | drain: drain})
        end

      {:error, other} ->
        Logger.warning("trailblazer: the drain's release failed: #{inspect(other)}")
        noreply(fence(%{state | last_error: "release failed: #{inspect(other)}"}))
    end
  end

  def handle_info({:drain_settled, _, _}, state), do: noreply(state)

  def handle_info(_, state), do: noreply(state)

  ## Cycles

  # One cycle while the worker is idle; otherwise coalesce into one follow-up.
  defp request_cycle(state) do
    cond do
      state.config == nil or state.state in [:fenced, :draining] ->
        state

      state.busy > 0 ->
        %{state | dirty: true}

      worker_busy?(state) ->
        state

      true ->
        start_cycle(state, cycle_fun(state))
    end
  end

  # The bridge reports real booleans (`resource_release_blocked: false` while
  # idle), so only a present, non-false value is busy.
  defp worker_busy?(state) do
    bridge = state.status_fun.()

    busy_value?(bridge[:active]) or busy_value?(bridge[:resource_release_blocked]) or
      Enum.any?(List.wrap(bridge[:requests]), &(&1.state in ["waiting_resource", "running"])) or
      Enum.any?(
        Companion.list(),
        &(&1.state in ["open", "verifying"] or mirror?(&1.state))
      )
  end

  defp busy_value?(value), do: value not in [nil, false]

  defp mirror?("mirror_" <> _), do: true
  defp mirror?(_), do: false

  defp start_cycle(state, fun) do
    %Task{ref: ref} = Task.Supervisor.async_nolink(state.tasks, fun)

    %{
      state
      | busy: state.busy + 1,
        state: :busy,
        running: Map.put(state.running, ref, true)
    }
  end

  defp done(ref, state) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        noreply(state)

      {_, running} ->
        state = %{state | running: running, busy: state.busy - 1}

        state =
          if state.busy == 0 and state.state == :busy, do: %{state | state: :idle}, else: state

        if state.dirty and state.state == :idle do
          noreply(request_cycle(%{state | dirty: false}))
        else
          noreply(state)
        end
    end
  end

  # The whole planning attempt, inside one task: board, lease, model, release,
  # dispatch. Everything it needs to decide is journaled before the effect.
  defp cycle_fun(state) do
    fn ->
      case state.board_fun.(state.config) do
        {:error, reason} ->
          send(state.pid, {:cycle_note, {:last_error, "board read failed: #{inspect(reason)}"}})

        {:ok, %{fingerprint: fp, cards: cards}} when cards != [] ->
          attempt(fp, cards, state)

        _ ->
          :ok
      end

      :ok
    end
  end

  defp attempt(fp, cards, state) do
    case Journal.get(fp) do
      %{lease: "", state: row_state} when row_state in @terminal ->
        :ok

      %{lease: lease} when lease != "" ->
        settle_row(fp, lease, %{fingerprint: fp, cards: cards}, state)

      _ ->
        infer(fp, cards, state)
    end
  end

  # A left-over lease from an interrupted cycle: release it first, then the
  # retained decision dispatches only if the board still reads the same. No
  # model call.
  defp settle_row(fp, lease, snapshot, state) do
    row = Journal.get(fp)

    case state.release_fun.(lease) do
      :ok ->
        if is_binary(row.ref) and row.ref != "" do
          retain(fp, row.ref, nil, row.reason, snapshot, state)
        else
          Journal.record(fp, "", "interrupted", row.ref, row.reason)
        end

      {:error, :release_unconfirmed} ->
        outcome = if row.ref in [nil, ""], do: :interrupted, else: :decided
        send(state.pid, {:drain, fp, lease, outcome, row.ref, row.reason})

      {:error, reason} ->
        send(state.pid, {:fence, "release failed: #{inspect(reason)}"})
    end
  end

  # The only place the model is called. The lease intent is durable BEFORE
  # the acquire — a crash between the two leaves the row a restart must
  # settle — and the lease is unique per attempt, never a reused constant.
  defp infer(fp, cards, state) do
    lease = "planner-brain-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    Journal.record(fp, lease, "intent", nil, "planning")

    case state.acquire_fun.(lease) do
      :blocked ->
        Journal.record(fp, "", "unavailable", nil, "the local model resource is busy")

      {:ok, held} ->
        unless held == lease, do: Journal.record(fp, held, "intent", nil, "planning")

        case state.choose_fun.(cards) do
          {:ok, :wait} ->
            conclude(fp, held, "wait", nil, nil, "waited", state)

          {:ok, %{ref: ref, reason: reason} = choice} ->
            Journal.record(fp, held, "intent", ref, reason)
            conclude(fp, held, :decided, ref, Map.get(choice, :target), reason, state)

          {:error, reason} ->
            conclude(fp, held, "error", nil, nil, format(reason), state)
        end
    end
  end

  # Releases the lease, then journals the outcome — or, for a decision,
  # verifies currency against a fresh board read and dispatches.
  defp conclude(fp, lease, outcome, ref, target, reason, state) do
    case state.release_fun.(lease) do
      :ok ->
        if outcome == :decided do
          retain(fp, ref, target, reason, snapshot_now(state), state)
        else
          Journal.record(fp, "", outcome, ref, reason)
        end

      {:error, :release_unconfirmed} ->
        send(state.pid, {:drain, fp, lease, outcome, ref, reason})

      {:error, other} ->
        send(state.pid, {:fence, "release failed: #{inspect(other)}"})
    end
  end

  # A fresh read for a decision's currency check: a model call takes minutes,
  # so the cycle's own snapshot is too old to dispatch from.
  defp snapshot_now(state) do
    case state.board_fun.(state.config) do
      {:ok, snapshot} -> snapshot
      _ -> nil
    end
  end

  # A decision dispatches only when the fresh board reads exactly as it did
  # when the decision was made: the same fingerprint and the same ref. An
  # edited context or check is a different board, however similar the ref.
  # The card's own routing check decides the destination: a `dispatch:research`
  # or markerless card never reaches the coder, a checked card never carries
  # the model's research choice, and only a tie is decided by the model's
  # target. Trailblazer dispatch never waits for research; Research holds
  # its own errors.
  defp retain(fp, ref, target, reason, fresh, state) do
    card = fresh && Enum.find(fresh[:cards] || [], &(&1.ref == ref))

    cond do
      fresh == nil ->
        Journal.record(fp, "", "interrupted", ref, reason)

      fresh[:fingerprint] == fp and card != nil ->
        route = retention_route(Route.classify(card.context), target)

        cond do
          route == :trailblazer and target == "research" ->
            Journal.record(
              fp,
              "",
              "error",
              ref,
              "model target research contradicts the checked card"
            )

          route == :research ->
            research_dispatch(fp, ref, card, reason, state)

          not worker_busy?(state) ->
            case state.assign_fun.(state.config, card) do
              :ok -> Journal.record(fp, "", "dispatched", ref, reason)
              {:error, why} -> Journal.record(fp, "", "assign_failed", ref, format(why))
            end

          true ->
            Journal.record(fp, "", "stale", ref, reason)
        end

      true ->
        Journal.record(fp, "", "stale", ref, reason)
    end
  end

  # A tie decidable only by the model's target: a "research" pick makes its
  # route research; every other pick keeps the checked route.
  defp retention_route(:tie, "research"), do: :research
  defp retention_route(route, _target), do: route

  # OpenCode runs one research job at a time: a busy reply is retried by a
  # later event, any other failure holds the card in Research.
  defp research_dispatch(fp, ref, card, reason, state) do
    case state.research_fun do
      nil ->
        Journal.record(fp, "", "assign_failed", ref, "research is not configured")

      fun ->
        case fun.(card) do
          :ok -> Journal.record(fp, "", "dispatched", ref, reason)
          {:error, :busy} -> Journal.record(fp, "", "unavailable", ref, "research is busy")
          {:error, other} -> Journal.record(fp, "", "assign_failed", ref, format(other))
        end
    end
  end

  ## The drain: a release the router could not confirm

  # The decision stays in the journal (the lease is unresolved) until the
  # cleanup is verified. The SSE stream is established first; once its HTTP
  # headers are in, a recheck releases once more — the unload may have
  # finished while the stream was connecting, and its single event must not
  # be missed. Nothing here repeats the model.
  defp arm_drain(fp, lease, outcome, ref, reason, state) do
    case start_sse(state) do
      {:ok, port} ->
        backstop =
          Backstop.arm(:planner_drain, fp, {:ms, state.drain_limit_ms}, fn -> %{fp: fp} end)

        %{
          state
          | state: :draining,
            drain: %{
              port: port,
              backstop: backstop,
              fp: fp,
              lease: lease,
              outcome: outcome,
              ref: ref,
              reason: reason,
              phase: :connecting,
              settling: nil,
              unloaded: false,
              deadline: false,
              partial: ""
            }
        }

      {:error, why} ->
        Logger.warning("trailblazer: no SSE listener for the unload: #{inspect(why)}")
        fence(%{state | last_error: "no SSE listener: #{inspect(why)}"})
    end
  end

  defp start_sse(state) do
    cond do
      fun = state.start_sse -> fun.(sse_url())
      executable = System.find_executable("curl") -> sse_port(executable)
      true -> {:error, :curl_missing}
    end
  end

  defp sse_url do
    url = String.trim_trailing(Config.get(:planner_model_url) || "", "/")
    String.replace_suffix(url, "/v1", "") <> "/models/sse"
  end

  defp sse_port(executable) do
    port =
      Port.open(
        {:spawn_executable, ~c"/bin/sh"},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, 16_384},
          env: [{~c"LC_ALL", ~c"C"}],
          # -i prints the HTTP headers: their end marks a live stream
          args: ["-c", @guard, executable, "-N", "-s", "-i", sse_url()]
        ]
      )

    {:ok, port}
  end

  defp sse_line(line, drain, state) do
    cond do
      drain.phase == :settling ->
        # a settle owns the outcome; further input changes nothing
        %{state | drain: %{drain | unloaded: drain.unloaded or frame(line) == :unload}}

      header?(line, ~r/^HTTP\/\S+ [45]\d\d/) ->
        Logger.warning(
          "trailblazer: the router's SSE stream refused: #{String.slice(line, 0, 60)}"
        )

        fence(state)

      line == "" and drain.phase == :connecting ->
        # headers are in: the stream is live, recheck the cleanup once now
        settle(drain, %{state | drain: %{drain | phase: :ready}})

      frame(line) == :unload ->
        settle(drain, state)

      true ->
        %{state | drain: drain}
    end
  end

  defp header?(line, regex), do: drain_phase_line(line, regex)
  defp drain_phase_line(line, regex), do: Regex.match?(regex, line)

  defp frame(line) do
    case String.trim_leading(line) do
      "data:" <> payload -> decode_frame(String.trim_leading(payload))
      _ -> nil
    end
  end

  defp decode_frame(payload) do
    planner_model = Config.get(:planner_model)

    with {:ok, json} <- Jason.decode(payload),
         "status_change" <- json["event"],
         %{"status" => "unloaded"} <- json["data"],
         model when is_binary(model) <- json["model"],
         true <- model in [planner_model, String.replace(planner_model, ":", "-")] do
      :unload
    else
      _ -> nil
    end
  end

  # One release attempt at a time owns the drain's outcome; the token makes a
  # late result from a superseded attempt harmless.
  defp settle(drain, state) do
    token = make_ref()
    drain = %{drain | phase: :settling, settling: token}

    %Task{ref: task_ref} =
      Task.Supervisor.async_nolink(state.tasks, fn ->
        result =
          try do
            state.release_fun.(drain.lease)
          rescue
            error -> {:error, Exception.message(error)}
          end

        send(state.pid, {:drain_settled, token, result})
        :ok
      end)

    %{state | drain: drain, running: Map.put(state.running, task_ref, true), busy: state.busy + 1}
  end

  # The verified cleanup settles the lease; the retained outcome concludes.
  defp conclude(drain, state) do
    state = %{state | state: :idle, drain: nil}

    if drain.outcome == :decided do
      resume(%{fp: drain.fp, ref: drain.ref, reason: drain.reason}, state)
    else
      Journal.record(drain.fp, "", "#{drain.outcome}", drain.ref, drain.reason)
      state
    end
  end

  defp fence(state) do
    if state.drain do
      Backstop.disarm(state.drain.backstop)
      if Port.info(state.drain.port), do: Port.close(state.drain.port)
    end

    %{state | state: :fenced, drain: nil}
  end

  # A retained decision from a previous run resumes in its own task.
  defp resume(pending, state) do
    start_cycle(state, fn ->
      retain(pending.fp, pending.ref, nil, pending.reason, snapshot_now(state), state)
      :ok
    end)
  end

  ## The board watcher: one inotify watch per admitted repository's git-bug
  ## refs, where claims and labels are written durably. Reads never wake us.

  defp start_watcher(state) do
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

  defp watcher_pid(state) do
    case state.watcher do
      {:ok, %{pid: pid}} -> pid
      _ -> nil
    end
  end

  ## Helpers

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

  defp format(term) when is_binary(term), do: String.slice(term, 0, 900)
  defp format(term), do: String.slice(inspect(term), 0, 900)

  defp noreply(state), do: {:noreply, state}
end
