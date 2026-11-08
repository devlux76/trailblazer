defmodule Trailblazer.Loop.Coordinator.Cleanup do
  @moduledoc "Removal of a case checkout and branch once its evidence is archived and verified; discard for retirement."

  alias Trailblazer.Loop.Coordinator.Archive
  alias Trailblazer.Loop.Coordinator.Git
  alias Trailblazer.Loop.Lifecycle

  @doc false
  def cleanup(id, r) do
    with {:ok, r} <- ensure_removal(id, r),
         {:ok, r} <- Archive.current_archive(id, r),
         :ok <- remove_checkout(r),
         :ok <- delete_branch(r, r["candidate"]),
         {:ok, %{"stage" => "cleanup_complete"} = r} <- Lifecycle.reconcile(id) do
      {:ok, r}
    else
      {:ok, _} -> {:error, :cleanup_not_observed}
      error -> error
    end
  end

  defp ensure_removal(_id, %{"stage" => "removal_pending"} = r), do: {:ok, r}

  defp ensure_removal(id, r) do
    with {:ok, archive} <- Archive.archive(id, r), do: Lifecycle.prepare_removal(id, archive)
  end

  @doc false
  def discard(id, r) do
    with {:ok, r} <- Archive.current_archive(id, r),
         :ok <- remove_checkout(r),
         :ok <- delete_branch(r, r["archive"]["branch_sha"]),
         {:ok, %{"stage" => "discarded"} = r} <- Lifecycle.reconcile(id) do
      {:ok, r}
    else
      {:ok, _} -> {:error, :cleanup_not_observed}
      error -> error
    end
  end

  # Nothing is removed unless the verified archive is still intact, also when
  # an interrupted cleanup resumes: it holds everything the checkout had
  # beyond its base (ignored and provisioned dependency/build trees aside).
  defp remove_checkout(r) do
    with true <- Lifecycle.archive_intact?(r["archive"]),
         {:ok, registered} <- Archive.registration(r) do
      cond do
        registered ->
          case Git.git(r["repo"], [
                 "--git-dir",
                 r["common"],
                 "worktree",
                 "remove",
                 "--force",
                 "--",
                 r["path"]
               ]) do
            {:ok, _} -> :ok
            error -> error
          end

        File.lstat(r["path"]) == {:error, :enoent} ->
          :ok

        true ->
          {:error, :unregistered_path_exists}
      end
    else
      false -> {:error, :archive_missing}
      error -> error
    end
  end

  defp delete_branch(r, expected) do
    ref = "refs/heads/" <> r["branch"]

    case Git.cmd(r["repo"], ["show-ref", "--verify", "--quiet", ref]) do
      {_, 1} ->
        :ok

      {_, 0} when is_binary(expected) ->
        case Git.git(r["repo"], ["update-ref", "-d", ref, expected]) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :branch_moved}
        end

      {_, 0} ->
        {:error, :branch_moved}

      {out, code} ->
        {:error, {:branch_observation_failed, code, out}}
    end
  end
end
