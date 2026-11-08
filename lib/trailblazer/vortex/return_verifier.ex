defmodule Trailblazer.Vortex.ReturnVerifier do
  @moduledoc """
  Verifies a frontier's returned fix before it is reported as fixed (design
  §7.5, bug:a3339f5). The return is `{base, case, commit}`; the case's own
  base comes from its lifecycle record and its admitted task names the repo,
  check, artifact policy and files.

  Gates, in order. A rejected return never runs the check:

    1. base: the return's base is the base the case was opened on;
    2. ancestry: the returned commit is not the base and descends from it;
    3. scope: every path the commit changes (deletions and both sides of a
       rename included) is one of the case's files, when the case names files.

  Then the admitted check and artifact policy run in a detached worktree of
  the commit (`Trailblazer.Verification`): a pass is `{:verified, summary}`, a
  failed check `{:failed, summary}`. A failed friend's fix is reported, never
  retried. Nothing here merges, pushes or commits; the caller records the
  outcome with `Store.return_outcome/3`.
  """
  alias Trailblazer.{Config, Verification}
  alias Trailblazer.Loop.Lifecycle
  alias Trailblazer.Vortex.Store

  @check_limit_ms 60 * 60 * 1000

  @type result ::
          {:verified, String.t()} | {:rejected, String.t()} | {:failed, String.t()}

  @spec verify(String.t()) :: result()
  def verify(case_id) do
    request = Store.get(case_id)
    record = Lifecycle.get(case_id)

    cond do
      request == nil or request.returned_fix == nil ->
        {:rejected, "no returned fix is recorded for case #{case_id}"}

      record == nil or not is_binary(record["base"]) ->
        {:rejected, "case #{case_id} has no recorded base to verify against"}

      true ->
        gate(case_id, request, record)
    end
  end

  defp gate(case_id, request, record) do
    fix = request.returned_fix
    base = record["base"]
    commit = fix["commit"]
    repo = request.task["repo"]
    files = record["files"] || request.task["files"] || []

    with :ok <- base_gate(fix["base"], base),
         :ok <- ancestry_gate(repo, base, commit),
         :ok <- scope_gate(repo, base, commit, files) do
      check(case_id, request.task, repo, commit)
    end
  end

  defp base_gate(returned, base) when returned == base, do: :ok

  defp base_gate(returned, base),
    do: {:rejected, "returned fix is on base #{returned}, case base is #{base}"}

  defp ancestry_gate(repo, base, commit) do
    cond do
      commit == base ->
        {:rejected, "returned commit is the case base #{base}"}

      match?({:ok, _}, git(repo, ["merge-base", "--is-ancestor", base, commit])) ->
        :ok

      true ->
        {:rejected, "returned commit #{commit} does not descend from base #{base}"}
    end
  end

  defp scope_gate(_repo, _base, _commit, []), do: :ok

  defp scope_gate(repo, base, commit, files) do
    case git(repo, ["diff", "-z", "--name-only", "--no-renames", base, commit]) do
      {:ok, out} ->
        allowed = MapSet.new(files)
        changed = String.split(out, <<0>>, trim: true)

        case Enum.reject(changed, &MapSet.member?(allowed, &1)) do
          [] -> :ok
          outside -> {:rejected, "out of scope: " <> Enum.join(outside, ", ")}
        end

      {:error, reason} ->
        {:rejected, "returned commit #{commit} cannot be read from #{repo}: #{reason}"}
    end
  end

  defp check(case_id, task, repo, commit) do
    command = task["check"]

    if is_binary(command) and command != "" do
      root = Path.join([Config.get(:state_dir), "return-verification", case_id])
      limit = @check_limit_ms

      case Verification.run(repo, commit, command,
             root: root,
             label: "returned fix of " <> case_id,
             artifacts: task["artifacts"],
             timeout: limit,
             deadline_at: System.os_time(:millisecond) + limit
           ) do
        {:ok, summary} -> {:verified, summary}
        {:error, summary} -> {:failed, summary}
      end
    else
      {:failed, "case #{case_id} has no admitted check to verify the returned fix with"}
    end
  end

  defp git(dir, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
           cd: dir,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim_trailing(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  end
end
