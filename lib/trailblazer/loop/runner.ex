defmodule Trailblazer.Loop.Runner do
  @moduledoc """
  One serial coding queue. Submission opens the durable case before returning;
  a linked, monitored worker runs the loop so API calls stay responsive. A dead
  worker closes its case as failed and the next queued task runs. The queue is
  in memory (persistent task delivery is phase 3); on application restart, open
  cases are closed as interrupted rather than silently run again.
  """
  use GenServer
  alias Trailblazer.Loop.{CaseRecord, Lifecycle, Workspace}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def submit(task, server \\ __MODULE__) do
    cond do
      Workspace.own_repo?(task.repo) ->
        {:error, :own_repo}

      Keyword.get(Trailblazer.Config.get(:vortex) || [], :resource_mode) == :dedicated ->
        {:error, :use_vortex_resource_gate}

      true ->
        GenServer.call(server, {:submit, task}, :infinity)
    end
  end

  def status(id, server \\ __MODULE__), do: GenServer.call(server, {:status, id}, :infinity)

  @doc "Dispatches an already durable VORTEX case only while the serial executor is idle."
  def dispatch_existing(task, id, server \\ __MODULE__),
    do: GenServer.call(server, {:dispatch_existing, task, id}, :infinity)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    if opts[:recover] do
      for id <- CaseRecord.open_cases(),
          not Trailblazer.Vortex.Store.waiting?(id),
          do: fail(id, "The service stopped before this task finished.")
    end

    {:ok,
     %{
       queue: :queue.new(),
       active: nil,
       run: Keyword.get(opts, :run, &Trailblazer.Loop.run/2),
       prepare: Keyword.get(opts, :prepare, &prepare/1)
     }}
  end

  @impl true
  def handle_call({:dispatch_existing, task, id}, _from, state) do
    record = CaseRecord.get(id)

    cond do
      state.active != nil or not :queue.is_empty(state.queue) ->
        {:reply, {:error, :busy}, state}

      record == nil or record.status != "open" or
          record.task != Jason.decode!(Jason.encode!(task)) ->
        {:reply, {:error, :invalid_case}, state}

      Workspace.own_repo?(task.repo) ->
        {:reply, {:error, :own_repo}, state}

      true ->
        state = start_next(%{state | queue: :queue.in({id, task}, state.queue)})
        {pid, _, _} = state.active
        {:reply, {:ok, pid}, state}
    end
  end

  @impl true
  def handle_call({:submit, task}, _from, state) do
    {:ok, id} = CaseRecord.open(task)
    state = %{state | queue: :queue.in({id, task}, state.queue)}
    {:reply, {:ok, id}, start_next(state)}
  end

  def handle_call({:status, id}, _from, state) do
    status =
      cond do
        state.active && elem(state.active, 2) == id -> :running
        Enum.any?(:queue.to_list(state.queue), fn {case_id, _} -> case_id == id end) -> :queued
        true -> nil
      end

    {:reply, status, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, %{active: {pid, ref, id}} = state) do
    # Loop normally closes the record; this also covers exits it cannot catch.
    fail(id, "The task worker stopped: #{inspect(reason)}.")
    {:noreply, start_next(%{state | active: nil})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.active do
      {pid, _ref, id} = state.active
      Process.exit(pid, :shutdown)
      fail(id, "The task runner stopped before this task finished.")
    end

    for {id, _task} <- :queue.to_list(state.queue),
        do: fail(id, "The task runner stopped before this task started.")

    :ok
  end

  defp start_next(%{active: active} = state) when not is_nil(active), do: state

  defp start_next(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, {id, task}}, rest} ->
        {pid, ref} =
          :erlang.spawn_opt(
            fn ->
              case state.prepare.(task) do
                :ok ->
                  state.run.(task, case_id: id)

                {:error, reason} ->
                  fail(id, "The repository could not be prepared: #{inspect(reason)}.")
              end
            end,
            [:link, :monitor]
          )

        %{state | active: {pid, ref, id}, queue: rest}
    end
  end

  # A repository already watched is brought up to date with git before the
  # task's trail is read from its graph (design §13.7).
  defp prepare(task) do
    with {:ok, _} <- Trailblazer.Indexer.watch(task.repo),
         {:ok, _} <- Trailblazer.Indexer.fresh(task.repo) do
      :ok
    end
  end

  defp fail(id, message) do
    # Observe any Git effect that preceded a worker's death before reporting it.
    recovery = Lifecycle.reconcile(id)

    if match?({:error, _}, recovery) do
      CaseRecord.event(id, :error, %{stage: :lifecycle_recovery, error: inspect(recovery)})
    end

    # Closing an already closed case is harmless and leaves its report intact.
    CaseRecord.close(id, %{case: id, status: :failed, summary: message})
  end
end
