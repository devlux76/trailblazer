defmodule Trailblazer.Loop.Coordinator.Archive do
  @moduledoc "The evidence archive: journal and changes written content-addressed and read back before removal."

  alias Trailblazer.Config
  alias Trailblazer.Loop.Coordinator.Git
  alias Trailblazer.Loop.Lifecycle

  @excluded ~w(deps node_modules _build target)

  # Intact is not current: an interrupted cleanup's checkout may have gained
  # changes after its archive. Immediately before removal the checkout's
  # present content and branch are compared with the archived snapshot; a
  # difference is archived anew and journalled before anything goes.
  @doc false
  def current_archive(id, r) do
    with {:ok, branch_sha} <- branch_sha(r),
         {:ok, patch} <- changes(r, branch_sha) do
      archived = r["archive"] || %{}

      cond do
        # a damaged archive means the evidence store itself is suspect: block
        not Lifecycle.archive_intact?(archived) ->
          {:error, :archive_missing}

        branch_sha == archived["branch_sha"] and
            Lifecycle.sha256(patch) == get_in(archived, ["files", "changes.patch"]) ->
          {:ok, r}

        true ->
          with {:ok, archive} <- archive(id, r), do: Lifecycle.refresh_archive(id, archive)
      end
    else
      {:error, reason} -> {:error, {:archive_failed, reason}}
    end
  end

  @doc false
  def registration(r) do
    case Git.git(r["repo"], ["worktree", "list", "--porcelain", "-z"]) do
      {:ok, text} -> {:ok, text |> String.split("\0") |> Enum.member?("worktree " <> r["path"])}
      {:error, reason} -> {:error, {:worktree_discovery_failed, reason}}
    end
  end

  ## Evidence archive

  # Written outside any worktree, atomically, then read back against its
  # SHA-256 before anything is removed (Lifecycle.archive_intact?/1).
  # Each snapshot gets its own content-addressed directory, so replacing a
  # stale archive never disturbs the one the journal still names.
  #
  # The directory is named by the whole payload (journal and patch bytes and
  # the recorded branch SHA), is filled under a private temporary name and
  # appears by one rename, and is never written again: an existing snapshot
  # is either this exact payload (reused) or something else (refused).
  @doc false
  def archive(id, r) do
    with {:ok, branch_sha} <- branch_sha(r),
         {:ok, patch} <- changes(r, branch_sha) do
      journal = Jason.encode!(r, pretty: true)

      files = %{
        "journal.json" => Lifecycle.sha256(journal),
        "changes.patch" => Lifecycle.sha256(patch)
      }

      identity = Lifecycle.sha256(Jason.encode!(%{"branch_sha" => branch_sha, "files" => files}))
      root = Path.join([Config.get(:state_dir), "archive", id])
      dir = Path.join(root, String.slice(identity, 0, 32))
      archive = %{"path" => dir, "branch_sha" => branch_sha, "files" => files}

      cond do
        Lifecycle.archive_intact?(archive) ->
          {:ok, archive}

        File.exists?(dir) ->
          {:error, {:archive_failed, :snapshot_exists_with_other_content}}

        true ->
          tmp = Path.join(root, ".tmp-#{System.unique_integer([:positive])}")

          with :ok <- File.mkdir_p(tmp),
               :ok <- File.write(Path.join(tmp, "journal.json"), journal),
               :ok <- File.write(Path.join(tmp, "changes.patch"), patch),
               :ok <- File.rename(tmp, dir) do
            if Lifecycle.archive_intact?(archive),
              do: {:ok, archive},
              else: {:error, :archive_unverified}
          else
            {:error, reason} ->
              File.rm_rf(tmp)
              {:error, {:archive_failed, reason}}
          end
      end
    else
      {:error, reason} -> {:error, {:archive_failed, reason}}
    end
  end

  defp branch_sha(r) do
    case Git.cmd(r["repo"], ["rev-parse", "--verify", "--quiet", "refs/heads/" <> r["branch"]]) do
      {sha, 0} -> {:ok, String.trim(sha)}
      {_, 1} -> {:ok, nil}
      {out, code} -> {:error, {:branch_observation_failed, code, out}}
    end
  end

  # Everything the case changed relative to its base: committed candidate
  # work plus, while its checkout exists, uncommitted and untracked files
  # (provisioned dependency and build trees excluded), at every stage.
  defp changes(r, branch_sha) do
    base = r["base"]

    with {:ok, registered} <- registration(r) do
      cond do
        registered ->
          excludes = Enum.map(@excluded, &":(exclude,glob)**/#{&1}")

          with {:ok, _} <- Git.git(r["path"], ["add", "-A", "--", "."] ++ excludes),
               do: Git.git_raw(r["path"], ["diff", "--cached", "--binary", base])

        is_binary(branch_sha) ->
          Git.git_raw(r["repo"], ["diff", "--binary", base, branch_sha])

        true ->
          {:ok, ""}
      end
    end
  end
end
