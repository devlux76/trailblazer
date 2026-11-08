defmodule Trailblazer.Loop.Coordinator do
  @moduledoc """
  The coordinator owns a case's integration and cleanup (design review,
  "Lifecycle: the coordinator owns integration"; Task 2).

  `preflight/1` is the read-only acceptance check. `accept/2` integrates a
  checked candidate into the primary branch admitted with the case, then
  archives its evidence and removes its managed checkout and branch.
  `retire/2` archives and removes a case that will not be integrated. All of
  it is serialized per repository (canonical Git common directory), every
  precondition is rechecked inside that lock, and every Git effect follows its
  journal intent in `Trailblazer.Loop.Lifecycle`.
  """
  alias Trailblazer.Loop.Coordinator.Archive
  alias Trailblazer.Loop.Coordinator.Cleanup
  alias Trailblazer.Loop.Coordinator.Integration
  alias Trailblazer.Loop.Coordinator.Locks
  alias Trailblazer.Loop.Coordinator.Preflight
  alias Trailblazer.Loop.Lifecycle

  @doc "Read-only acceptance preflight for the case identified by `id`: no Git effects."
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
            Locks.with_lock(common, fn -> Preflight.preflight_record(id, record) end)
        end
    end
  end

  ## Integration and cleanup (Task 2)

  @doc """
  Integrates the case's checked candidate into its admitted primary branch,
  then archives its evidence and removes its managed checkout and branch.

  Every Git effect follows its journal intent; an interrupted call resumes from
  the journal. A blocked integration (dirty primary, conflict, failed test of
  the merge result, moved primary under the CAS) leaves the candidate branch
  and evidence intact, records the reason and can be called again.
  """
  @spec accept(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def accept(id, opts \\ []) when is_list(opts) do
    coordinated(id, fn record -> accept_record(id, record, opts) end)
  end

  @doc """
  Retires a case that will not be integrated (failed, unverified or refused):
  archives its journal and changes outside Git, verifies the archive, then
  removes its managed checkout and branch.
  """
  @spec retire(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def retire(id, opts \\ []) when is_list(opts) do
    coordinated(id, fn record -> retire_record(id, record) end)
  end

  defp coordinated(id, fun) do
    case Lifecycle.get(id) do
      nil ->
        {:error, :no_lifecycle}

      %{"common" => common, "repo" => repo} when is_binary(common) and is_binary(repo) ->
        result =
          Locks.with_lock(common, fn ->
            with {:ok, record} <- recover(id), do: fun.(record)
          end)

        case result do
          {:error, reason} = error ->
            _ = Lifecycle.failed(id, reason)
            error

          ok ->
            ok
        end

      _ ->
        {:error, :ownership_changed}
    end
  end

  # Observe interrupted effects first. A CAS that lost to a moved primary is
  # reopened so the integration is recomputed and retested.
  defp recover(id) do
    case Lifecycle.reconcile(id) do
      {:ok, record} when is_map(record) ->
        {:ok, record}

      {:error, :primary_moved} ->
        with {:ok, _} <- Lifecycle.reopen_integration(id), do: {:ok, Lifecycle.get(id)}

      {:ok, nil} ->
        {:error, :no_lifecycle}

      error ->
        error
    end
  end

  defp accept_record(id, r, opts) do
    case r["stage"] do
      "candidate_ready" ->
        with {:ok, pre} <- Preflight.preflight_record(id, r),
             {:ok, r} <- Integration.integrate(id, r, pre, opts),
             do: Cleanup.cleanup(id, r)

      "integration_pending" ->
        with {:ok, r} <- Integration.advance(id, r), do: Cleanup.cleanup(id, r)

      stage when stage in ~w(integrated removal_pending) ->
        Cleanup.cleanup(id, r)

      "cleanup_complete" ->
        {:ok, r}

      stage ->
        {:error, {:not_acceptable, stage}}
    end
  end

  defp retire_record(id, r) do
    case r["stage"] do
      "discarded" ->
        {:ok, r}

      stage when stage in ~w(integration_pending integrated removal_pending cleanup_complete) ->
        {:error, {:not_retirable, stage}}

      "discard_pending" ->
        Cleanup.discard(id, r)

      _ ->
        with {:ok, archive} <- Archive.archive(id, r),
             {:ok, r} <- Lifecycle.prepare_discard(id, archive),
             do: Cleanup.discard(id, r)
    end
  end

  @doc delegate_to: {Trailblazer.Loop.Coordinator.Locks, :acquire_lock, 1}
  defdelegate acquire_lock(common), to: Trailblazer.Loop.Coordinator.Locks

  @doc delegate_to: {Trailblazer.Loop.Coordinator.Locks, :release_lock, 1}
  defdelegate release_lock(common), to: Trailblazer.Loop.Coordinator.Locks

  @doc delegate_to: {Trailblazer.Loop.Coordinator.Locks, :with_lock, 2}
  defdelegate with_lock(common, fun), to: Trailblazer.Loop.Coordinator.Locks
end
