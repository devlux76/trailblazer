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
  alias Trailblazer.Planner.{Board, Companion, Decision, Journal}
  alias Trailblazer.Planner.Brain.{Drain, Planning, Watcher}

  # An unload takes seconds; one minute without the router's announcement
  # triggers one cleanup investigation; unresolved ownership remains fenced.
  @drain_limit_ms 60_000

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
      research_fun:
        opts[:research] || (&Trailblazer.Planner.Research.dispatch(opts[:config], &1)),
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
      |> then(&Planning.recover(Journal.unresolved(), &1))
      |> Watcher.start_watcher()
      |> request_cycle()
      |> noreply()
    else
      noreply(state)
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
    do: noreply(Drain.arm_drain(fp, lease, outcome, ref, reason, state))

  def handle_info({:fence, reason}, state),
    do: noreply(Drain.fence(%{state | last_error: reason}))

  def handle_info({:cycle_note, {:last_error, text}}, state),
    do: noreply(%{state | last_error: text})

  # The board watcher's handshake and events.
  def handle_info({:watcher_backend, worker, backend}, state) do
    if Watcher.watcher_pid(state) == worker, do: send(backend, :begin)

    noreply(state)
  end

  def handle_info({:file_event, worker, event}, state) do
    if Watcher.watcher_pid(state) == worker do
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
        noreply(
          Drain.sse_line(String.trim_trailing(text, "\r"), %{state.drain | partial: ""}, state)
        )
  end

  # The stream ended without settling: the cleanup stays unverified.
  def handle_info({port, {:exit_status, _}}, %{drain: %{port: port, phase: phase}} = state) do
    unless phase == :settling do
      Logger.warning("trailblazer: the router's SSE stream ended without an unload")
      noreply(Drain.fence(state))
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
      noreply(Drain.fence(state))
    else
      noreply(Drain.settle(%{state.drain | phase: :ready, deadline: true}, state))
    end
  end

  # The recheck the live stream triggered, or a frame-triggered retry.
  def handle_info({:drain_settled, token, result}, %{drain: %{settling: token}} = state) do
    case result do
      :ok ->
        drain = state.drain
        Backstop.disarm(drain.backstop)
        Port.close(drain.port)
        noreply(Drain.conclude(drain, %{state | last_error: nil}))

      {:error, :release_unconfirmed} ->
        # the stream is live; its unload frame will settle the lease
        drain = %{state.drain | phase: :ready}

        if drain.deadline do
          noreply(Drain.fence(state))
        else
          if drain.unloaded,
            do: noreply(Drain.settle(%{drain | unloaded: false}, state)),
            else: noreply(%{state | drain: drain})
        end

      {:error, other} ->
        Logger.warning("trailblazer: the drain's release failed: #{inspect(other)}")
        noreply(Drain.fence(%{state | last_error: "release failed: #{inspect(other)}"}))
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
  @doc false
  def worker_busy?(state) do
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

  @doc false
  def start_cycle(state, fun) do
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
          Planning.attempt(fp, cards, state)

        _ ->
          :ok
      end

      :ok
    end
  end

  ## Helpers

  defdelegate acquire(id), to: Trailblazer.Planner.Brain.Lease
  defdelegate release(lease), to: Trailblazer.Planner.Brain.Lease

  defp noreply(state), do: {:noreply, state}
end
