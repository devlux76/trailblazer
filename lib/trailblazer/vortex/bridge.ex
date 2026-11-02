defmodule Trailblazer.Vortex.Bridge do
  @moduledoc """
  Model-free VORTEX admission and durable response delivery. A local ring or
  explicit recovery call can restore intake after failure. Production listens
  on a VORTEX attach line and reads/acks per notice; case events deliver reports without
  waiting for a model to become idle. Production dispatch denies ownership until
  a verified resource adapter is installed. Worker death alone is not release.
  """
  use GenServer
  require Logger
  alias Trailblazer.Events
  alias Trailblazer.Loop.{Runner, CaseRecord}
  alias Trailblazer.Vortex.{Protocol, Store, Transport}

  # Unconfirmed release backoff: 5 s doubling to 5 min, reported once after
  # five failures (about 75 s in), retried for as long as it takes.
  @release_retry_ms 5_000
  @release_retry_max_ms 300_000
  @release_report_after 5

  def start_link(opts),
    do:
      GenServer.start_link(
        __MODULE__,
        opts,
        if(opts[:name] == nil and Keyword.has_key?(opts, :name),
          do: [],
          else: [name: opts[:name] || __MODULE__]
        )
      )

  def pump(server \\ __MODULE__), do: GenServer.call(server, :pump, :infinity)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status, :infinity)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    # State holds data and external funs only. A closure made here points at
    # the module version that ran init and breaks once a hot load purges it.
    state = %{
      peers: Keyword.fetch!(opts, :peers),
      transport:
        opts[:transport] || {:endpoint, Keyword.fetch!(opts, :endpoint), opts[:owner_peer]},
      runner: opts[:runner] || Runner,
      resource: opts[:resource] || {&__MODULE__.no_grant/1, &__MODULE__.no_release/1},
      active: nil,
      blocked_release: nil,
      # A release the resource could not confirm (the router not up yet, a
      # model still resident) is asked again with backoff, never parked for
      # good: a parked release fences every later dispatch (trailblazer:ebd0381).
      release_failures: 0,
      release_retry_ms: opts[:release_retry_ms] || @release_retry_ms,
      release_retry_max_ms: opts[:release_retry_max_ms] || @release_retry_max_ms,
      resource_busy: false,
      jobs: %{},
      reading: false,
      listen: opts[:listen] || false,
      senders: %{},
      transmitted: MapSet.new()
    }

    Events.subscribe(:anomaly)
    {:ok, state, {:continue, :restore}}
  end

  @impl true
  def handle_continue(:restore, state) do
    for id <- Store.ids(), do: Events.subscribe({:case, id})

    for [id, _] <- Store.holds(),
        CaseRecord.get(id, inline: false).status == "open",
        Runner.status(id, state.runner) == nil do
      CaseRecord.close(id, %{
        case: id,
        status: :failed,
        summary:
          "Resource acquisition or execution interrupted; ownership requires verified cleanup."
      })
    end

    state = reconcile(state)
    {:noreply, state |> flush() |> dispatch() |> listen()}
  end

  @impl true
  # A bridge hot-loaded from state that predates `:transmitted` seeds it before
  # handling anything, so the seed holds only messages that already existed
  # (all sent, many times) and never the one this message is about to queue.
  def handle_call(request, from, state) when not is_map_key(state, :transmitted),
    do: handle_call(request, from, seed_transmitted(state))

  def handle_call(:status, _from, state) do
    requests =
      for id <- Store.ids(),
          do: Map.take(Store.get(id), [:case_id, :state, :peer, :frontier, :returned_fix])

    {:reply,
     %{
       requests: requests,
       pending_messages: length(Store.outbox()),
       active: state.active && state.active.id,
       resource_release_blocked: state.blocked_release != nil
     }, state}
  end

  def handle_call(:pump, _from, %{reading: true} = state),
    do: {:reply, {:error, :pump_busy}, state}

  def handle_call(:pump, from, state) do
    state = job(%{state | reading: true}, {:read, from}, fn -> call(state, "read", %{}) end)
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) when not is_map_key(state, :transmitted),
    do: handle_info(message, seed_transmitted(state))

  # Delivery faults stay in the local anomaly ledger. Sending them through
  # the same broken transport would make every timeout create another send.
  def handle_info({:trailblazer_event, :anomaly, %{kind: kind}}, state)
      when kind in [:vortex, "vortex"], do: {:noreply, state}

  def handle_info({:trailblazer_event, :anomaly, anomaly}, state) do
    Store.investigate(anomaly, frontier(state, %{frontier: nil}))
    {:noreply, flush(state)}
  end

  # The backoff timer of a release that could not be confirmed. Another
  # resource job in flight asks again after it; a lease released or replaced
  # meanwhile is left alone.
  def handle_info({:retry_release, id, lease}, %{blocked_release: lease} = state) do
    if state.resource_busy do
      Process.send_after(
        self(),
        {:retry_release, id, lease},
        Map.get(state, :release_retry_ms, @release_retry_ms)
      )

      {:noreply, state}
    else
      {:noreply, release_resource(state, id, lease)}
    end
  end

  def handle_info({:retry_release, _id, _lease}, state), do: {:noreply, state}

  def handle_info({:trailblazer_event, {:case, _id}, %{closed: true}}, state) do
    {:noreply, state |> reconcile() |> flush()}
  end

  # A notice on the attach line. One read runs at a time; a notice that
  # lands during it is remembered and read after the ack.
  def handle_info({:vortex_notice, unread}, state) when is_integer(unread) and unread > 0 do
    if state.reading do
      {:noreply, Map.put(state, :notice, true)}
    else
      {:noreply, job(%{state | reading: true}, {:read, nil}, fn -> call(state, "read", %{}) end)}
    end
  end

  def handle_info({:vortex_notice, _}, state), do: {:noreply, state}

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{kind: kind}, jobs} ->
        Process.demonitor(ref, [:flush])
        {:noreply, completed(kind, result, %{state | jobs: jobs})}
    end
  end

  def handle_info({:trailblazer_event, _, _}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{active: %{ref: ref, lease: lease}} = state
      ) do
    {:noreply, release_resource(%{state | active: nil}, state.active.id, lease)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{kind: kind}, jobs} ->
        {:noreply, completed(kind, {:error, :transport_unavailable}, %{state | jobs: jobs})}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    for {_, %{task: task}} <- state.jobs, do: Process.exit(task.pid, :kill)
    :ok
  end

  defp job(state, kind, fun) do
    task = Task.async(fun)
    %{state | jobs: Map.put(state.jobs, task.ref, %{task: task, kind: kind})}
  end

  # Presence is one open attach line (vortex docs/2026-10-22-presence-design.md),
  # held for the life of the bridge. When it closes, nothing reopens it on a
  # clock: with no line the service rings Trailblazer's adapter, whose pump
  # ends here and opens it again.
  defp listen(%{listen: true} = state) do
    if Map.get(state, :line) do
      state
    else
      parent = self()
      # The line lives as long as the bridge, so it must not run bridge code:
      # a process still in an old version blocks every later hot load.
      task =
        case state.transport do
          {:endpoint, endpoint, peer} ->
            Task.async(Transport, :call, [endpoint, "attach", %{"notify" => parent}, peer])

          fun ->
            Task.async(fn -> fun.("attach", %{"notify" => parent}) end)
        end

      %{state | jobs: Map.put(state.jobs, task.ref, %{task: task, kind: :line})}
      |> Map.put(:line, task.ref)
    end
  end

  defp listen(state), do: state

  defp completed({:acquire_resource, id, reserved_lease}, result, state) do
    state = %{state | resource_busy: false}

    case result do
      {:ok, lease} when is_binary(lease) ->
        request = Store.get(id)

        if request.state in ["waiting_resource", "running"] and
             CaseRecord.get(id, inline: false).status == "open" and authorized?(request, state) do
          task = Map.new(request.task, fn {k, v} -> {String.to_existing_atom(k), v} end)
          :ok = Store.state(id, "running", lease)

          case Runner.dispatch_existing(task, id, state.runner) do
            {:ok, pid} ->
              %{state | active: %{id: id, ref: Process.monitor(pid), lease: lease}}

            {:error, _} ->
              :ok = Store.state(id, "waiting_resource")
              release_resource(state, id, lease)
          end
        else
          release_resource(state, id, lease)
        end

      :blocked ->
        Store.released(id)
        Events.publish(:planner, {:resource_released, id})

        if CaseRecord.get(id, inline: false).status == "open",
          do: Store.state(id, "waiting_resource")

        state

      _ ->
        CaseRecord.close(id, %{
          case: id,
          status: :failed,
          summary: "Resource grant reply lost; ownership requires verified cleanup."
        })

        release_resource(state, id, reserved_lease)
    end
  end

  defp completed({:release_resource, id, lease}, result, state) do
    state = %{state | resource_busy: false}

    if result == :ok do
      Store.released(id)
      Events.publish(:planner, {:resource_released, id})

      state
      |> Map.merge(%{blocked_release: nil, release_failures: 0})
      |> reconcile()
      |> flush()
      |> dispatch()
    else
      failures = Map.get(state, :release_failures, 0) + 1
      base = Map.get(state, :release_retry_ms, @release_retry_ms)
      max = Map.get(state, :release_retry_max_ms, @release_retry_max_ms)
      delay = min(base * Integer.pow(2, min(failures - 1, 20)), max)
      Process.send_after(self(), {:retry_release, id, lease}, delay)

      # Once it has failed long enough to be more than a slow start, say so;
      # the retries go on regardless.
      if failures == @release_report_after do
        Trailblazer.Anomaly.report(:resource_release_blocked, id, %{
          lease: lease,
          failures: failures,
          result: inspect(result, limit: 10)
        })
      end

      Map.merge(state, %{blocked_release: lease, release_failures: failures})
    end
  end

  defp completed(:wait, {:ok, _}, state),
    do: job(state, {:read, nil}, fn -> call(state, "read", %{}) end)

  # A wait still in flight from before the attach line (hot-load) ends here.
  defp completed(:wait, _, state), do: listen(%{state | reading: false})

  defp completed(:line, _, state), do: Map.put(state, :line, nil)

  defp completed({:read, from}, {:ok, page}, state) do
    case value(page, "events") do
      events when is_list(events) ->
        last =
          Enum.reduce(events, nil, fn event, _ ->
            cursor = value(event, "cursor")
            if not is_integer(cursor) or cursor < 0, do: raise("invalid VORTEX cursor")
            process_event(event, state)
            cursor
          end)

        state = state |> reconcile() |> flush() |> dispatch()

        if is_integer(last) do
          job(state, {:ack, from}, fn -> call(state, "ack", %{"cursor" => last}) end)
        else
          completed({:ack, from}, {:ok, %{}}, state)
        end

      _ ->
        completed({:ack, from}, {:error, :invalid_page}, state)
    end
  end

  defp completed({:read, from}, error, state), do: completed({:ack, from}, error, state)

  defp completed({:ack, from}, result, state) do
    if from, do: GenServer.reply(from, if(match?({:ok, _}, result), do: :ok, else: result))
    state = %{state | reading: false}

    cond do
      not match?({:ok, _}, result) ->
        state

      Map.get(state, :notice) ->
        state = Map.put(state, :notice, false)

        job(%{state | reading: true}, {:read, nil}, fn -> call(state, "read", %{}) end)
        |> listen()

      true ->
        listen(state)
    end
  end

  defp completed({:send, peer, attempted}, result, state) do
    # A job started before the hot load that added `transmitted` returns a list.
    {receipted, sent} =
      case result do
        %{receipted: receipted, transmitted: sent} -> {receipted, sent}
        list when is_list(list) -> {list, []}
        _ -> {[], []}
      end

    for message <- receipted, do: Store.receipt(peer, message.id)
    state = Map.put(state, :transmitted, MapSet.union(transmitted(state), MapSet.new(sent)))

    # Send messages added while this peer's worker was busy, but never spin on
    # the same unreceipted/failed batch. A future ring/recovery call retries it.
    state = %{state | senders: Map.delete(state.senders, peer)}
    flush(state, attempted, peer)
  end

  # Conference messages are the research route's reply channel (trailblazer:4cc63df):
  # they lift unaltered to the planner, and an authorized peer's message also says
  # it recovered, which wakes a held card's retry. They are not protocol intake.
  defp process_event(
         %{"kind" => "conference_message", "room" => "conference:" <> id} = raw,
         state
       ) do
    peer = value(raw, "peer")

    Events.publish(:planner, {
      :research_conference,
      %{
        "conference" => id,
        "peer" => peer,
        "body" => value(raw, "body"),
        "cursor" => value(raw, "cursor")
      }
    })

    if Map.has_key?(state.peers, peer),
      do: Events.publish(:planner, {:research_recovered, peer})
  end

  defp process_event(raw, state) do
    event = %{peer: value(raw, "peer"), room: value(raw, "room")}

    with "message" <- value(raw, "kind"),
         {:ok, policy} <- Protocol.peer(event, state.peers),
         {:ok, message} <- Protocol.decode(value(raw, "body")) do
      result = receive_message(event, policy, message, state)

      case result do
        :ok ->
          :ok

        {:error, reason} ->
          Store.classify(event.peer, value(raw, "cursor"), reason)
          Logger.warning("trailblazer: VORTEX event refused: #{inspect(reason)}")
      end
    else
      _ -> Store.classify(event.peer, value(raw, "cursor"), :ignored)
    end
  end

  defp receive_message(event, policy, %{"type" => "task"} = message, _state) do
    with {:ok, task} <- Protocol.task(message, policy, event.peer),
         {planner, task} = Map.pop(task, :planner),
         {:ok, id, fresh} <-
           Store.admit(event.peer, event.room, message["request_id"], task, planner) do
      Events.subscribe({:case, id})
      if planner && fresh == :new, do: Events.publish(:planner, {:assigned, id})
      :ok
    end
  end

  defp receive_message(
         event,
         %{role: role},
         %{"type" => "cancel", "payload" => %{"case" => id}} = message,
         _
       )
       when role in [:caller, :collaborator] do
    request_id = message["request_id"]

    case Store.get(id) do
      %{peer: peer, request_id: request, state: "waiting_resource"}
      when peer == event.peer and request == request_id ->
        CaseRecord.close(id, %{
          case: id,
          status: :cancelled,
          summary: "Cancelled by the caller before execution."
        })

      _ ->
        {:error, :cannot_cancel}
    end
  end

  defp receive_message(event, _, %{"type" => "receipt", "payload" => payload}, _),
    do: Store.receipt(event.peer, payload["message_id"])

  defp receive_message(event, %{role: role}, %{"type" => type, "payload" => payload} = message, _)
       when type in ~w(claim returned_fix) and role in [:frontier, :collaborator] do
    id = payload["case"]
    request = if is_binary(id), do: Store.get(id)

    with %{request_id: request_id} <- request,
         true <- request_id == message["request_id"],
         :ok <-
           if(type == "claim",
             do: Store.claim(event.peer, id),
             else: Store.returned_fix(event.peer, id, payload)
           ) do
      Store.acknowledgment(id, event.peer, event.room, request_id, message["id"])
    else
      _ -> {:error, :not_assigned}
    end
  end

  defp receive_message(_, _, _, _), do: {:error, :unexpected_message}

  defp reconcile(state) do
    for anomaly <- Trailblazer.Anomaly.list(open: true),
        anomaly.sent == 0,
        anomaly.kind != "vortex" do
      Store.investigate(anomaly, frontier(state, %{frontier: nil}))
    end

    for id <- Store.ids(),
        %{state: status} = request = Store.get(id),
        status in ~w(waiting_resource running waiting_frontier),
        request.peer != "internal",
        %{status: closed} <- [CaseRecord.get(id, inline: false)],
        closed != "open" do
      Store.finish(id, frontier(state, request))
    end

    if state.active == nil and not state.resource_busy do
      case Enum.find(Store.holds(), fn [id, _] ->
             CaseRecord.get(id, inline: false).status != "open"
           end) do
        [id, lease] -> release_resource(state, id, lease)
        nil -> state
      end
    else
      state
    end
  end

  defp frontier(state, request) do
    Enum.find_value(state.peers, fn {peer, policy} ->
      if policy.role in [:frontier, :collaborator] and
           (request.frontier == nil or request.frontier == peer),
         do: {peer, policy.room}
    end)
  end

  defp dispatch(%{resource_busy: true} = state), do: state
  defp dispatch(%{active: active} = state) when active != nil, do: state
  defp dispatch(%{blocked_release: lease} = state) when lease != nil, do: state

  defp dispatch(state) do
    # A previous bridge incarnation's running case fences dispatch. Recovery
    # closes it for frontier diagnosis; it is never replayed as a fresh attempt.
    if Store.holds() != [] or Enum.any?(Store.ids(), &(Store.get(&1).state == "running")) do
      state
    else
      id =
        Enum.find(
          Store.ids(),
          &(Store.get(&1).state == "waiting_resource" and authorized?(Store.get(&1), state))
        )

      if id, do: acquire(id, state), else: state
    end
  end

  defp authorized?(request, state) do
    with {:ok, policy} <- Protocol.peer(%{peer: request.peer, room: request.room}, state.peers),
         message <- %{
           "type" => "task",
           "payload" =>
             Map.take(
               request.task,
               ~w(repo request check files design read_rounds reasoning_budget_tokens replay_reply_from)
             )
         },
         {:ok, _} <- Protocol.task(message, policy, request.peer) do
      true
    else
      _ -> false
    end
  end

  defp call(%{transport: {:endpoint, endpoint, peer}}, op, args),
    do: Transport.call(endpoint, op, args, peer)

  defp call(%{transport: fun}, op, args), do: fun.(op, args)

  @doc false
  def no_grant(_lease), do: :blocked

  @doc false
  def no_release(_lease), do: {:error, :no_resource_adapter}

  defp acquire(id, state) do
    {acquire, _} = state.resource
    # Persist intent before an asynchronous grant can outlive this bridge.
    lease = id <> ":" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    :ok = Store.reserve(id, lease)
    job(%{state | resource_busy: true}, {:acquire_resource, id, lease}, fn -> acquire.(lease) end)
  end

  defp release_resource(state, id, lease) do
    {_, release} = state.resource
    job(%{state | resource_busy: true}, {:release_resource, id, lease}, fn -> release.(lease) end)
  end

  # A message that awaits an application receipt stays in the durable outbox
  # until the receipt arrives, but it is transmitted once per run: resending it
  # on every later flush (each anomaly, each closed case) flooded the frontier
  # with its whole backlog (2026-10-23). A restart's restore sends it again once.
  defp transmitted(state), do: Map.get(state, :transmitted, MapSet.new())

  # Everything awaiting a receipt when older code ran was already sent, many
  # times over (see the handle_call/handle_info guards).
  defp seed_transmitted(state) do
    Map.put(
      state,
      :transmitted,
      for(m <- Store.outbox(), m.receipt, into: MapSet.new(), do: m.id)
    )
  end

  defp flush(state, excluded \\ [], only_peer \\ nil) do
    sent = transmitted(state)

    Store.outbox()
    |> Enum.reject(&(&1.id in excluded or (only_peer != nil and &1.peer != only_peer)))
    |> Enum.reject(&(&1.receipt and MapSet.member?(sent, &1.id)))
    |> Enum.group_by(& &1.peer)
    |> Enum.reduce(state, fn {peer, messages}, state ->
      case state.peers[peer] do
        %{room: room} when not is_map_key(state.senders, peer) ->
          messages = Enum.filter(messages, &(&1.room == room))

          if messages == [] do
            state
          else
            state =
              job(state, {:send, peer, Enum.uniq(excluded ++ Enum.map(messages, & &1.id))}, fn ->
                ok =
                  Enum.filter(messages, fn message ->
                    match?(
                      {:ok, _},
                      call(state, "send", %{"room" => room, "text" => message.body})
                    )
                  end)

                %{
                  receipted: Enum.reject(ok, & &1.receipt),
                  transmitted: for(m <- ok, m.receipt, do: m.id)
                }
              end)

            %{state | senders: Map.put(state.senders, peer, true)}
          end

        _ ->
          state
      end
    end)
  end

  defp value(map, key) do
    fields = %{
      "peer" => :peer,
      "room" => :room,
      "events" => :events,
      "cursor" => :cursor,
      "kind" => :kind,
      "body" => :body
    }

    case map do
      %{^key => value} -> value
      _ -> Map.get(map, fields[key])
    end
  end
end
