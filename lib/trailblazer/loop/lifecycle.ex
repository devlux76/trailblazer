defmodule Trailblazer.Loop.Lifecycle do
  @moduledoc """
  Durable intent/evidence for repair Git effects. Reconciliation only observes
  Git: it never runs a check, advances a ref, or removes a workspace. Task 2's
  coordinator executes integration and cleanup after recording these intents.
  The journal remains available after the public case report has closed.
  """
  alias Trailblazer.{CaseStore, Files}
  alias Trailblazer.Loop.Workspace

  def get(id), do: CaseStore.lifecycle_get(id)

  def admit(id, task, ws) do
    with nil <- get(id),
         %{repo: _} <- CaseStore.case_get(id),
         {:ok, owner} <- Workspace.identity(ws, task.repo) do
      primary = Map.get(task, :primary)

      with true <- is_nil(primary) or valid_primary?(owner.repo, primary) do
        record = owner |> Jason.encode!() |> Jason.decode!()

        record =
          Map.merge(record, %{
            "primary" => primary,
            "primary_sha" => primary && git!(owner.repo, ["rev-parse", "refs/heads/" <> primary]),
            "owner" => Map.get(task, :from, "cli"),
            "files" => task.files,
            "trusted_check" => task.check,
            "candidate" => nil,
            "result" => nil,
            "stage" => "opened",
            "cleanup" => "pending",
            "history" => []
          })

        save(id, 0, record, "admitted")
      else
        _ -> {:error, :invalid_primary}
      end
    else
      %{"version" => _} = record ->
        with {:ok, owner} <- Workspace.identity(ws, task.repo),
             identity = Jason.decode!(Jason.encode!(owner)),
             true <- Map.take(record, Map.keys(identity)) == identity do
          {:ok, record}
        else
          _ -> {:error, :ownership_changed}
        end

      _ ->
        {:error, :invalid_ownership}
    end
  end

  def tree(ws, paths) do
    {:ok, tree} = Workspace.tree(ws, paths)
    tree
  end

  def record_check(id, evidence) do
    transition(id, fn r ->
      {:ok, Map.put(r, "check", Jason.decode!(Jason.encode!(evidence))), "check"}
    end)
  end

  def failed(id, reason) do
    error = inspect(reason)

    transition(id, fn r ->
      if r["last_error"] == error,
        do: {:ok, r},
        else: {:ok, Map.put(r, "last_error", error), "blocked"}
    end)
  end

  def reported(id, report) do
    transition(id, fn r ->
      {:ok, Map.merge(r, %{"outcome" => to_string(report.status), "summary" => report.summary}),
       "reported"}
    end)
  end

  def prepare_commit(id, tree, evidence) do
    transition(id, fn r ->
      cond do
        r["intent"] && r["intent"] != %{"kind" => "commit", "parent" => r["base"], "tree" => tree} ->
          {:error, :conflicting_intent}

        evidence[:status] != :pass or evidence[:tree] != tree or not is_binary(evidence[:command]) ->
          {:error, :unchecked_tree}

        r["candidate"] != nil ->
          {:error, :already_committed}

        true ->
          check = evidence |> Jason.encode!() |> Jason.decode!()

          {:ok,
           Map.merge(r, %{
             "stage" => "commit_pending",
             "check" => check,
             "intent" => %{"kind" => "commit", "parent" => r["base"], "tree" => tree}
           }), "commit_intent"}
      end
    end)
  end

  def prepare_integration(id, old, result, evidence) do
    transition(id, fn r ->
      cond do
        r["primary"] == nil ->
          {:error, :no_primary}

        r["stage"] != "candidate_ready" ->
          {:error, :not_candidate_ready}

        evidence[:status] != :pass or evidence[:sha] != result ->
          {:error, :unchecked_result}

        git!(r["repo"], ["rev-parse", result <> "^{commit}"]) != result ->
          {:error, :invalid_result}

        not ancestor?(r["repo"], r["candidate"], result) ->
          {:error, :candidate_not_in_result}

        true ->
          {:ok,
           Map.merge(r, %{
             "stage" => "integration_pending",
             "integration_check" => Jason.decode!(Jason.encode!(evidence)),
             "intent" => %{"kind" => "integration", "old" => old, "result" => result}
           }), "integration_intent"}
      end
    end)
  end

  def prepare_removal(id, archive \\ nil) do
    transition(id, fn r ->
      if r["stage"] == "integrated" and r["result"] != nil do
        {:ok,
         Map.merge(r, %{
           "stage" => "removal_pending",
           "archive" => archive || r["archive"],
           "intent" => %{"kind" => "removal"}
         }), "removal_intent"}
      else
        {:error, :not_integrated}
      end
    end)
  end

  # A tested integration whose compare-and-swap lost to a moved primary is
  # recomputed and retested from the candidate, never retried blindly.
  def reopen_integration(id) do
    transition(id, fn r ->
      with %{"kind" => "integration", "old" => old, "result" => result} <- r["intent"],
           actual = git!(r["repo"], ["rev-parse", "refs/heads/" <> r["primary"]]),
           true <- actual not in [old, result] do
        {:ok,
         r
         |> Map.merge(%{"stage" => "candidate_ready", "integration_check" => nil})
         |> Map.delete("intent"), "integration_reopened"}
      else
        _ -> {:error, :integration_not_reopenable}
      end
    end)
  end

  # Evidence of a case that will not be integrated (failed, unverified or
  # refused) is preserved outside Git, and verified, before its checkout and
  # branch are removed (design review, Lifecycle).
  def prepare_discard(id, archive) do
    transition(id, fn r ->
      cond do
        match?(%{"kind" => "discard"}, r["intent"]) ->
          {:ok, r}

        r["intent"] != nil ->
          {:error, :conflicting_intent}

        r["stage"] in ~w(integration_pending integrated removal_pending cleanup_complete discarded) ->
          {:error, :not_discardable}

        not archive_intact?(archive) ->
          {:error, :archive_missing}

        true ->
          {:ok,
           Map.merge(r, %{
             "stage" => "discard_pending",
             "archive" => archive,
             "intent" => %{"kind" => "discard"}
           }), "discard_intent"}
      end
    end)
  end

  # A pending removal or discard whose checkout changed after its archive
  # records the newer verified snapshot before anything is removed.
  def refresh_archive(id, archive) do
    transition(id, fn r ->
      cond do
        r["stage"] not in ~w(removal_pending discard_pending) -> {:error, :no_pending_removal}
        not archive_intact?(archive) -> {:error, :archive_missing}
        r["archive"] == archive -> {:ok, r}
        true -> {:ok, Map.put(r, "archive", archive), "archive_refreshed"}
      end
    end)
  end

  @doc "Whether every archived file is present with its recorded SHA-256."
  def archive_intact?(%{"path" => dir, "files" => files}) when is_binary(dir) and is_map(files) do
    map_size(files) > 0 and
      Enum.all?(files, fn {name, sha} ->
        case File.read(Path.join(dir, name)) do
          {:ok, data} -> sha256(data) == sha
          _ -> false
        end
      end)
  end

  def archive_intact?(_), do: false

  def sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  # Until the coordinator lands, release a clean candidate checkout but keep
  # its branch and evidence. This is distinct from post-integration cleanup.
  def prepare_candidate_removal(id) do
    transition(id, fn r ->
      with true <- r["stage"] == "candidate_ready",
           :ok <- ownership(r),
           true <- git!(r["repo"], ["rev-parse", "refs/heads/" <> r["branch"]]) == r["candidate"],
           "" <- git!(r["path"], ["status", "--porcelain", "--untracked-files=no"]) do
        {:ok,
         Map.merge(r, %{
           "cleanup" => "candidate_workspace_pending",
           "intent" => %{"kind" => "candidate_removal"}
         }), "candidate_removal_intent"}
      else
        _ -> {:error, :candidate_dirty_or_moved}
      end
    end)
  end

  def reconcile(id) do
    result = transition(id, &observe/1)

    case result do
      {:error, :no_lifecycle} ->
        {:ok, nil}

      {:error, reason} ->
        failed(id, reason)
        {:error, reason}

      other ->
        other
    end
  rescue
    e ->
      reason = {:observation_failed, Exception.message(e)}
      failed(id, reason)
      {:error, reason}
  end

  defp observe(%{"intent" => %{"kind" => "commit", "parent" => parent, "tree" => tree}} = r) do
    with :ok <- ownership(r) do
      sha = git!(r["repo"], ["rev-parse", "refs/heads/" <> r["branch"]])

      cond do
        sha == parent ->
          {:ok, r}

        git!(r["repo"], ["show", "-s", "--format=%P", sha]) != parent ->
          {:error, :unexpected_parent}

        git!(r["repo"], ["rev-parse", sha <> "^{tree}"]) != tree ->
          {:error, :unexpected_tree}

        true ->
          {:ok,
           r
           |> Map.merge(%{"stage" => "candidate_ready", "candidate" => sha})
           |> Map.delete("intent"), "candidate_ready"}
      end
    end
  end

  defp observe(%{"intent" => %{"kind" => "integration", "old" => old, "result" => result}} = r) do
    with :ok <- repository(r) do
      actual = git!(r["repo"], ["rev-parse", "refs/heads/" <> r["primary"]])

      cond do
        actual == old ->
          {:ok, r}

        actual == result ->
          {:ok,
           r |> Map.merge(%{"stage" => "integrated", "result" => result}) |> Map.delete("intent"),
           "integrated"}

        true ->
          {:error, :primary_moved}
      end
    end
  end

  defp observe(%{"intent" => %{"kind" => "candidate_removal"}} = r) do
    with :ok <- repository(r),
         true <- git!(r["repo"], ["rev-parse", "refs/heads/" <> r["branch"]]) == r["candidate"] do
      observe_removal(r, :candidate)
    else
      _ -> {:error, :candidate_moved}
    end
  end

  defp observe(%{"intent" => %{"kind" => "removal"}} = r) do
    with :ok <- repository(r),
         true <- r["archive"] == nil or archive_intact?(r["archive"]) do
      observe_removal(r, :integrated)
    else
      false -> {:error, :archive_missing}
      error -> error
    end
  end

  defp observe(%{"intent" => %{"kind" => "discard"}} = r) do
    with :ok <- repository(r),
         true <- archive_intact?(r["archive"]) do
      observe_removal(r, :discard)
    else
      false -> {:error, :archive_missing}
      error -> error
    end
  end

  defp observe(r), do: {:ok, r}

  defp observe_removal(r, mode) do
    paths = git!(r["repo"], ["worktree", "list", "--porcelain", "-z"])
    registered = String.split(paths, "\0") |> Enum.member?("worktree " <> r["path"])

    cond do
      not registered and File.lstat(r["path"]) == {:error, :enoent} ->
        if mode == :candidate or not branch_exists?(r) do
          {cleanup, stage} =
            case mode do
              :candidate -> {"candidate_workspace_removed", "candidate_ready"}
              :integrated -> {"complete", "cleanup_complete"}
              :discard -> {"complete", "discarded"}
            end

          {:ok, r |> Map.merge(%{"cleanup" => cleanup, "stage" => stage}) |> Map.delete("intent"),
           cleanup}
        else
          {:ok, r}
        end

      registered ->
        {:ok, r}

      true ->
        {:error, :unregistered_path_exists}
    end
  end

  defp branch_exists?(r) do
    {_, code} =
      System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/" <> r["branch"]],
        cd: r["repo"],
        stderr_to_stdout: true
      )

    case code do
      0 -> true
      1 -> false
      _ -> raise "Git branch observation failed (#{code})"
    end
  end

  defp repository(r) do
    with {:ok, canonical} <- Files.canonical_path(r["repo"]),
         true <- canonical == r["repo"],
         true <-
           git!(canonical, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) ==
             r["common"] do
      :ok
    else
      _ -> {:error, :ownership_changed}
    end
  end

  defp ownership(r) do
    with :ok <- repository(r),
         {:ok, owner} <-
           Workspace.identity(%{path: r["path"], branch: r["branch"], base: r["base"]}, r["repo"]),
         true <- owner.common == r["common"] do
      :ok
    else
      _ -> {:error, :ownership_changed}
    end
  end

  defp transition(id, fun) do
    case get(id) do
      nil ->
        {:error, :no_lifecycle}

      r ->
        case fun.(r) do
          {:ok, ^r} -> {:ok, r}
          {:ok, next, event} -> save(id, r["version"], next, event)
          error -> error
        end
    end
  end

  defp save(id, version, record, event) do
    entry = %{
      "event" => event,
      "at" => System.os_time(:millisecond),
      "version" => version + 1,
      "evidence" =>
        Map.take(
          record,
          ~w(intent check integration_check candidate result cleanup stage last_error archive)
        )
    }

    CaseStore.lifecycle_cas(id, version, Map.update!(record, "history", &(&1 ++ [entry])))
  end

  defp valid_primary?(repo, name) when is_binary(name) do
    match?(
      {_, 0},
      System.cmd("git", ["check-ref-format", "refs/heads/" <> name],
        cd: repo,
        stderr_to_stdout: true
      )
    )
  end

  defp valid_primary?(_, _), do: false

  defp ancestor?(repo, candidate, result) do
    case System.cmd("git", ["merge-base", "--is-ancestor", candidate, result],
           cd: repo,
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      {_, 1} -> false
      {out, code} -> raise "Git ancestry failed (#{code}): #{String.slice(out, 0, 400)}"
    end
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
           cd: repo,
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim_trailing(out, "\n")
      {out, code} -> raise "Git observation failed (#{code}): #{String.slice(out, 0, 400)}"
    end
  end
end
