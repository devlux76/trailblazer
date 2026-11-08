defmodule Trailblazer.Loop.Review do
  @moduledoc "The review of a checked tree: verdicts, retries and the unreviewable case."

  alias Trailblazer.Config
  alias Trailblazer.Loop.{Conversation, Lifecycle, Outcome, Prompts, TextAnswers, Workspace}

  import Trailblazer.Loop.Ledger,
    only: [tally: 1, mod: 3, record: 3, describe: 1, git: 2]

  # The review, in a fresh context: the request, the design, the diff only.
  # Spark never reviews Spark; the reviewer is a different model on its
  # own router. An unclear, timed-out, unavailable or unusable review is
  # never fed back to the coder and never fails a tree that passed its
  # check.
  @doc false
  def review(st) do
    if Config.get(:review_model) == Config.get(:code_model) do
      record(st, :review, %{verdict: :refused, reason: :same_model})
      {:awaiting_review, :same_model_review_refused}
    else
      diff = mod(st, :workspace, Workspace).diff(st.ws, tally(:changed))

      artifact_note =
        case tally(:artifacts) do
          nil ->
            ""

          evidence ->
            "\n\nTrusted artifact preparation (review generated/deleted outputs and modified build definitions):\n" <>
              Jason.encode!(
                Map.take(evidence, [
                  :command,
                  :paths,
                  :deleted_paths,
                  :definitions_changed,
                  :policy_hash
                ])
              )
        end

      files = TextAnswers.changed_files(st.ws.path, diff)
      messages = Prompts.reviewer(st.task, diff <> artifact_note, st.head.evidence, files)
      review_passes(st, messages, 1)
    end
  end

  # One review pass per Backstop, and three passes at most per case; a
  # retry never inherits or resets a larger budget. An error or timeout
  # consumes a pass like an unclear verdict, and the pass after the
  # third parks the case for the frontier.
  defp review_passes(st, messages, pass) when pass <= 3 do
    case Conversation.converse(st, messages, nil, :reviewer) do
      {:ok, reply} ->
        case judged(reply) do
          :pass ->
            record(st, :review, %{verdict: :pass, pass: pass, text: reply.content})
            :ok

          {:fail, findings} ->
            record(st, :review, %{verdict: :fail, pass: pass, text: findings})
            {:retry, :review, "The review of your change found:\n\n#{findings}"}

          {:unclear, text} ->
            record(st, :review, %{verdict: :unclear, pass: pass, text: text})

            if pass < 3 do
              disambiguate(messages, reply)
              |> then(&review_passes(st, &1, pass + 1))
            else
              {:awaiting_review, :review_unclear}
            end
        end

      {:review_error, reason} ->
        record(st, :review, %{verdict: :unavailable, pass: pass, reason: reason})

        if pass < 3 do
          review_passes(st, messages, pass + 1)
        else
          {:awaiting_review, reason}
        end
    end
  end

  defp disambiguate(messages, reply) do
    messages ++
      [
        %{role: "assistant", content: reply.content},
        %{role: "user", content: "Answer with exactly PASS, or FAIL: and the findings."}
      ]
  end

  # a review cut off at the length limit may say PASS and mean nothing
  defp judged(%{finish_reason: "length", content: text}), do: {:unclear, text}

  defp judged(reply), do: Prompts.review_verdict(reply.content)

  # The review could not produce a verdict the machine may act on. The
  # checked tree is the work product: pin it to a durable ref before
  # anything else is released, keep the workspace and branch as evidence,
  # and close as awaiting_review. No reset, no coder call, no commit —
  # an unusable review is not a defect to fix.
  @doc false
  def awaiting_review(st, reason) do
    ws = st.ws
    tree = Lifecycle.tree(ws, tally(:changed))
    ref = "refs/trailblazer/checkpoints/" <> st.id

    pinned =
      case git(ws.path, ["update-ref", ref, tree]) do
        {:ok, _} -> true
        {:error, _} -> false
      end

    record(st, :review, %{
      verdict: :awaiting_review,
      reason: reason,
      tree: tree,
      ref: ref,
      pinned: pinned
    })

    note =
      if reason == :verification_budget_exhausted do
        "The shared 15-minute verification budget expired. The tree at #{ref} is preserved; check status is #{inspect(tally(:check) && tally(:check).status)}. Frontier verification is required; no automatic coder retry."
      else
        "The reviewer could not produce a verdict (#{describe(reason)}). " <>
          "The checked tree is pinned at #{ref} (tree #{tree}); " <>
          "the worktree and branch are retained; no commit was made and " <>
          "the coder was not asked again. The frontier reviews; nothing is re-coded."
      end

    Outcome.report(
      st,
      :awaiting_review,
      note,
      %{
        files: tally(:changed),
        tree: tree,
        ref: ref,
        reason: reason,
        pinned: pinned,
        attempts: length(st.failures) + 1
      }
    )
    |> Map.put(:awaiting_review, %{ref: ref, tree: tree, reason: reason, pinned: pinned})
  end
end
