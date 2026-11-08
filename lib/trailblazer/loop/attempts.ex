defmodule Trailblazer.Loop.Attempts do
  @moduledoc "The attempts loop: each attempt's generation, edits, verification and retry."

  alias Trailblazer.{Config}

  alias Trailblazer.Loop.{
    Coder,
    EditBlocks,
    Edits,
    Finish,
    Lifecycle,
    Outcome,
    Review,
    Verification,
    Workspace
  }

  import Trailblazer.Loop.Ledger,
    only: [
      tally: 1,
      tally: 2,
      mod: 3,
      now: 0,
      record: 3,
      budget_remaining!: 0,
      verification_remaining: 1,
      describe: 1,
      git: 2,
      submit_how: 1
    ]

  @attempts 3

  @doc false
  def attempts(%{task: %{replay_reply_from: source}} = st, _trail, _files, _check, n, _feedback)
      when is_binary(source) and n > 1, do: Outcome.exhausted(st)

  def attempts(st, trail, files, check, n, feedback) do
    if n > max_attempts(),
      do: Outcome.exhausted(st),
      else: attempt(st, trail, files, check, n, feedback)
  end

  defp attempt(st, trail, files, check, n, feedback) do
    record(st, :attempt, %{stage: :attempt, n: n})
    tally(:changed, Map.get(st, :carried_paths, []))
    tally(:edit_tree, nil)
    tally(:previous_edits, nil)
    tally(:relocations, [])
    tally(:artifacts, nil)
    tally(:served_reads, nil)

    case attempt(st, trail, files, check, feedback) do
      {:ok, reply} ->
        Finish.succeeded(st, n, reply, check)

      {:awaiting_review, reason} ->
        Review.awaiting_review(st, reason)

      {:retry, why, next_feedback} ->
        next_feedback =
          Enum.map_join(Enum.reverse(tally(:relocations)), "", &Edits.relocation_notice/1) <>
            next_feedback

        next_feedback =
          case tally(:previous_edits) do
            [_ | _] = edits ->
              next_feedback <>
                "\n\nPrevious submitted edit blocks (reference only, captured before any check; a missed atomic submission writes no files). " <>
                "Use their exact code to diagnose the failure; still submit corrected edits #{submit_how(st)}.\n\n```json\n" <>
                Jason.encode!(edits, pretty: true) <> "\n```"

            _ ->
              next_feedback
          end

        failure = %{n: n, why: why, feedback: next_feedback, changed: tally(:changed)}
        st = %{st | failures: st.failures ++ [failure]}

        # the last attempt's edits stay in the worktree for inspection
        retry? = n < max_attempts() and is_nil(st.task.replay_reply_from)

        # The next attempt continues from the model's own edits (as written,
        # before any check or tool ran), so errors refer to the files it sees.
        edited = tally(:edit_tree)
        edited = if is_binary(edited), do: edited, else: nil
        carried = edited || Map.get(st, :carried_tree)
        paths = if edited, do: tally(:changed), else: Map.get(st, :carried_paths, [])
        st = st |> Map.put(:carried_tree, carried) |> Map.put(:carried_paths, paths)

        reset = fn ->
          cond do
            not retry? ->
              :ok

            is_nil(carried) ->
              mod(st, :workspace, Workspace).reset(st.ws)

            true ->
              with :ok <- mod(st, :workspace, Workspace).reset(st.ws),
                   do: Workspace.restore(st.ws, carried)
          end
        end

        case with :ok <- checkpoint_attempt(st, n), do: reset.() do
          :ok ->
            next_feedback =
              if retry? do
                next_feedback <>
                  if(carried,
                    do:
                      "\n\nYour previous edits are still applied; any changes made by checks or tools were discarded. " <>
                        "The output above refers to the current files: make corrective edits to them (read them again for exact text and lines), " <>
                        "and do not re-apply changes that are already there.",
                    else:
                      "\n\nThe worktree was reset to its original files; previous edits remain in the attempt checkpoint and case record. " <>
                        "Apply your complete corrected change to the original files shown above."
                  )
              else
                next_feedback
              end

            attempts(st, trail, files, check, n + 1, next_feedback)

          {:error, reason} ->
            record(st, :error, %{stage: :reset, reason: reason})

            Outcome.report(
              st,
              :failed,
              "The worktree could not be reset after attempt #{n}: #{describe(reason)}.",
              %{attempts: n}
            )
        end

      {:stop, report} ->
        report
    end
  end

  # A generation deadline spans every read, correction and model call in one
  # fresh conversation. Verification time is shared across all three attempts.
  defp attempt(st, trail, files, check, feedback) do
    with {:ok, reply} <- generate(st, trail, files, feedback),
         {:ok, blocks} <- EditBlocks.blocks(st, reply),
         :ok <- EditBlocks.apply_edits(st, blocks) do
      started = now()
      remaining = verification_remaining(st)
      tally(:phase, {:verification, started + remaining})

      try do
        budget_remaining!()

        result =
          with :ok <- Verification.prepare_artifacts(st),
               :ok <- Verification.compile_checkpoint(st),
               :ok <- Verification.run_check(st, check),
               :ok <- Review.review(st),
               do: {:ok, reply}

        budget_remaining!()
        result
      catch
        :throw, {:budget_expired, :verification} ->
          {:awaiting_review, :verification_budget_exhausted}
      after
        tally(:verification_ms, tally(:verification_ms) + now() - started)
        tally(:phase, nil)
      end
    end
  end

  defp generate(st, trail, files, feedback) do
    limit = Keyword.get(st.opts, :generation_limit_ms, 900_000)
    tally(:phase, {:generation, now() + limit})
    record(st, :attempt, %{stage: :generation_budget, limit_ms: limit})

    try do
      result = Coder.coder_reply(st, trail, files, feedback)
      budget_remaining!()
      result
    catch
      :throw, {:budget_expired, :generation} ->
        record(st, :error, %{stage: :generation, reason: :generation_timeout})

        {:retry, :generation_timeout,
         "The 15-minute generation window expired. Start in a fresh context and submit a smaller complete change. Partial output is preserved in the case record."}
    after
      tally(:phase, nil)
    end
  end

  defp checkpoint_attempt(st, n) do
    tree = Lifecycle.tree(st.ws, tally(:changed))
    ref = "refs/trailblazer/attempts/#{st.id}/#{n}"

    case git(st.ws.path, ["update-ref", ref, tree]) do
      {:ok, _} ->
        record(st, :attempt, %{stage: :attempt_checkpoint, n: n, tree: tree, ref: ref})
        :ok

      {:error, reason} ->
        {:error, {:checkpoint_failed, reason}}
    end
  end

  # Local attempts per case (:code_attempts, at most the built-in three); the
  # frontier is the fallback after them.
  defp max_attempts, do: min(Config.get(:code_attempts) || @attempts, @attempts)
end
