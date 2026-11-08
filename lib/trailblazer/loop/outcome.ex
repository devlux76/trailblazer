defmodule Trailblazer.Loop.Outcome do
  @moduledoc "Ending a task: the report, the coordinator hand-off, the exhausted dossier and the frontier fallback."

  require Logger
  alias Trailblazer.{Config}
  alias Trailblazer.Loop.{CaseRecord, Lifecycle, Prompts}

  import Trailblazer.Loop.Ledger,
    only: [tally: 1, now: 0, record: 3, verification_remaining: 1, describe: 1]

  # A primary admitted with the case is the trusted policy that hands its
  # outcome to the coordinator: a fixed candidate is integrated, anything else
  # is archived, and both end with the managed checkout and branch removed.
  # Without one the candidate branch (and an unfinished worktree) stays for
  # the caller, as before. A blocked coordinator keeps the candidate and says
  # why; the public status stays as the Loop decided it.
  @doc false
  def coordinate(id, report, opts) do
    coordinator = Keyword.get(opts, :coordinator, Trailblazer.Loop.Coordinator)

    case Lifecycle.get(id) do
      %{"primary" => primary} when is_binary(primary) ->
        result =
          cond do
            report.status == :fixed ->
              checks = Keyword.get(opts, :check_opts, [])
              checks = Keyword.put(checks, :deadline_at, report.verification_deadline_at)
              coordinator.accept(id, check_opts: checks)

            report.status == :awaiting_review or
                report[:reason] in [
                  :edit_repair_exhausted,
                  :source_context_missing,
                  :decomposition_required,
                  :compiled_checkpoint_failed
                ] ->
              {:ok, %{"stage" => "retained"}}

            true ->
              coordinator.retire(id, [])
          end

        coordinated(report, result)

      _ ->
        report
    end
  rescue
    e -> coordinated(report, {:error, {:coordinator_crashed, Exception.message(e)}})
  end

  defp coordinated(report, {:ok, %{"stage" => "cleanup_complete"} = r}) do
    %{
      report
      | worktree: nil,
        summary:
          report.summary <>
            " Integrated into #{r["primary"]} at #{r["result"]}; candidate branch and checkout removed, evidence archived at #{r["archive"]["path"]}."
    }
    |> Map.put(:integration, %{
      primary: r["primary"],
      result: r["result"],
      archive: r["archive"]["path"]
    })
  end

  defp coordinated(report, {:ok, %{"stage" => "retained"}}) do
    %{
      report
      | summary:
          report.summary <>
            " Not integrated; workspace, branch and checked tree retained for frontier review."
    }
  end

  defp coordinated(report, {:ok, %{"stage" => "discarded"} = r}) do
    %{
      report
      | worktree: nil,
        summary:
          report.summary <>
            " Not integrated; evidence archived at #{r["archive"]["path"]} and the checkout and branch removed."
    }
    |> Map.put(:archive, r["archive"]["path"])
  end

  defp coordinated(report, {:error, reason}) do
    %{
      report
      | summary:
          report.summary <>
            " Coordinator blocked: #{inspect(reason)}; candidate and evidence retained."
    }
  end

  defp coordinated(report, _), do: report

  @doc false
  def exhausted(st) do
    attempts = length(st.failures)

    diagnosis =
      st.failures
      |> Enum.map(&describe(&1.why))
      |> Enum.frequencies()
      |> Enum.map_join(", ", fn {why, count} -> "#{why} (#{count})" end)

    dossier =
      Prompts.dossier(%{
        case: st.id,
        request: st.task.request,
        from: st.task.from,
        repo: st.task.repo,
        branch: st.ws.branch,
        worktree: st.ws.path,
        trail: "(in the case record)",
        attempts:
          Enum.map(st.failures, fn f ->
            %{n: f.n, summary: changed_summary(f.changed), failure: f.feedback}
          end),
        diagnosis: "All #{attempts} attempts failed: #{diagnosis}."
      })

    record(st, :dossier, %{text: dossier})
    frontier_fallback(st, attempts, diagnosis, dossier)

    report(
      st,
      :failed,
      "#{attempts} attempts failed: #{diagnosis}. Decompose this card into smaller tasks; preserved attempt checkpoints and the dossier show what was tried.",
      %{
        attempts: attempts,
        dossier: dossier,
        reason: :decomposition_required,
        files: tally(:changed)
      }
    )
  end

  # The frontier fallback: the dossier (request, worktree, every attempt's
  # failure) plus the design and check is written next to the case record,
  # and the configured ping command (:frontier_ping, e.g. ["ping-claude"])
  # gets a self-contained message pointing at it, so the frontier can write
  # the patch without being briefed. Background, never raises; off when unset.
  defp frontier_fallback(st, attempts, diagnosis, dossier) do
    with [cmd | args] <- Config.get(:frontier_ping) || [],
         path = Path.join(CaseRecord.dir(st.id), "dossier.md"),
         :ok <- File.mkdir_p(Path.dirname(path)),
         brief =
           dossier <>
             "\n\nDesign:\n" <>
             Enum.join(st.task[:design] || [], "\n\n") <>
             "\n\nCheck: " <> to_string(st.task[:check]) <> "\n",
         :ok <- File.write(path, brief) do
      card = get_in(st.task, [:planner, :ref])

      text =
        "Trailblazer frontier fallback: case #{st.id}" <>
          if(card, do: " (card #{card})", else: "") <>
          " failed #{attempts} local attempts (#{diagnosis}). Write the patch as the next attempt. " <>
          "Brief: #{path}. Base worktree #{st.task.repo}; case worktree #{st.ws.path}; check: #{st.task[:check]}"

      Task.start(fn ->
        try do
          System.cmd(cmd, args ++ [text],
            stderr_to_stdout: true,
            env: [{"PING_FROM", "Trailblazer"}]
          )
        rescue
          e -> Logger.warning("trailblazer: frontier ping failed: #{Exception.message(e)}")
        end
      end)

      record(st, :frontier, %{stage: :fallback, brief: path})
    else
      _ -> :ok
    end
  end

  defp changed_summary([]), do: nil

  defp changed_summary(paths), do: Enum.join(paths, ", ")

  @doc false
  def crashed(st, text) do
    Logger.error("trailblazer: case #{st.id} crashed: #{text}")
    _ = CaseRecord.event(st.id, :error, %{stage: :crash, error: text})
    report(st, :failed, "Trailblazer failed inside the loop; the case record has the error.")
  end

  @doc false
  def report(st, status, summary, extra \\ %{}) do
    check =
      case tally(:check) do
        nil -> nil
        %{status: :pass} -> %{status: :pass}
        %{status: s} = c -> %{status: s, output_tail: c.output_tail}
      end

    report = %{
      status: status,
      summary: summary,
      branch: st.ws && st.ws.branch,
      commit: extra[:commit],
      worktree: if(st.ws && tally(:workspace_closed) != true, do: st.ws.path),
      files: extra[:files] || [],
      check: check,
      attempts: extra[:attempts] || length(st.failures),
      cost: %{
        model_calls: tally(:model_calls),
        prompt_tokens: tally(:prompt_tokens),
        completion_tokens: tally(:completion_tokens),
        seconds: div(now() - st.started, 1000)
      },
      case: st.id,
      verification_deadline_at: System.os_time(:millisecond) + verification_remaining(st),
      compiled: compiled_report(),
      test_bugs: Map.values(tally(:test_bugs)) |> Enum.uniq()
    }

    report = Map.merge(report, Map.take(extra, [:reason]))
    if extra[:dossier], do: Map.put(report, :dossier, extra[:dossier]), else: report
  end

  defp compiled_report do
    case tally(:compiled) do
      nil -> nil
      cp -> cp |> Map.drop([:ws, :source, :case]) |> Map.put(:base, cp.ws.base)
    end
  end
end
