defmodule Trailblazer.Loop.Chat do
  @moduledoc "One model call: prefill handling, the embedding gate, the request options and the reply's outcome."

  alias Trailblazer.{Config, EmbedGate, Model}
  alias Trailblazer.Loop.{EditBlocks, Outcome, Streams, Tools}

  import Trailblazer.Loop.Ledger,
    only: [
      tally: 1,
      tally: 2,
      mod: 3,
      record: 3,
      budget_remaining!: 0,
      describe: 1,
      submit_how: 1
    ]

  defp think_prefill(%{think: think}, messages, :coder) when is_binary(think) do
    if Enum.any?(messages, &(&1[:role] == "assistant")),
      do: "<think></think>",
      else: "<think>" <> think <> "</think>"
  end

  defp think_prefill(_, _, _), do: nil

  # The server may echo the prefill at the head of the content.
  defp unprefill(reply, prefill) do
    content = reply.content || ""

    content =
      if String.starts_with?(content, prefill),
        do: String.trim_leading(String.replace_prefix(content, prefill, "")),
        else: content

    Map.merge(reply, %{content: content, prefill: prefill})
  end

  # A prefilled turn goes back into history exactly as the server rendered
  # it: llama.cpp renders a final assistant prefill after an empty think
  # block (measured with LFM2.5, /apply-template), and a hybrid model's cache
  # cannot rewind to a divergence, so any other history text re-reads the
  # whole prompt on the next call (5.5 minutes on the CPU).
  @doc false
  def assistant_message(reply) do
    prefill =
      case Map.get(reply, :prefill) do
        nil -> ""
        prefill -> "<think></think>" <> prefill
      end

    %{
      role: "assistant",
      content: prefill <> (reply.content || ""),
      tool_calls:
        Enum.map(reply.tool_calls, fn call ->
          %{
            id: call.id,
            type: "function",
            function: %{name: call.name, arguments: call.arguments}
          }
        end)
    }
  end

  @doc false
  def chat(st, messages, tools, role, submit_only) do
    # The pinned server's required choice allows any advertised tool. Remove
    # reading tools when the host no longer permits them, including corrections.
    tools =
      if submit_only,
        do: Enum.filter(tools, &(&1.function.name in Tools.edit_tools())),
        else: tools

    # A think-prefill coder (code_think_prefill): its reply is prefilled with a
    # closed think block, the trail and history on the attempt's first call,
    # empty after, so it answers at once instead of deliberating for the
    # whole window. The echo is stripped from the reply's content and kept
    # in the history the next call sends.
    # Never with a forced tool choice: llama.cpp's forced grammar after a
    # prefill is the sampler setup that refused a schema (HTTP 400).
    prefill = unless submit_only, do: think_prefill(st, messages, role)

    messages =
      if prefill, do: messages ++ [%{role: "assistant", content: prefill}], else: messages

    record(st, :prompt, %{role: role, messages: messages, tools: tools != nil})

    # a call that fails part way keeps what it had (E5)
    partial = fn reply -> record(st, :reply, Map.merge(reply, %{role: role, partial: true})) end

    # a coder call after the first (a retry, a tool round) extends a prompt the
    # model server has seen, so its prefix should come from the cache (E25)
    expect_cache? = role == :coder and tally(:coder_calls) > 0
    if role == :coder, do: tally(:coder_calls, tally(:coder_calls) + 1)

    opts = [
      on_partial: partial,
      on_delta: Streams.stream_log(st, role),
      on_progress: Streams.progress_log(st, role, expect_cache?)
    ]

    opts = opts ++ if(tools, do: [tools: tools], else: [])

    opts =
      if role == :coder and st.task.edit_mode == :text,
        do: opts ++ [stop_when: &EditBlocks.looping_blocks?/1],
        else: opts

    opts =
      if submit_only,
        do: opts ++ [tool_choice: "required"],
        else: opts

    opts =
      if is_nil(st.task.reasoning_budget_tokens),
        do: opts,
        else: opts ++ [reasoning_budget_tokens: st.task.reasoning_budget_tokens]

    role_opts =
      case role do
        :reviewer ->
          [
            model: Config.get(:review_model),
            model_url: Config.get(:review_model_url),
            backstop_ms: Config.get(:review_backstop_ms),
            backstop_kind: :review_call,
            role: :reviewer,
            sampling: Config.get(:review_model_sampling)
          ]

        _ ->
          [sampling: Config.get(:code_model_sampling)]
      end
      |> Enum.reject(&match?({:sampling, nil}, &1))

    opts = role_opts ++ opts
    opts = opts ++ Keyword.get(st.opts, :model_opts, [])

    result =
      with_gate(st, fn ->
        remaining = budget_remaining!()
        timeout = min(remaining, opts[:backstop_ms] || Config.get(:backstop_model_ms))
        mod(st, :model, Model).chat(messages, Keyword.put(opts, :backstop_ms, timeout))
      end)

    result =
      case result do
        {:ok, reply} when is_binary(prefill) -> {:ok, unprefill(reply, prefill)}
        other -> other
      end

    # Preserve a complete late reply too; a deadline never erases work.
    case result do
      {:ok, reply} -> record(st, :reply, Map.put(reply, :role, role))
      _ -> :ok
    end

    tally(:model_calls, tally(:model_calls) + 1)

    case result do
      {:ok, reply} ->
        usage = Map.get(reply, :usage) || %{}
        tally(:prompt_tokens, tally(:prompt_tokens) + (usage[:prompt_tokens] || 0))
        tally(:completion_tokens, tally(:completion_tokens) + (usage[:completion_tokens] || 0))

      _ ->
        :ok
    end

    budget_remaining!()

    case result do
      {:ok, reply} ->
        {:ok, reply}

      {:error, reason} when role == :reviewer ->
        record(st, :error, %{stage: :reviewer, reason: reason})
        {:review_error, reason}

      {:error, :model_down} ->
        record(st, :error, %{stage: role, reason: :model_down})
        {:stop, Outcome.report(st, :failed, "The code model is not running.")}

      {:error, :output_limit} ->
        record(st, :error, %{stage: role, reason: :output_limit})

        {:stop,
         Outcome.report(
           st,
           :failed,
           "The #{role} exhausted its output budget before submitting an answer. Replan the budget before another attempt."
         )}

      {:error, {:http, status}} ->
        record(st, :error, %{stage: role, reason: {:http, status}})
        {:stop, Outcome.report(st, :failed, "The code model answered HTTP #{status}.")}

      {:error, reason} ->
        record(st, :error, %{stage: role, reason: reason})

        {:retry, {:model, reason},
         "Your last reply was not usable (#{describe(reason)}). Answer more briefly and submit the changes #{submit_how(st)}."}
    end
  end

  defp with_gate(st, fun) do
    case Keyword.get(
           st.opts,
           :gate,
           {fn -> EmbedGate.hold(EmbedGate, budget_remaining!()) end, &EmbedGate.release/0}
         ) do
      false ->
        fun.()

      {hold, release} ->
        case hold.() do
          :ok ->
            :ok

          {:error, :timeout} ->
            {phase, _} = tally(:phase)
            throw({:budget_expired, phase})
        end

        try do
          fun.()
        after
          release.()
        end
    end
  end
end
