defmodule Trailblazer.Verification do
  @moduledoc """
  Independent verification of one exact commit (design §7.5, §7.6): a detached
  worktree of the commit under `root`, the admitted artifact policy, the
  admitted check run inside it, and a check that the check left the tracked
  candidate files alone. The worktree is removed afterwards, whatever happened.

  Callers own the decision about what the commit is. `Planner.Companion` checks
  the case's reported commit against its branch first; `Vortex.ReturnVerifier`
  checks a frontier's returned commit against the case's base and scope first.
  This module only runs the check and reports what it saw.

  Options:

    * `root:` the worktree path (created here, removed here);
    * `label:` the name the commit is known by, used in the success text;
    * `artifacts:` the admitted artifact policy, or `nil`;
    * `timeout:` and `deadline_at:` bound the check (passed to `Check.run/3`).

  Returns `{:ok, summary}` when the check passes and the tracked files are
  clean, otherwise `{:error, summary}`.
  """
  alias Trailblazer.Loop.{Artifacts, Check, Workspace}

  @spec run(Path.t(), String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(repo, commit, command, opts) do
    root = Keyword.fetch!(opts, :root)
    label = Keyword.fetch!(opts, :label)
    artifacts = Keyword.get(opts, :artifacts)
    check_opts = Keyword.take(opts, [:timeout, :deadline_at])

    try do
      with :ok <- File.mkdir_p(Path.dirname(root)),
           :ok <- remove_interrupted_worktree(repo, root),
           {:ok, _} <- git(repo, ["worktree", "add", "--detach", root, commit]),
           :ok <- Workspace.provision_checkout(root, repo),
           :ok <- verify_artifacts(root, artifacts, check_opts) do
        result = Check.run(root, command, check_opts)

        tail =
          result.output_tail
          |> String.slice(-900, 900)
          |> String.replace(root, "<verification-worktree>")

        cond do
          result.status != :pass ->
            {:error,
             "Independent verification failed (#{result.status}, exit #{inspect(result.exit)}): #{command}. #{tail}"}

          true ->
            case git(root, ["status", "--porcelain", "--untracked-files=no"]) do
              {:ok, ""} ->
                {:ok,
                 "Independent verification passed (exit 0): #{command}. Candidate #{commit} on #{label}; not merged. #{tail}"}

              {:ok, _} ->
                {:error, "Independent verification changed tracked candidate files."}

              {:error, reason} ->
                {:error,
                 "Independent verification status failed: #{String.slice(reason, -300, 300)}"}
            end
        end
      else
        {:error, reason} ->
          detail =
            inspect(reason)
            |> String.replace(root, "<verification-worktree>")
            |> String.replace(repo, "<repository>")
            |> String.slice(-900, 900)

          {:error, "Independent verification setup failed: #{detail}"}
      end
    after
      git(repo, ["worktree", "remove", "--force", root])
    end
  end

  defp verify_artifacts(_root, nil, _limit), do: :ok

  defp verify_artifacts(root, policy, opts) do
    case Artifacts.verify(root, policy, opts) do
      {:ok, _} -> :ok
      {:error, evidence} -> {:error, {:artifact_verification, evidence}}
    end
  end

  defp remove_interrupted_worktree(repo, root) do
    existed = File.exists?(root)

    case git(repo, ["worktree", "remove", "--force", root]) do
      {:ok, _} -> :ok
      {:error, _} when not existed -> :ok
      {:error, reason} -> {:error, "Interrupted verification cleanup failed: #{reason}"}
    end
  end

  defp git(dir, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
           cd: dir,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  end
end
