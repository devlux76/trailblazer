defmodule Trailblazer.Loop.Coordinator.Locks do
  @moduledoc "Repository-scoped lock: one manager process per common Git directory, serialized by messages."

  @table :trailblazer_coordinator_locks

  ## Locking

  # A repository-scoped, process-owned lock. Access is serialized by a small
  # manager process per common directory; waiters block on a message, never on
  # a clock (design §13.2).
  def acquire_lock(common) do
    ensure_manager(common)
    manager = get_manager(common)
    send(manager, {:acquire, self()})

    receive do
      :granted -> :ok
    end
  end

  def release_lock(common) do
    case get_manager(common) do
      nil -> :ok
      manager -> send(manager, {:release, self()})
    end

    :ok
  end

  def with_lock(common, fun) when is_function(fun, 0) do
    acquire_lock(common)

    try do
      fun.()
    after
      release_lock(common)
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        parent = self()

        spawn(fn ->
          try do
            :ets.new(@table, [:named_table, :public, :set])
          rescue
            ArgumentError -> :ok
          end

          send(parent, :trailblazer_coordinator_table_ready)

          receive do
            :trailblazer_coordinator_table_stop -> :ok
          end
        end)

        receive do
          :trailblazer_coordinator_table_ready -> :ok
        end

        ensure_table()

      _ ->
        :ok
    end
  end

  defp ensure_manager(common) do
    ensure_table()

    pid = get_manager(common)

    if is_pid(pid) and Process.alive?(pid) do
      :ok
    else
      :ets.delete(@table, common)
      pid = spawn(fn -> manager_loop(nil, []) end)

      case :ets.insert_new(@table, {common, pid}) do
        true -> :ok
        false -> Process.exit(pid, :kill)
      end
    end
  end

  defp get_manager(common) do
    case :ets.lookup(@table, common) do
      [{^common, pid}] when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp manager_loop(owner, waiters) do
    receive do
      {:acquire, pid} ->
        Process.monitor(pid)

        if owner == nil do
          send(pid, :granted)
          manager_loop(pid, waiters)
        else
          manager_loop(owner, waiters ++ [pid])
        end

      {:release, pid} ->
        if owner == pid do
          case waiters do
            [next | rest] ->
              Process.monitor(next)
              send(next, :granted)
              manager_loop(next, rest)

            [] ->
              manager_loop(nil, [])
          end
        else
          manager_loop(owner, waiters)
        end

      {:DOWN, _ref, :process, pid, _reason} ->
        if owner == pid do
          case waiters do
            [next | rest] ->
              Process.monitor(next)
              send(next, :granted)
              manager_loop(next, rest)

            [] ->
              manager_loop(nil, [])
          end
        else
          manager_loop(owner, List.delete(waiters, pid))
        end
    end
  end
end
