defmodule Trailblazer.Loop.Coordinator do
  @moduledoc """
  Locally authorized acceptance preflight for a checked candidate (Task 2,
  sub-brief 1). It serializes the whole acceptance operation by the
  repository's canonical Git common directory and rechecks every precondition
  inside that lock. It performs no Git effects: no refs, checkouts, indexes,
  candidate branches or files are modified.
  """

  alias Trailblazer.{Files, Loop.Lifecycle}

  @table :trailblazer_coordinator_locks

  @doc "Acceptance preflight for the case identified by `id`."
  @spec accept(term()) :: {:ok, map()} | {:error, term()}
  def accept(id), do: accept(id, [])

  @spec accept(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def accept(id, opts) when is_list(opts) do
    preflight(id, opts)
  end

  @doc "Alias for `accept/2`."
  def preflight(id), do: preflight(id, [])

  def preflight(id, _opts) do
    case Lifecycle.get(id) do
      nil ->
        {:error, :no_lifecycle}

      record when is_map(record) ->
        common = record["common"]
        repo = record["repo"]

        cond do
          not is_binary(common) or not is_binary(repo) ->
            {:error, :ownership_changed}

          true ->
            with_lock(common, fn -> preflight_record(id, record) end)
        end
    end
  end

  ## Preflight

  defp preflight_record(id, record) do
    repo = record["repo"]
    common = record["common"]

    with :ok <- validate_repository(repo, common),
         primary = record["primary"],
         :ok <- validate_primary(primary),
         {:ok, primary_sha} <- primary_sha(repo, primary),
         candidate = record["candidate"],
         :ok <- validate_candidate(candidate, record["stage"]),
         branch = record["branch"],
         :ok <- validate_branch(repo, branch, candidate),
         base = record["base"],
         :ok <- validate_base(repo, base),
         checkouts <- primary_checkouts(repo, primary),
         :ok <- check_primary_checkouts(checkouts, record["files"] || []) do
      {:ok,
       %{
         "case" => id,
         "repo" => repo,
         "common" => common,
         "primary" => primary,
         "primary_sha" => primary_sha,
         "candidate" => candidate,
         "branch" => branch,
         "base" => base,
         "files" => record["files"],
         "primary_checkouts" => checkouts,
         "stage" => record["stage"]
       }}
    end
  end

  defp validate_repository(repo, common) do
    with {:ok, ^repo} <- Files.canonical_path(repo),
         {:ok, ^common} <- git(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      :ok
    else
      _ -> {:error, :ownership_changed}
    end
  end

  defp validate_primary(nil), do: {:error, :no_primary}

  defp validate_primary(primary) when is_binary(primary) do
    if valid_primary?(primary) do
      :ok
    else
      {:error, :invalid_primary}
    end
  end

  defp validate_primary(_), do: {:error, :no_primary}

  defp valid_primary?(name) do
    match?(
      {_, 0},
      System.cmd("git", ["check-ref-format", "refs/heads/" <> name], stderr_to_stdout: true)
    )
  end

  defp primary_sha(repo, primary) do
    case git(repo, ["rev-parse", "--verify", "refs/heads/" <> primary]) do
      {:ok, sha} -> {:ok, sha}
      _ -> {:error, :missing_primary}
    end
  end

  defp validate_candidate(nil, _stage), do: {:error, :no_candidate}

  defp validate_candidate(_candidate, stage) do
    if stage == "candidate_ready" do
      :ok
    else
      {:error, :not_candidate_ready}
    end
  end

  defp validate_branch(repo, branch, candidate) do
    case git(repo, ["rev-parse", "--verify", "refs/heads/" <> branch]) do
      {:ok, ^candidate} -> :ok
      {:ok, _} -> {:error, :candidate_moved}
      _ -> {:error, :candidate_moved}
    end
  end

  defp validate_base(repo, base) do
    case git(repo, ["rev-parse", "--verify", base <> "^{commit}"]) do
      {:ok, _} -> :ok
      _ -> {:error, :ownership_changed}
    end
  end

  defp primary_checkouts(repo, primary) do
    case git(repo, ["worktree", "list", "--porcelain"]) do
      {:ok, text} ->
        text
        |> String.split("\n\n", trim: true)
        |> Enum.reduce([], fn block, acc ->
          lines = String.split(block, "\n", trim: true)
          path = Enum.find_value(lines, fn "worktree " <> p -> String.trim(p); _ -> nil end)
          branch = Enum.find_value(lines, fn "branch refs/heads/" <> b -> String.trim(b); _ -> nil end)

          if is_binary(path) and branch == primary do
            [path | acc]
          else
            acc
          end
        end)
        |> Enum.reverse()

      _ ->
        []
    end
  end

  defp check_primary_checkouts(paths, files) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case git(path, ["status", "--porcelain"]) do
        {:ok, ""} ->
          {:cont, :ok}

        {:ok, status} ->
          lines = String.split(status, "\n", trim: true)

          if Enum.any?(lines, &(not String.starts_with?(&1, "??"))) do
            {:halt, {:error, :dirty_primary}}
          else
            untracked =
              lines
              |> Enum.filter(&String.starts_with?(&1, "??"))
              |> Enum.map(fn
                "?? " <> p -> String.trim(p)
                other -> String.trim(other)
              end)

            if Enum.any?(untracked, &(&1 in (files || []))) do
              {:halt, {:error, :colliding_untracked}}
            else
              {:cont, :ok}
            end
          end

        {:error, _} ->
          {:halt, {:error, :dirty_primary}}
      end
    end)
  end

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

  defp git(repo, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
           cd: repo,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim_trailing(out, "\n")}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end
end
