defmodule Trailblazer.Loop.Conversation do
  @moduledoc "The coder's conversation: reads, submissions, edit corrections and the batch of edits."

  alias Trailblazer.{Backstop}
  alias Trailblazer.Loop.{Chat, Edits, Outcome, TextAnswers, Tools}

  import Trailblazer.Loop.Ledger,
    only: [
      tally: 2,
      served_reads: 0,
      mod: 3,
      query_opts: 1,
      record: 3,
      budget_remaining!: 0,
      tracked: 1
    ]

  # One exchange: the task may reduce the default reading budget,
  # then must submit edits through the remaining edit tool.
  @doc false
  def converse(st, messages, tools, role, round \\ 1, corrections \\ 0)

  # Text mode: once reading ends the coder answers in plain text, so the
  # final call offers no tools; its <edit>/<create> reply is parsed by EditBlocks.blocks/2.
  def converse(%{task: %{edit_mode: :text}} = st, messages, tools, :coder, round, corrections)
      when tools != nil and round > st.task.read_rounds do
    messages =
      messages ++
        [
          %{
            role: "user",
            content:
              if(TextAnswers.whole_file?(st.task),
                do:
                  "Reading is complete. Reply now with each changed file written out complete (its path on a line, then one fenced block); call no tool.",
                else:
                  "Reading is complete. Reply now with the complete change as <edit>/<create> blocks only; call no tool."
              )
          }
        ]

    converse(st, messages, nil, :coder, round, corrections)
  end

  def converse(st, messages, tools, role, round, corrections) do
    submit_only = tools != nil and (round > st.task.read_rounds or corrections > 0)

    messages =
      if submit_only and corrections == 0 do
        messages ++
          [
            %{
              role: "user",
              content:
                "Reading is complete. Call submit_edits or edit alone with the complete batch. No more read or search calls."
            }
          ]
      else
        messages
      end

    case Chat.chat(st, messages, tools, role, submit_only) do
      # No tools offered, yet the server lifts a native edit(...) call (LFM2.5, live)
      {:ok, %{tool_calls: [_ | _] = calls} = reply}
      when tools == nil and st.task.edit_mode == :text ->
        lifted_edits(st, reply, calls)

      {:ok, %{tool_calls: [_ | _] = calls} = reply} when tools != nil ->
        submissions =
          if st.task.edit_mode == :text,
            do: [],
            else: Enum.filter(calls, &(&1.name in Tools.edit_tools()))

        # Text mode: the server may lift the model's native edit(...) call
        # into tool_calls (LFM2.5, live 2026-11-06), leaving no text to
        # parse. Read those calls as the native range blocks they are.
        text_calls =
          if st.task.edit_mode == :text and Enum.all?(calls, &(&1.name in Tools.edit_tools())),
            do: Tools.native_call_blocks(Enum.map(calls, & &1.arguments)),
            else: :none

        cond do
          match?({:ok, [_ | _]}, text_calls) ->
            record(st, :edit, %{status: :native_tool_calls, calls: length(calls)})
            {:ok, Map.put(reply, :edit_blocks, elem(text_calls, 1))}

          submissions != [] and length(submissions) == length(calls) ->
            case batch_blocks(submissions) do
              {:ok, blocks} ->
                preview_edits(st, messages, tools, role, round, reply, blocks, corrections)

              {:error, reason} ->
                correct_edits(st, messages, tools, role, round, reply, corrections, reason)
            end

          submissions != [] ->
            correct_edits(
              st,
              messages,
              tools,
              role,
              round,
              reply,
              corrections,
              "Call submit_edits or edit alone, without read/search calls, with the complete batch."
            )

          submit_only ->
            correct_edits(
              st,
              messages,
              tools,
              role,
              round,
              reply,
              corrections,
              "Reading is complete. Only submit_edits or edit may be called now."
            )

          true ->
            answers = Enum.map(calls, &answer_call(st, &1))

            converse(
              st,
              messages ++ [Chat.assistant_message(reply) | answers],
              tools,
              role,
              round + 1,
              corrections
            )
        end

      other ->
        other
    end
  end

  defp lifted_edits(st, reply, calls) do
    with true <- Enum.all?(calls, &(&1.name in Tools.edit_tools())),
         {:ok, [_ | _] = blocks} <- Tools.native_call_blocks(Enum.map(calls, & &1.arguments)) do
      record(st, :edit, %{status: :native_tool_calls, calls: length(calls)})
      {:ok, Map.put(reply, :edit_blocks, blocks)}
    else
      _ -> {:ok, reply}
    end
  end

  defp preview_edits(st, messages, tools, role, round, reply, blocks, corrections) do
    tally(:previous_edits, blocks)
    record(st, :edit, %{status: :preview, paths: Enum.map(blocks, & &1.path)})

    case Edits.apply(st.ws.path, blocks, [dry_run: true] ++ edit_options(st)) do
      {:ok, _} ->
        record(st, :edit, %{status: :preview_ok, blocks: length(blocks)})
        {:ok, Map.put(reply, :edit_blocks, blocks)}

      {:error, failures} ->
        record(st, :edit, %{
          status: :preview_missed,
          blocks: blocks,
          failures: failures,
          correction: corrections
        })

        case missing_source(st, failures) do
          [] ->
            correct_edits(
              st,
              messages,
              tools,
              role,
              round,
              reply,
              corrections,
              Edits.feedback(failures)
            )

          paths ->
            source_missing(st, paths)
        end
    end
  end

  defp correct_edits(st, messages, tools, role, round, reply, corrections, feedback) do
    answers =
      Enum.map(reply.tool_calls, fn call ->
        record(st, :tool_call, %{
          id: call.id,
          name: call.name,
          arguments: call.arguments,
          result: feedback,
          status: :refused
        })

        %{role: "tool", tool_call_id: call.id, content: feedback}
      end)

    if corrections >= 2 do
      record(st, :edit, %{status: :edit_repair_exhausted, submissions: corrections + 1})

      {:stop,
       Outcome.report(
         st,
         :failed,
         "edit_repair_exhausted: three unusable submissions; no partial batch was written. Worktree and case evidence retained.",
         %{attempts: length(st.failures) + 1, reason: :edit_repair_exhausted}
       )}
    else
      converse(
        st,
        messages ++ [Chat.assistant_message(reply) | answers],
        tools,
        role,
        round,
        corrections + 1
      )
    end
  end

  defp edit_options(st),
    do: [files: tracked(st.ws.path), shown: Map.get(st.task, :files, [])]

  defp missing_source(%{task: %{read_rounds: 0}}, failures) do
    for f <- failures,
        f.reason in [:no_such_file, :no_match] and f.closest == "",
        do: f.block.path
  end

  defp missing_source(_st, _failures), do: []

  defp source_missing(st, paths) do
    record(st, :error, %{stage: :edits, reason: :source_context_missing, paths: paths})

    {:stop,
     Outcome.report(
       st,
       :failed,
       "source_context_missing: #{Enum.join(paths, ", ")}. Supply literal current anchors or authorize reads on a fresh admission; no zero-read retry was run.",
       %{attempts: length(st.failures) + 1, reason: :source_context_missing}
     )}
  end

  # One batch from every edit-tool call of a reply, in order; any bad call
  # refuses the whole batch with its reason.
  defp batch_blocks(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      case Tools.edit_call_blocks(call.name, call.arguments) do
        {:ok, blocks} -> {:cont, {:ok, acc ++ blocks}}
        {:error, reason} -> {:halt, {:error, "#{call.name}: #{reason}"}}
      end
    end)
  end

  defp answer_call(%{task: %{edit_mode: :text}}, %{name: name} = call)
       when name in ["submit_edits", "edit"],
       do: %{
         role: "tool",
         tool_call_id: call.id,
         content:
           "error: there is no edit tool in this mode; when reading is complete, reply with <edit>/<create> blocks in plain text."
       }

  defp answer_call(st, call), do: answer_tool(st, call)

  defp answer_tool(st, call) do
    target = %{repo: st.task.repo, worktree: st.ws.path}
    remaining = budget_remaining!()

    result =
      case Backstop.guard(
             :generation_tool,
             st.id,
             {:ms, remaining},
             fn -> %{tool: call.name} end,
             fn ->
               mod(st, :tools, Tools).call(target, call.name, call.arguments, query_opts(st))
             end
           ) do
        {:ok, result} -> result
        {:error, {:backstop, _}} -> throw({:budget_expired, :generation})
        {:error, reason} -> "Tool failed: #{inspect(reason)}"
      end

    # a re-read of lines this attempt already showed is a pointer, not the text
    result =
      if call.name == "read" do
        {result, served} = Tools.dedupe_read(result, served_reads())
        tally(:served_reads, served)
        result
      else
        result
      end

    budget_remaining!()

    record(st, :tool_call, %{
      id: call.id,
      name: call.name,
      arguments: call.arguments,
      result: result
    })

    %{role: "tool", tool_call_id: call.id, content: result}
  end
end
