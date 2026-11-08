defmodule Trailblazer.Loop.Coordinator.Integration do
  @moduledoc "Integration of a checked candidate: the tested result, the merge commit and the compare-and-swap advance."

  alias Trailblazer.Config
  alias Trailblazer.Loop.Artifacts
  alias Trailblazer.Loop.Check
  alias Trailblazer.Loop.Coordinator.Git
  alias Trailblazer.Loop.Coordinator.Preflight
  alias Trailblazer.Loop.Lifecycle
  alias Trailblazer.Loop.Workspace

  # The tested result: the candidate itself when primary has not moved past
  # its base (its own check is the evidence), otherwise a merge commit of the
  # moved primary and the candidate, tested in a detached checkout.
  @doc false
  def integrate(id, r, pre, opts) do
    old = pre["primary_sha"]
    candidate = r["candidate"]

    with {:ok, command} <- trusted_command(r),
         {:ok, result, evidence} <- tested_result(id, r, old, candidate, command, opts),
         {:ok, r} <- Lifecycle.prepare_integration(id, old, result, evidence) do
      advance(id, r)
    end
  end

  defp trusted_command(r) do
    case r["trusted_check"] || get_in(r, ["check", "command"]) do
      command when is_binary(command) and command != "" -> {:ok, command}
      _ -> {:error, :no_trusted_check}
    end
  end

  defp tested_result(id, r, old, candidate, command, opts) do
    repo = r["repo"]

    if Git.ancestor?(repo, old, candidate) and is_nil(r["artifacts"]) do
      check = r["check"] || %{}

      with "pass" <- check["status"],
           {:ok, tree} <- Git.git(repo, ["rev-parse", candidate <> "^{tree}"]),
           ^tree <- check["tree"] do
        {:ok, candidate,
         %{
           status: :pass,
           sha: candidate,
           tree: tree,
           command: check["command"],
           source: "candidate"
         }}
      else
        _ -> {:error, :candidate_check_mismatch}
      end
    else
      merged =
        if Git.ancestor?(repo, old, candidate),
          do: {:ok, candidate},
          else: merge_commit(r, old, candidate)

      with {:ok, result} <- merged,
           {:ok, evidence} <- verify(id, repo, result, command, r["artifacts"], opts),
           do: {:ok, result, evidence}
    end
  end

  defp merge_commit(r, old, candidate) do
    repo = r["repo"]

    case Git.cmd(repo, ["merge-tree", "--write-tree", "--no-messages", old, candidate]) do
      {out, 0} ->
        tree = out |> String.split("\n") |> hd()

        with {:ok, body} <- Git.git(repo, ["log", "-1", "--format=%B", candidate]),
             message = "Merge #{r["branch"]} into #{r["primary"]}\n\n#{String.trim(body)}\n",
             {:ok, sha} <-
               Git.git(repo, ["commit-tree", tree, "-p", old, "-p", candidate, "-m", message]) do
          {:ok, sha}
        else
          {:error, reason} -> {:error, {:merge_commit_failed, reason}}
        end

      {_, 1} ->
        {:error, :merge_conflict}

      {out, code} ->
        {:error, {:merge_failed, code, String.slice(out, -400, 400)}}
    end
  end

  defp verify(id, repo, result, command, policy, opts) do
    root = Path.join([Config.get(:state_dir), "integration", id])
    check = Keyword.get(opts, :check, Check)

    try do
      with :ok <- File.mkdir_p(Path.dirname(root)),
           :ok <- remove_stale(repo, root),
           {:ok, _} <- Git.git(repo, ["worktree", "add", "--detach", root, result]),
           :ok <- Workspace.provision_checkout(root, repo),
           :ok <- verify_artifacts(root, policy, Keyword.get(opts, :check_opts, [])) do
        outcome = check.run(root, command, Keyword.get(opts, :check_opts, []))

        cond do
          outcome.status != :pass ->
            {:error, {:integration_check_failed, outcome.status, outcome[:exit]}}

          Git.git(root, ["status", "--porcelain", "--untracked-files=no"]) != {:ok, ""} ->
            {:error, :integration_check_changed_tracked_files}

          true ->
            {:ok,
             %{
               status: :pass,
               sha: result,
               command: command,
               exit: outcome[:exit],
               output_tail: String.slice(outcome[:output_tail] || "", -900, 900),
               source: "merge"
             }}
        end
      end
    after
      _ = Git.git(repo, ["worktree", "remove", "--force", root])
    end
  end

  defp verify_artifacts(_root, nil, _opts), do: :ok

  defp verify_artifacts(root, policy, opts) do
    case Artifacts.verify(root, policy, opts) do
      {:ok, _} -> :ok
      {:error, evidence} -> {:error, {:artifact_verification, evidence}}
    end
  end

  defp remove_stale(repo, root) do
    existed = File.exists?(root)

    case Git.git(repo, ["worktree", "remove", "--force", root]) do
      {:ok, _} -> :ok
      {:error, _} when not existed -> :ok
      {:error, reason} -> {:error, {:stale_verification_checkout, reason}}
    end
  end

  # Compare-and-swap primary from the recorded old SHA to the tested result.
  # A checked-out primary is fast-forwarded through its own clean checkout,
  # never moved behind its back.
  @doc false
  def advance(id, r) do
    %{"old" => old, "result" => result} = r["intent"]
    repo = r["repo"]
    primary = r["primary"]

    with {:ok, ^old} <- primary_ref(repo, primary),
         {:ok, touched} <- Git.git(repo, ["diff", "--name-only", "-z", old, result]),
         {:ok, checkouts} <- Preflight.primary_checkouts(repo, primary),
         :ok <-
           Preflight.check_primary_checkouts(checkouts, String.split(touched, "\0", trim: true)),
         :ok <- swap(repo, primary, old, result, r["branch"], checkouts),
         {:ok, %{"stage" => "integrated"} = r} <- Lifecycle.reconcile(id) do
      {:ok, r}
    else
      {:ok, %{} = _record} -> {:error, :integration_not_observed}
      {:ok, _moved} -> {:error, :primary_moved}
      error -> error
    end
  end

  defp primary_ref(repo, primary) do
    case Git.git(repo, ["rev-parse", "--verify", "refs/heads/" <> primary]) do
      {:ok, sha} -> {:ok, sha}
      _ -> {:error, :missing_primary}
    end
  end

  defp swap(repo, primary, old, result, branch, []) do
    case Git.git(repo, [
           "update-ref",
           "-m",
           "trailblazer: integrate " <> branch,
           "refs/heads/" <> primary,
           result,
           old
         ]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:cas_failed, reason}}
    end
  end

  defp swap(_repo, primary, old, result, _branch, [path]) do
    with {:ok, "refs/heads/" <> ^primary} <- Git.git(path, ["symbolic-ref", "HEAD"]),
         {:ok, ^old} <- Git.git(path, ["rev-parse", "HEAD"]),
         {:ok, _} <- Git.git(path, ["merge", "--ff-only", "--no-edit", result]) do
      :ok
    else
      {:error, reason} -> {:error, {:fast_forward_failed, reason}}
      _ -> {:error, :primary_moved}
    end
  end

  defp swap(_, _, _, _, _, _), do: {:error, :primary_checked_out_twice}
end
