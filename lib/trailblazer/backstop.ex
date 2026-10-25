defmodule Trailblazer.Backstop do
  @moduledoc """
  The one backstop of an interaction with something outside the VM (design
  §13.2, rule 6), and the only place in Trailblazer allowed a timer.

  `arm/4` is called by the process that waits; it gets `{:backstop, ref, id}`
  if the limit passes before `disarm/1`, where `id` is the anomaly reported for
  it. Firing is not expected: the limit is set generously from measurements,
  so it means something is wrong or the machine is overloaded, and the
  anomaly carries the load to tell which. The guarded work then ends in its
  defined way, decided by the waiting process.

  A backstop and its answer can race (J5): this process decides. `disarm/1`
  answers `:ok` when the backstop had not fired, `:fired` when it had, and the
  caller lets exactly one outcome stand. A waiting process that dies takes its
  backstops with it. Each change is published on `:backstop`.
  """
  use GenServer

  alias Trailblazer.{Anomaly, Events}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Arms a backstop for the calling process. `evidence` is a function called
  if it fires, returning a map of what was seen so far (progress, the request).
  """
  @spec arm(atom(), term(), {:ms, pos_integer()}, (-> map())) :: reference()
  def arm(kind, subject, {:ms, ms}, evidence \\ fn -> %{} end)
      when is_integer(ms) and ms > 0 and is_function(evidence, 0) do
    ref = make_ref()
    :ok = GenServer.call(__MODULE__, {:arm, ref, self(), kind, subject, ms, evidence}, :infinity)
    ref
  end

  @doc "The interaction answered: `:ok`, or `:fired` if the backstop won the race."
  @spec disarm(reference()) :: :ok | :fired
  def disarm(ref), do: GenServer.call(__MODULE__, {:disarm, ref}, :infinity)

  @doc """
  Runs `fun` in a monitored process of its own under one backstop, for an
  interaction that has no answer of its own to wait for besides its reply (an
  HTTP request with no client timeout). Returns `{:ok, value}`,
  `{:error, {:backstop, anomaly_id}}` after killing the process when the
  backstop fires first, or `{:error, {:down, reason}}` when `fun` crashed.
  """
  @spec guard(atom(), term(), {:ms, pos_integer()}, (-> map()), (-> term())) ::
          {:ok, term()} | {:error, {:backstop, term()} | {:down, term()}}
  def guard(kind, subject, limit, evidence, fun) do
    parent = self()

    {pid, mon} =
      spawn_monitor(fn ->
        worker = self()
        # Monitoring alone leaves unlinked external IO alive if its waiter dies.
        # Tie its lifetime to that waiter without linking crashes back into it.
        spawn(fn ->
          owner_ref = Process.monitor(parent)
          worker_ref = Process.monitor(worker)

          receive do
            {:DOWN, ^owner_ref, :process, ^parent, _} -> Process.exit(worker, :kill)
            {:DOWN, ^worker_ref, :process, ^worker, _} -> :ok
          end
        end)

        send(parent, {:guarded, self(), fun.()})
      end)

    ref = arm(kind, subject, limit, evidence)

    receive do
      {:guarded, ^pid, value} ->
        Process.demonitor(mon, [:flush])
        settle(ref, {:ok, value})

      {:DOWN, ^mon, :process, ^pid, reason} ->
        settle(ref, {:error, {:down, reason}})

      {:backstop, ^ref, id} ->
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^mon, :process, ^pid, _} -> :ok)
        receive do: ({:guarded, ^pid, _} -> :ok), after: (0 -> :ok)
        {:error, {:backstop, id}}
    end
  end

  # J5: if the backstop fired in the same moment, its outcome stands.
  defp settle(ref, outcome) do
    case disarm(ref) do
      :ok -> outcome
      :fired -> receive do: ({:backstop, ^ref, id} -> {:error, {:backstop, id}})
    end
  end

  @doc "How many backstops are armed."
  def armed, do: GenServer.call(__MODULE__, :armed, :infinity)

  @impl true
  def init(_opts), do: {:ok, %{armed: %{}, fired: %{}, owners: %{}}}

  @impl true
  def handle_call({:arm, ref, owner, kind, subject, ms, evidence}, _from, s) do
    timer = Process.send_after(self(), {:fire, ref}, ms)
    mon = Map.get_lazy(s.owners, owner, fn -> Process.monitor(owner) end)

    entry = %{
      owner: owner,
      kind: kind,
      subject: subject,
      ms: ms,
      evidence: evidence,
      timer: timer,
      at: System.monotonic_time(:millisecond)
    }

    :ok = Events.publish(:backstop, {:armed, ref, kind, subject, ms})

    {:reply, :ok,
     %{s | armed: Map.put(s.armed, ref, entry), owners: Map.put(s.owners, owner, mon)}}
  end

  def handle_call({:disarm, ref}, _from, s) do
    case Map.pop(s.armed, ref) do
      {nil, _} ->
        case Map.pop(s.fired, ref) do
          {nil, _} -> {:reply, :ok, s}
          {owner, fired} -> {:reply, :fired, forget_owner(%{s | fired: fired}, owner)}
        end

      {entry, armed} ->
        Process.cancel_timer(entry.timer)
        :ok = Events.publish(:backstop, {:disarmed, ref})
        {:reply, :ok, forget_owner(%{s | armed: armed}, entry.owner)}
    end
  end

  def handle_call(:armed, _from, s), do: {:reply, map_size(s.armed), s}

  @impl true
  def handle_info({:fire, ref}, s) do
    case Map.pop(s.armed, ref) do
      {nil, _} ->
        {:noreply, s}

      {entry, armed} ->
        evidence =
          try do
            entry.evidence.()
          rescue
            e -> %{evidence_failed: Exception.message(e)}
          end

        evidence =
          Map.merge(evidence, %{
            limit_ms: entry.ms,
            waited_ms: System.monotonic_time(:millisecond) - entry.at
          })

        # reporting reads the load and writes cases.db: off this process, so
        # other backstops keep their own time
        owner = entry.owner

        {:ok, _} =
          Task.start(fn ->
            # the waiting process is told even if recording fails (nil id),
            # or it would wait for this message forever
            id =
              try do
                {:ok, id} = Anomaly.report(entry.kind, entry.subject, evidence)
                id
              rescue
                _ -> nil
              catch
                _, _ -> nil
              end

            send(owner, {:backstop, ref, id})
          end)

        :ok = Events.publish(:backstop, {:fired, ref, entry.kind, entry.subject})

        {:noreply, %{s | armed: armed, fired: Map.put(s.fired, ref, entry.owner)}}
    end
  end

  def handle_info({:DOWN, _mon, :process, owner, _reason}, s) do
    {mine, rest} = Enum.split_with(s.armed, fn {_ref, e} -> e.owner == owner end)

    for {ref, e} <- mine do
      Process.cancel_timer(e.timer)
      :ok = Events.publish(:backstop, {:cancelled, ref, :owner_down})
    end

    fired = Map.reject(s.fired, fn {_ref, o} -> o == owner end)
    {:noreply, %{s | armed: Map.new(rest), owners: Map.delete(s.owners, owner), fired: fired}}
  end

  # an owner with nothing armed and no fired backstop left to disarm is no
  # longer monitored; while it has either, its :DOWN cleans them up
  defp forget_owner(s, owner) do
    if Enum.any?(s.armed, fn {_, e} -> e.owner == owner end) or
         Enum.any?(s.fired, fn {_, o} -> o == owner end) do
      s
    else
      case Map.pop(s.owners, owner) do
        {nil, _} ->
          s

        {mon, owners} ->
          Process.demonitor(mon, [:flush])
          %{s | owners: owners}
      end
    end
  end
end
