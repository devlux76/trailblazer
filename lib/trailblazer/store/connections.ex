defmodule Trailblazer.Store.Connections do
  @moduledoc """
  Demand queue for graph I/O: one writer and two read-only WAL workers.
  Callers wait with monitors; only free workers receive a batch. Each active
  transaction has one backstop, not a queue or statement timeout. A worker is
  replaced after cancellation, so a connection is never reused while its old
  owner may still be rolling back. Commit precedes acknowledgement (J13).
  """
  use GenServer
  require Logger
  alias Trailblazer.{Anomaly, Backstop, Config, Events}
  alias Trailblazer.Store.Connection

  def start_link(opts) do
    with {:ok, pid} <-
           GenServer.start_link(__MODULE__, opts, name: opts[:name], timeout: :infinity) do
      :ok = GenServer.call(pid, :ready, :infinity)
      {:ok, pid}
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    s = %{
      db: opts[:db],
      setup: opts[:setup],
      workers: %{},
      active: %{},
      idle: %{read: [], write: []},
      queue: %{read: :queue.new(), write: :queue.new()},
      waiters: [],
      readers_started: false,
      ready: false
    }

    {:ok, start_worker(s, :write)}
  end

  @impl true
  def handle_call(:ready, _, %{ready: true} = s), do: {:reply, :ok, s}
  def handle_call(:ready, from, s), do: {:noreply, %{s | waiters: [from | s.waiters]}}

  def handle_call({:run, mode, fun}, from, s), do: enqueue(mode, fun, from, s)

  defp enqueue(mode, fun, from, s) do
    job = %{
      from: from,
      fun: fun,
      monitor: Process.monitor(elem(from, 0)),
      ref: make_ref()
    }

    queue = Map.update!(s.queue, mode, &:queue.in(job, &1))
    {:noreply, dispatch(%{s | queue: queue}, mode)}
  end

  @impl true
  def handle_info({:connection_ready, pid, pool, driver, raw, guardian}, s) do
    worker = Map.fetch!(s.workers, pid)

    case Backstop.disarm(worker.backstop) do
      :ok ->
        worker = %{
          worker
          | ready: true,
            backstop: nil,
            raw: raw,
            guardian: guardian,
            monitors:
              worker.monitors
              |> Map.put(pool, Process.monitor(pool))
              |> Map.put(driver, Process.monitor(driver))
              |> Map.put(guardian, Process.monitor(guardian))
        }

        s = %{
          s
          | workers: Map.put(s.workers, pid, worker),
            idle: Map.update!(s.idle, worker.mode, &(&1 ++ [pid]))
        }

        s =
          if worker.mode == :write and not s.readers_started do
            s |> Map.put(:readers_started, true) |> start_worker(:read) |> start_worker(:read)
          else
            s
          end

        s =
          if not s.ready and map_size(s.workers) == 3 and
               Enum.all?(s.workers, fn {_, w} -> w.ready end) do
            for from <- s.waiters, do: GenServer.reply(from, :ok)
            Events.publish(:store, {:ready, self()})
            %{s | ready: true, waiters: []}
          else
            s
          end

        {:noreply, dispatch(s, worker.mode)}

      :fired ->
        id = fired_id(worker.backstop)
        {:stop, {:connection_backstop, id}, s}
    end
  end

  def handle_info({:store_result, pid, ref, result}, s) do
    case s.active[pid] do
      %{ref: ^ref} = job ->
        case Backstop.disarm(job.backstop) do
          :ok ->
            reply(job, result)

            s = %{
              s
              | active: Map.delete(s.active, pid),
                idle: Map.update!(s.idle, s.workers[pid].mode, &(&1 ++ [pid]))
            }

            {:noreply, dispatch(s, s.workers[pid].mode)}

          :fired ->
            id = fired_id(job.backstop)
            Events.publish(:store, {:late_result, id, s.workers[pid].mode})
            {:noreply, cancel(s, pid, job, {:store_backstop, id})}
        end

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:backstop, ref, id}, s) do
    case Enum.find(s.active, fn {_, j} -> j.backstop == ref end) do
      {pid, job} ->
        Backstop.disarm(ref)
        {:noreply, cancel(s, pid, job, {:store_backstop, id})}

      nil ->
        if Enum.any?(s.workers, fn {_, w} -> w.backstop == ref end),
          do: {:stop, {:connection_backstop, id}, s},
          else: {:noreply, s}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, s) do
    case Enum.find(s.workers, fn {_, w} -> w.monitors[pid] == ref end) do
      {worker_pid, worker} ->
        if worker.backstop, do: Backstop.disarm(worker.backstop)
        monitors = Map.delete(worker.monitors, pid)

        if worker.retiring and (pid != worker.guardian or reason == :normal) do
          s = %{s | workers: Map.put(s.workers, worker_pid, %{worker | monitors: monitors})}

          if map_size(monitors) == 0 do
            s = %{s | workers: Map.delete(s.workers, worker_pid)}
            {:noreply, start_worker(s, worker.mode)}
          else
            {:noreply, s}
          end
        else
          if job = s.active[worker_pid] do
            result =
              case Backstop.disarm(job.backstop) do
                :ok -> failure({:connection_down, reason})
                :fired -> failure({:store_backstop, fired_id(job.backstop)})
              end

            reply(job, result)
          end

          Logger.error("trailblazer: store #{worker.mode} connection stopped: #{inspect(reason)}")
          Anomaly.report(:store_connection, {s.db, worker.mode}, %{reason: inspect(reason)})
          {:stop, {:connection_down, worker.mode, reason}, s}
        end

      nil ->
        case Enum.find(s.active, fn {_, j} -> j.monitor == ref end) do
          {worker, job} ->
            Backstop.disarm(job.backstop)
            {:noreply, retire(%{s | active: Map.delete(s.active, worker)}, worker)}

          nil ->
            queue =
              Map.new(s.queue, fn {mode, q} -> {mode, :queue.filter(&(&1.monitor != ref), q)} end)

            {:noreply, %{s | queue: queue}}
        end
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s) do
    idle = s.idle.read ++ s.idle.write

    for {pid, _} <- s.workers do
      if pid in idle and Process.alive?(pid),
        do: GenServer.stop(pid, :normal, :infinity),
        else: retire(s, pid)
    end

    :ok
  end

  defp start_worker(s, mode) do
    setup = if mode == :write, do: s.setup, else: fn _ -> :ok end
    {:ok, pid} = Connection.start_link(self(), s.db, mode, setup)

    backstop =
      Backstop.arm(:store_connection, {s.db, mode}, {:ms, Config.get(:backstop_store_ms)}, fn ->
        %{phase: :opening}
      end)

    worker = %{
      mode: mode,
      monitors: %{pid => Process.monitor(pid)},
      raw: nil,
      guardian: nil,
      backstop: backstop,
      ready: false,
      retiring: false
    }

    %{s | workers: Map.put(s.workers, pid, worker)}
  end

  defp dispatch(s, mode) do
    case {s.idle[mode], :queue.out(s.queue[mode])} do
      {[pid | rest], {{:value, job}, queue}} ->
        s = %{s | idle: Map.put(s.idle, mode, rest), queue: Map.put(s.queue, mode, queue)}

        if Process.alive?(elem(job.from, 0)) do
          ref =
            Backstop.arm(:store_io, {s.db, mode}, {:ms, Config.get(:backstop_store_ms)}, fn ->
              %{phase: :transaction, caller: inspect(elem(job.from, 0))}
            end)

          job = Map.put(job, :backstop, ref)
          GenServer.cast(pid, {:run, job.ref, job.fun})
          dispatch(%{s | active: Map.put(s.active, pid, job)}, mode)
        else
          Process.demonitor(job.monitor, [:flush])
          dispatch(%{s | idle: Map.update!(s.idle, mode, &(&1 ++ [pid]))}, mode)
        end

      _ ->
        s
    end
  end

  defp cancel(s, pid, job, reason) do
    reply(job, failure(reason))
    retire(%{s | active: Map.delete(s.active, pid)}, pid)
  end

  defp retire(s, pid) do
    # cancel wakes both SQLite execution and its busy handler before teardown.
    if raw = s.workers[pid].raw, do: Exqlite.Sqlite3.cancel(raw)
    Process.exit(pid, :kill)
    %{s | workers: Map.update!(s.workers, pid, &%{&1 | retiring: true})}
  end

  defp reply(job, result) do
    Process.demonitor(job.monitor, [:flush])

    GenServer.reply(job.from, result)
  end

  defp failure(reason),
    do: {:raised, :error, RuntimeError.exception("store failed: #{inspect(reason)}"), []}

  # Backstop guarantees this message even if anomaly persistence failed (nil id).
  defp fired_id(ref) do
    receive do: ({:backstop, ^ref, id} -> id)
  end
end
