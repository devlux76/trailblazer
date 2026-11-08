defmodule Trailblazer.Loop.Coder do
  @moduledoc "The coder's first call, and the replay of a recorded reply."

  alias Trailblazer.{Config}

  alias Trailblazer.Loop.{
    CaseRecord,
    Context,
    Conversation,
    Edits,
    Outcome,
    Prompts,
    TextAnswers,
    Tools
  }

  import Trailblazer.Loop.Ledger, only: [record: 3]

  @doc false
  def coder_reply(%{task: %{replay_reply_from: id}} = st, _trail, _files, _feedback)
      when is_binary(id) do
    with %{status: "failed"} = source <- CaseRecord.get(id),
         true <- source.repo == st.task.repo and source.task["check"] == st.task.check,
         true <- (source.task["from"] || "cli") == st.task.from,
         true <- source.task["artifacts"] == st.task.artifacts,
         %{} = ws <-
           Enum.find(source.events, &(&1.kind == "attempt" and &1.data["stage"] == "workspace")),
         true <- ws.data["base"] == st.ws.base,
         %{} = edit <- Enum.find(Enum.reverse(source.events), &(&1.kind == "edit")),
         true <- edit.data["status"] in ["no_blocks", "unparsed"],
         %{} = event <-
           Enum.find(
             Enum.reverse(source.events),
             &(&1.kind == "reply" and &1.data["role"] == "coder")
           ),
         true <- event.data["finish_reason"] == "stop" and event.data["partial"] != true,
         true <- Map.get(event.data, "tool_calls", []) == [],
         {:ok, edits} <- replay_blocks(event.data["content"]) do
      reply = %{
        content: event.data["content"],
        reasoning: "",
        tool_calls: [],
        edit_blocks: edits,
        finish_reason: "stop",
        usage: %{prompt_tokens: 0, completion_tokens: 0},
        ms: 0,
        replayed_from: id,
        source_reply_seq: event.seq,
        source_reply_sha256:
          :crypto.hash(:sha256, event.data["content"]) |> Base.encode16(case: :lower)
      }

      record(st, :reply, Map.put(reply, :role, :coder))
      {:ok, reply}
    else
      _ ->
        record(st, :error, %{stage: :replay_reply, source: id, reason: :incompatible_source})

        {:stop,
         Outcome.report(
           st,
           :failed,
           "The recorded reply cannot be replayed for this peer, repository, check, base or response format."
         )}
    end
  end

  def coder_reply(st, trail, files, feedback) do
    head = Map.get(st, :head, %{})

    head =
      if st.task.edit_mode == :text, do: Map.put(head, :sources, Context.sources(st)), else: head

    head =
      if TextAnswers.whole_file?(st.task),
        do: Map.merge(head, %{whole: true, usages: TextAnswers.usages(st.ws.path, st.task)}),
        else: head

    think? = Config.get(:code_think_prefill) == true
    messages = Prompts.coder(st.task, trail, files, feedback, Map.put(head, :think, think?))

    st =
      if think?,
        do: Map.put(st, :think, Prompts.coder_think(trail, head[:examples])),
        else: st

    record(st, :attempt, %{stage: :prompt_size, bytes: Context.prompt_sizes(messages)})

    format =
      if st.task.read_rounds > 0 and st.task.files != [] and
           Enum.all?(files, fn {_, size} -> size != :missing end),
         do: :ranges,
         else: :both

    {format, tools} =
      if st.task.edit_mode == :text,
        do: {:text, Tools.definitions()},
        else:
          {format,
           Tools.definitions() ++ [Tools.edit_definition(format), Tools.flat_edit_definition()]}

    record(st, :attempt, %{stage: :edit_format, format: format})
    Conversation.converse(st, messages, tools, :coder)
  end

  # A recorded unparsed reply: <edit>/<create> tags, else JSON text, else
  # SEARCH/REPLACE text; whatever was valid when it was recorded.
  defp replay_blocks(content) do
    opts = if Regex.match?(~r/<(?:edit|create)\b/, content), do: [mode: :text], else: []

    case Tools.text_edit_blocks(content, opts) do
      :none ->
        case Edits.parse(content) do
          {:ok, [_ | _] = blocks} -> {:ok, blocks}
          _ -> :error
        end

      other ->
        other
    end
  end
end
