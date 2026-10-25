defmodule Trailblazer.EmbedHealth do
  @moduledoc """
  Whether the embedder and the vector store answer, as events (design §13.4,
  J12). A consumer whose embedding failed says so with `down/2` and waits for
  `%{state: :up}` on the `:embedder` topic; it holds no timer of its own.

  Demand drives the probing: while at least one live consumer waits, this
  process alone probes again after a gap that doubles up to
  `embed_retry_cap_ms`. The router announces nothing when a model becomes
  ready, so this retry is the one timer here (allowlisted in
  `no_clocks_test.exs`, like the model's loading retry). Nobody waiting, no
  probing. One backstop (`backstop_embed_ms`) turns a long outage with work
  pending into an anomaly; it never schedules a probe.

  Nothing is held for nobody: when the last consumer waiting goes away, the
  retry timer, the probe in flight with its own backstop, and the outage
  backstop all go with it. The state stays `:down` — the last consumer reported
  that and no probe has said otherwise. Demand that arrives after that arms a
  new outage backstop and probes again: one is held per period of pending
  demand, and one that fired is not armed again while the same consumers keep
  waiting.

  Each change of state is published once: up and down repeatedly is one event
  per change. A consumer's `ok/0` after a successful batch resets the gap, so
  an embedder that answers the probe but fails real work backs off instead of
  churning.
  """
  use GenServer
  require Logger
  alias Trailblazer.{Backstop, Config, Events}

  @first_gap 1_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "The caller's embedding failed; it waits for `%{state: :up}` on `:embedder`."
  def down(reason, who \\ self(), server \\ __MODULE__),
    do: GenServer.cast(server, {:down, reason, who})

  @doc "A batch went through: the next outage starts again from the first gap."
  def ok(server \\ __MODULE__), do: GenServer.cast(server, :ok)

  def state(server \\ __MODULE__), do: GenServer.call(server, :state, :infinity)

  @impl true
  def init(opts) do
    {:ok,
     %{
       state: :up,
       reason: nil,
       waiting: %{},
       probe: Keyword.get(opts, :probe, &probe/0),
       probing: nil,
       timer: nil,
       gap: @first_gap,
       backstop: nil
     }}
  end

  @impl true
  def handle_call(:state, _, s),
    do: {:reply, if(s.state == :up, do: :up, else: {:down, s.reason}), s}

  @impl true
  def handle_cast({:down, reason, who}, s) do
    # A period of pending demand begins when nobody was waiting, not when a
    # consumer is new: one that joins an outage already pending has not started
    # a period, so it must not rearm an outage guard that already fired.
    began? = map_size(s.waiting) == 0
    waiting = Map.put_new_lazy(s.waiting, who, fn -> Process.monitor(who) end)

    s = %{s | waiting: waiting}

    s =
      if s.state == :up do
        Logger.warning("trailblazer: embedder down: #{inspect(reason)}")
        Events.publish(:embedder, %{state: :down, reason: inspect(reason)})
        %{s | state: :down, reason: reason}
      else
        s
      end

    {:noreply, s |> arm_outage(began?, reason) |> schedule()}
  end

  def handle_cast(:ok, s), do: {:noreply, %{s | gap: @first_gap}}

  @impl true
  # The retry message is untagged and `Process.cancel_timer/1` does not retract
  # one already in this mailbox, so it is not always an answer to a question
  # that is still open. Demand decides, not the message (design §13.2): nobody
  # waiting means no probe, and one probe out is one probe — a second would
  # orphan the first and leave its backstop armed for work nobody wants.
  def handle_info(:probe, %{state: :up} = s), do: {:noreply, s}
  def handle_info(:probe, %{waiting: waiting} = s) when map_size(waiting) == 0, do: {:noreply, s}
  def handle_info(:probe, %{probing: probing} = s) when not is_nil(probing), do: {:noreply, s}

  def handle_info(:probe, s) do
    parent = self()
    probe = s.probe
    {pid, ref} = spawn_monitor(fn -> send(parent, {:probed, self(), probe.()}) end)

    # One backstop per probe (design §13.2), armed here rather than through
    # `Backstop.guard/5`: the probe already runs in a monitored process of its
    # own, and a second hop would let `{:probed, ...}` trail the caller's view.
    backstop = Backstop.arm(:embed_probe, :embedder, {:ms, Config.get(:backstop_embed_probe_ms)})
    {:noreply, %{s | timer: nil, probing: {pid, ref, backstop}}}
  end

  def handle_info({:probed, pid, result}, %{probing: {pid, ref, backstop}} = s) do
    Process.demonitor(ref, [:flush])
    s = %{s | probing: nil}

    # J5: if the backstop fired in the same moment, its outcome stands.
    result = if Backstop.disarm(backstop) == :fired, do: {:error, :timeout}, else: result

    case result do
      :ok -> {:noreply, recovered(s)}
      {:error, reason} -> {:noreply, schedule(%{s | reason: reason, gap: next_gap(s.gap)})}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{probing: {pid, ref, backstop}} = s) do
    Backstop.disarm(backstop)

    {:noreply, schedule(%{s | probing: nil, reason: {:probe_down, reason}, gap: next_gap(s.gap)})}
  end

  # The probe's backstop fired: the probe is given up on and killed.
  def handle_info({:backstop, backstop, _id}, %{probing: {pid, ref, backstop}} = s) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    {:noreply, schedule(%{s | probing: nil, reason: :timeout, gap: next_gap(s.gap)})}
  end

  # Nobody waits: this process holds nothing for anyone (design §13.2). The
  # retry timer, the probe in flight with its own backstop and the outage
  # backstop all go with the last consumer. The state stays :down — what that
  # consumer reported is what is known, and no probe has said otherwise.
  def handle_info({:DOWN, _ref, :process, who, _}, s) do
    waiting = Map.delete(s.waiting, who)

    if map_size(waiting) == 0,
      do: {:noreply, s |> Map.put(:waiting, waiting) |> idle()},
      else: {:noreply, %{s | waiting: waiting}}
  end

  # The backstop recorded the anomaly; probing goes on as before.
  def handle_info({:backstop, ref, _id}, %{backstop: ref} = s),
    do: {:noreply, %{s | backstop: nil}}

  def handle_info(_, s), do: {:noreply, s}

  defp recovered(s) do
    s = if s.timer, do: %{s | timer: cancel(s.timer)}, else: s
    s = disarm_outage(s)
    for {_, ref} <- s.waiting, do: Process.demonitor(ref, [:flush])
    Logger.info("trailblazer: embedder up")
    Events.publish(:embedder, %{state: :up})
    %{s | state: :up, reason: nil, waiting: %{}, timer: nil, backstop: nil}
  end

  # One outage guard per period of pending demand (design §13.2). A period
  # begins when the last consumer leaves and the next one arrives, so a guard
  # that fired while consumers kept waiting is not armed again underneath them,
  # and demand that arrives while one is held does not stack a second.
  defp arm_outage(s, false, _reason), do: s

  defp arm_outage(s, true, reason) do
    if s.backstop do
      s
    else
      waiting = map_size(s.waiting)

      guard =
        Backstop.arm(:embedder_down, :embedder, {:ms, Config.get(:backstop_embed_ms)}, fn ->
          %{reason: inspect(reason), waiting: waiting}
        end)

      %{s | backstop: guard}
    end
  end

  defp disarm_outage(%{backstop: nil} = s), do: s

  defp disarm_outage(s) do
    Backstop.disarm(s.backstop)
    %{s | backstop: nil}
  end

  # Nobody is waiting: the timer, the probe in flight and both guards go with
  # them. The probe is killed rather than left to answer a question that was
  # cancelled, and its guard is disarmed before the kill, so no anomaly is
  # recorded for work nobody wants.
  defp idle(s) do
    s = if s.timer, do: %{s | timer: cancel(s.timer)}, else: s

    case s.probing do
      {pid, ref, guard} ->
        Process.demonitor(ref, [:flush])
        Backstop.disarm(guard)
        Process.exit(pid, :kill)
        %{s | probing: nil}

      nil ->
        s
    end
    |> disarm_outage()
  end

  # One probe or one timer at a time, and only while someone waits.
  defp schedule(%{state: :up} = s), do: s
  defp schedule(%{probing: p} = s) when not is_nil(p), do: s
  defp schedule(%{timer: t} = s) when not is_nil(t), do: s
  defp schedule(s) when map_size(s.waiting) == 0, do: s
  defp schedule(s), do: %{s | timer: Process.send_after(self(), :probe, s.gap)}

  defp next_gap(gap), do: min(gap * 2, Config.get(:embed_retry_cap_ms))

  defp cancel(timer) do
    Process.cancel_timer(timer)
    nil
  end

  # The embedder embeds one word and Qdrant says it is healthy.
  defp probe do
    case Config.get(:embed_probe) do
      :down ->
        {:error, :probe_disabled}

      _ ->
        with {:ok, _} <- Trailblazer.Embed.query("health"),
             {:ok, %Req.Response{status: 200}} <-
               Req.get(Config.get(:qdrant_url) <> "/healthz", retry: false) do
          :ok
        else
          {:ok, %Req.Response{status: status}} -> {:error, {:qdrant, status}}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
