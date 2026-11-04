defmodule Trailblazer.EmbedGate do
  @moduledoc """
  One embedding batch at a time, newest active repository first. Equal mtimes
  favor the earlier watch. An indexer keeps its place between batches until it
  reports no runnable work; a running batch is never interrupted. Both indexers
  and jobs are monitored so dead owners and holders cannot strand the queue.

  `hold/1` takes the gate for something that must not share the CPU with
  embedding (the code model, design §7.2): it waits for the running batch to
  finish, goes ahead of every indexer, and keeps the gate until `release/1`
  or until the holder exits.
  """
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, if(name, do: [name: name], else: []))
  end

  # Called by the indexer, not its spawned batch job.
  def update(priority, pending?, server \\ __MODULE__),
    do: GenServer.call(server, {:update, priority, pending?}, :infinity)

  def acquire(owner, server \\ __MODULE__),
    do: GenServer.call(server, {:acquire, owner}, :infinity)

  def hold(server \\ __MODULE__, timeout \\ :infinity) do
    try do
      GenServer.call(server, :hold, timeout)
    catch
      :exit, {:timeout, _} ->
        # The request may have been granted as the call timed out. Cancel both
        # a queued and an already-granted hold before the live owner retries.
        GenServer.call(server, :cancel_hold, :infinity)
        {:error, :timeout}
    end
  end

  def release(server \\ __MODULE__), do: GenServer.call(server, :release, :infinity)
  def queued?(job, server \\ __MODULE__), do: GenServer.call(server, {:queued?, job}, :infinity)

  @impl true
  def init(_), do: {:ok, %{repos: %{}, waiters: %{}, holds: [], holder: nil, next: 0}}

  @impl true
  def handle_call({:update, priority, pending?}, {owner, _}, s) do
    repo =
      Map.get_lazy(s.repos, owner, fn ->
        %{priority: priority, pending: pending?, order: s.next, ref: Process.monitor(owner)}
      end)

    pending? = if pending? == :keep, do: repo.pending, else: pending?
    repo = %{repo | priority: priority, pending: pending?}
    s = %{s | repos: Map.put(s.repos, owner, repo), next: s.next + 1}
    {:reply, :ok, grant(s)}
  end

  def handle_call({:acquire, owner}, {job, _} = from, s) do
    if Map.has_key?(s.repos, owner) do
      waiter = %{owner: owner, from: from, ref: Process.monitor(job)}
      {:noreply, grant(%{s | waiters: Map.put(s.waiters, job, waiter)})}
    else
      {:reply, {:error, :owner_down}, s}
    end
  end

  def handle_call(:hold, {job, _} = from, s) do
    hold = %{job: job, from: from, ref: Process.monitor(job)}
    {:noreply, grant(%{s | holds: s.holds ++ [hold]})}
  end

  def handle_call(:cancel_hold, {job, _}, s) do
    {mine, holds} = Enum.split_with(s.holds, &(&1.job == job))
    for hold <- mine, do: Process.demonitor(hold.ref, [:flush])

    s =
      case s.holder do
        {^job, ref} ->
          Process.demonitor(ref, [:flush])
          %{s | holder: nil}

        _ ->
          s
      end

    {:reply, :ok, grant(%{s | holds: holds})}
  end

  def handle_call(:release, {job, _}, %{holder: {job, ref}} = s) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, grant(%{s | holder: nil})}
  end

  def handle_call(:release, _, s), do: {:reply, {:error, :not_holder}, s}
  def handle_call({:queued?, job}, _, s), do: {:reply, Map.has_key?(s.waiters, job), s}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, s) do
    s =
      case s.repos[pid] do
        %{ref: ^ref} ->
          {removed, kept} = Enum.split_with(s.waiters, fn {_, w} -> w.owner == pid end)

          for {_, w} <- removed do
            Process.demonitor(w.ref, [:flush])
            GenServer.reply(w.from, {:error, :owner_down})
          end

          %{s | repos: Map.delete(s.repos, pid), waiters: Map.new(kept)}

        _ ->
          s
      end

    s = if s.holder == {pid, ref}, do: %{s | holder: nil}, else: s
    holds = Enum.reject(s.holds, &(&1.ref == ref))
    {:noreply, grant(%{s | waiters: Map.delete(s.waiters, pid), holds: holds})}
  end

  defp grant(%{holder: holder} = s) when not is_nil(holder), do: s

  defp grant(%{holds: [hold | rest]} = s) do
    GenServer.reply(hold.from, :ok)
    %{s | holder: {hold.job, hold.ref}, holds: rest}
  end

  defp grant(s) do
    # Include runnable repos even during the gap between a batch release and
    # its indexer's next job. Otherwise older waiters would slip in each time.
    candidates =
      Enum.filter(s.repos, fn {owner, repo} ->
        repo.pending or Enum.any?(s.waiters, fn {_, w} -> w.owner == owner end)
      end)

    case Enum.min_by(candidates, fn {_, r} -> {-r.priority, r.order} end, fn -> nil end) do
      nil ->
        s

      {owner, _} ->
        case Enum.find(s.waiters, fn {_, w} -> w.owner == owner end) do
          nil ->
            s

          {job, w} ->
            GenServer.reply(w.from, :ok)
            %{s | holder: {job, w.ref}, waiters: Map.delete(s.waiters, job)}
        end
    end
  end
end
