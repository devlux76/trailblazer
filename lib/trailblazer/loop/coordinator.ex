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

  alias Trailblazer.{Config, Files, Loop.Check, Loop.Lifecycle, Loop.Workspace}

  @table :trailblazer_coordinator_locks

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
         {:ok, checkouts} <- primary_checkouts(repo, primary),
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

          path =
            Enum.find_value(lines, fn
              "worktree " <> p -> String.trim(p)
              _ -> nil
            end)

          branch =
            Enum.find_value(lines, fn
              "branch refs/heads/" <> b -> String.trim(b)
              _ -> nil
            end)

          if is_binary(path) and branch == primary do
            [path | acc]
          else
            acc
          end
        end)
        |> Enum.reverse()
        |> then(&{:ok, &1})

      # Unknown checkouts are never treated as none: that could move a
      # checked-out primary behind its worktree's back.
      {:error, reason} ->
        {:error, {:worktree_discovery_failed, reason}}
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
          with_lock(common, fn ->
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
        with {:ok, pre} <- preflight_record(id, r),
             {:ok, r} <- integrate(id, r, pre, opts),
             do: cleanup(id, r)

      "integration_pending" ->
        with {:ok, r} <- advance(id, r), do: cleanup(id, r)

      stage when stage in ~w(integrated removal_pending) ->
        cleanup(id, r)

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
        discard(id, r)

      _ ->
        with {:ok, archive} <- archive(id, r),
             {:ok, r} <- Lifecycle.prepare_discard(id, archive),
             do: discard(id, r)
    end
  end

  # The tested result: the candidate itself when primary has not moved past
  # its base (its own check is the evidence), otherwise a merge commit of the
  # moved primary and the candidate, tested in a detached checkout.
  defp integrate(id, r, pre, opts) do
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

    if ancestor?(repo, old, candidate) do
      check = r["check"] || %{}

      with "pass" <- check["status"],
           {:ok, tree} <- git(repo, ["rev-parse", candidate <> "^{tree}"]),
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
      with {:ok, result} <- merge_commit(r, old, candidate),
           {:ok, evidence} <- verify(id, repo, result, command, opts),
           do: {:ok, result, evidence}
    end
  end

  defp merge_commit(r, old, candidate) do
    repo = r["repo"]

    case cmd(repo, ["merge-tree", "--write-tree", "--no-messages", old, candidate]) do
      {out, 0} ->
        tree = out |> String.split("\n") |> hd()

        with {:ok, body} <- git(repo, ["log", "-1", "--format=%B", candidate]),
             message = "Merge #{r["branch"]} into #{r["primary"]}\n\n#{String.trim(body)}\n",
             {:ok, sha} <-
               git(repo, ["commit-tree", tree, "-p", old, "-p", candidate, "-m", message]) do
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

  defp verify(id, repo, result, command, opts) do
    root = Path.join([Config.get(:state_dir), "integration", id])
    check = Keyword.get(opts, :check, Check)

    try do
      with :ok <- File.mkdir_p(Path.dirname(root)),
           :ok <- remove_stale(repo, root),
           {:ok, _} <- git(repo, ["worktree", "add", "--detach", root, result]),
           :ok <- Workspace.provision_checkout(root, repo) do
        outcome = check.run(root, command, Keyword.get(opts, :check_opts, []))

        cond do
          outcome.status != :pass ->
            {:error, {:integration_check_failed, outcome.status, outcome[:exit]}}

          git(root, ["status", "--porcelain", "--untracked-files=no"]) != {:ok, ""} ->
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
      _ = git(repo, ["worktree", "remove", "--force", root])
    end
  end

  defp remove_stale(repo, root) do
    existed = File.exists?(root)

    case git(repo, ["worktree", "remove", "--force", root]) do
      {:ok, _} -> :ok
      {:error, _} when not existed -> :ok
      {:error, reason} -> {:error, {:stale_verification_checkout, reason}}
    end
  end

  # Compare-and-swap primary from the recorded old SHA to the tested result.
  # A checked-out primary is fast-forwarded through its own clean checkout,
  # never moved behind its back.
  defp advance(id, r) do
    %{"old" => old, "result" => result} = r["intent"]
    repo = r["repo"]
    primary = r["primary"]

    with {:ok, ^old} <- primary_ref(repo, primary),
         {:ok, touched} <- git(repo, ["diff", "--name-only", "-z", old, result]),
         {:ok, checkouts} <- primary_checkouts(repo, primary),
         :ok <- check_primary_checkouts(checkouts, String.split(touched, "\0", trim: true)),
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
    case git(repo, ["rev-parse", "--verify", "refs/heads/" <> primary]) do
      {:ok, sha} -> {:ok, sha}
      _ -> {:error, :missing_primary}
    end
  end

  defp swap(repo, primary, old, result, branch, []) do
    case git(repo, [
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
    with {:ok, "refs/heads/" <> ^primary} <- git(path, ["symbolic-ref", "HEAD"]),
         {:ok, ^old} <- git(path, ["rev-parse", "HEAD"]),
         {:ok, _} <- git(path, ["merge", "--ff-only", "--no-edit", result]) do
      :ok
    else
      {:error, reason} -> {:error, {:fast_forward_failed, reason}}
      _ -> {:error, :primary_moved}
    end
  end

  defp swap(_, _, _, _, _, _), do: {:error, :primary_checked_out_twice}

  defp cleanup(id, r) do
    with {:ok, r} <- ensure_removal(id, r),
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
    with {:ok, archive} <- archive(id, r), do: Lifecycle.prepare_removal(id, archive)
  end

  defp discard(id, r) do
    with :ok <- remove_checkout(r),
         :ok <- delete_branch(r, r["archive"]["branch_sha"]),
         {:ok, %{"stage" => "discarded"} = r} <- Lifecycle.reconcile(id) do
      {:ok, r}
    else
      {:ok, _} -> {:error, :cleanup_not_observed}
      error -> error
    end
  end

  defp registration(r) do
    case git(r["repo"], ["worktree", "list", "--porcelain", "-z"]) do
      {:ok, text} -> {:ok, text |> String.split("\0") |> Enum.member?("worktree " <> r["path"])}
      {:error, reason} -> {:error, {:worktree_discovery_failed, reason}}
    end
  end

  # Nothing is removed unless the verified archive is still intact, also when
  # an interrupted cleanup resumes: it holds everything the checkout had
  # beyond its base (ignored and provisioned dependency/build trees aside).
  defp remove_checkout(r) do
    with true <- Lifecycle.archive_intact?(r["archive"]),
         {:ok, registered} <- registration(r) do
      cond do
        registered ->
          case git(r["repo"], [
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

    case cmd(r["repo"], ["show-ref", "--verify", "--quiet", ref]) do
      {_, 1} ->
        :ok

      {_, 0} when is_binary(expected) ->
        case git(r["repo"], ["update-ref", "-d", ref, expected]) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :branch_moved}
        end

      {_, 0} ->
        {:error, :branch_moved}

      {out, code} ->
        {:error, {:branch_observation_failed, code, out}}
    end
  end

  ## Evidence archive

  # Written outside any worktree, atomically, then read back against its
  # SHA-256 before anything is removed (Lifecycle.archive_intact?/1).
  defp archive(id, r) do
    dir = Path.join([Config.get(:state_dir), "archive", id])

    with {:ok, branch_sha} <- branch_sha(r),
         {:ok, patch} <- changes(r, branch_sha),
         journal = Jason.encode!(r, pretty: true),
         :ok <- File.mkdir_p(dir),
         :ok <- put(dir, "journal.json", journal),
         :ok <- put(dir, "changes.patch", patch) do
      archive = %{
        "path" => dir,
        "branch_sha" => branch_sha,
        "files" => %{
          "journal.json" => Lifecycle.sha256(journal),
          "changes.patch" => Lifecycle.sha256(patch)
        }
      }

      if Lifecycle.archive_intact?(archive),
        do: {:ok, archive},
        else: {:error, :archive_unverified}
    else
      {:error, reason} -> {:error, {:archive_failed, reason}}
    end
  end

  defp branch_sha(r) do
    case cmd(r["repo"], ["rev-parse", "--verify", "--quiet", "refs/heads/" <> r["branch"]]) do
      {sha, 0} -> {:ok, String.trim(sha)}
      {_, 1} -> {:ok, nil}
      {out, code} -> {:error, {:branch_observation_failed, code, out}}
    end
  end

  @excluded ~w(deps node_modules _build target)

  # Everything the case changed relative to its base: committed candidate
  # work plus, while its checkout exists, uncommitted and untracked files
  # (provisioned dependency and build trees excluded), at every stage.
  defp changes(r, branch_sha) do
    base = r["base"]

    with {:ok, registered} <- registration(r) do
      cond do
        registered ->
          excludes = Enum.map(@excluded, &":(exclude,glob)**/#{&1}")

          with {:ok, _} <- git(r["path"], ["add", "-A", "--", "."] ++ excludes),
               do: git_raw(r["path"], ["diff", "--cached", "--binary", base])

        is_binary(branch_sha) ->
          git_raw(r["repo"], ["diff", "--binary", base, branch_sha])

        true ->
          {:ok, ""}
      end
    end
  end

  defp put(dir, name, data) do
    path = Path.join(dir, name)
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, data), do: File.rename(tmp, path)
  end

  defp ancestor?(repo, a, b), do: match?({_, 0}, cmd(repo, ["merge-base", "--is-ancestor", a, b]))

  defp cmd(repo, args) do
    System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
      cd: repo,
      stderr_to_stdout: true
    )
  rescue
    e in ErlangError -> {Exception.message(e), 128}
  end

  defp git_raw(repo, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args, cd: repo) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {code, String.slice(out, -400, 400)}}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
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
