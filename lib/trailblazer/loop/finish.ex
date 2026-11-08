defmodule Trailblazer.Loop.Finish do
  @moduledoc "Ending a fixed task: the commit, the candidate cleanup and the commit message."

  alias Trailblazer.Loop.{CompiledCheckpoint, Lifecycle, Outcome, Workspace}

  import Trailblazer.Loop.Ledger,
    only: [tally: 1, tally: 2, mod: 3, record: 3, describe: 1, lifecycle: 1]

  @doc false
  def succeeded(st, n, reply, check) do
    workspace = mod(st, :workspace, Workspace)
    # a reply of blocks alone (the third live trial) still gets a summary
    explanation =
      case explanation(reply.content) do
        "" -> "Changed #{Enum.join(tally(:changed), ", ")}."
        text -> text
      end

    extra = %{files: tally(:changed), attempts: n}

    cond do
      check == nil ->
        Outcome.report(
          st,
          :unverified,
          "Changed and reviewed, but there is no check, so it is left uncommitted in the worktree. #{explanation}",
          extra
        )

      true ->
        evidence = tally(:check)
        current_tree = Lifecycle.tree(st.ws, tally(:changed))

        commit =
          if evidence.tree == current_tree do
            with {:ok, message} <- commit_message(st.task.request),
                 {:ok, _} <- Lifecycle.prepare_commit(st.id, current_tree, evidence),
                 do: workspace.commit(st.ws, message, tally(:changed))
          else
            {:error,
             "the candidate changed after its trusted check; use a check that does not rewrite tracked files"}
          end

        case commit do
          {:ok, sha} ->
            journal = lifecycle(Lifecycle.reconcile(st.id))

            if journal["candidate"] == sha do
              refs = Map.values(tally(:test_bugs)) |> Enum.uniq()

              if refs != [] do
                resolved =
                  CompiledCheckpoint.resolve(
                    st.task.repo,
                    refs,
                    sha,
                    Keyword.get(st.opts, :checkpoint_opts, [])
                  )

                record(st, :attempt, %{stage: :test_bugs_resolved, results: resolved})
              end

              summary =
                case close_candidate(st, workspace) do
                  :ok ->
                    explanation

                  {:error, reason} ->
                    explanation <> " Candidate workspace cleanup blocked: #{inspect(reason)}."
                end

              Outcome.report(st, :fixed, summary, Map.put(extra, :commit, sha))
            else
              Outcome.report(
                st,
                :failed,
                "The commit could not be reconciled with its checked tree.",
                extra
              )
            end

          {:error, reason} ->
            _ = Lifecycle.failed(st.id, reason)

            Outcome.report(
              st,
              :failed,
              "Check and review passed, but the commit failed: #{describe(reason)}.",
              extra
            )
        end
    end
  end

  defp close_candidate(st, workspace) do
    result =
      with {:ok, _} <- Lifecycle.prepare_candidate_removal(st.id),
           :ok <- workspace.close(st.ws),
           {:ok, %{"cleanup" => "candidate_workspace_removed"}} <- Lifecycle.reconcile(st.id),
           do: :ok

    case result do
      :ok ->
        tally(:workspace_closed, true)
        :ok

      other ->
        reason =
          case other do
            {:error, reason} -> reason
            _ -> :candidate_removal_not_observed
          end

        Lifecycle.failed(st.id, reason)
        {:error, reason}
    end
  end

  # What the model said before its first block, in a few lines.
  defp explanation(content) do
    content
    # text mode's first <edit>/<create> tag, then a SEARCH block (the fence is
    # optional, as in `Edits`: live T3 wrote `path` then SEARCH)
    |> String.split(~r/^[ \t]*<(?:edit|create)\b/m, parts: 2)
    |> hd()
    |> String.split(~r/^[^\n]*\n(?:```[^\n]*\n)?<{5,9} SEARCH/m, parts: 2)
    |> hd()
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "```")))
    |> Enum.take(-3)
    |> Enum.join(" ")
    |> String.slice(0, 500)
  end

  # The request's first line is the whole commit message: the operator's hooks (run
  # by Workspace.commit) require a bug:<id> in our repositories and cap the message at
  # 255 characters, details living in the bug. An over-long line keeps every bug:<id>
  # reference whole at the end and shortens only the prose; only when the references
  # alone leave no room for a meaningful subject is the work left uncommitted.
  @commit_limit 255

  @bug_ref ~r/\bbug:[0-9a-f]{7,64}\b/

  @doc false
  def commit_message(request) do
    line = request |> String.trim() |> String.split("\n", parts: 2) |> hd() |> String.trim()

    if byte_size(line) <= @commit_limit do
      {:ok, line}
    else
      refs = @bug_ref |> Regex.scan(line) |> List.flatten() |> Enum.uniq()
      suffix = Enum.map_join(refs, "", &(" " <> &1))
      prose = @bug_ref |> Regex.replace(line, "") |> String.split() |> Enum.join(" ")
      room = @commit_limit - byte_size(suffix) - byte_size("...")

      if room < 40 do
        {:error, "the request's first line is over #{@commit_limit} characters"}
      else
        {:ok, fit_bytes(prose, room) <> "..." <> suffix}
      end
    end
  end

  defp fit_bytes(text, room) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn g, acc ->
      if byte_size(acc) + byte_size(g) <= room, do: {:cont, acc <> g}, else: {:halt, acc}
    end)
    |> String.trim_trailing()
  end
end
