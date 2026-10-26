defmodule Trailblazer.Model do
  @moduledoc """
  One streaming chat call, adapted from mirai-agent's ModelClient. SSE framing
  and native tool envelopes are local copies; no Mirai runtime is needed.
  Reasoning is returned for the case record and removed from outbound messages.
  A complete reply needs a choice, finish reason and SSE DONE, not just HTTP 200.
  Generation is bounded by max_tokens, its progress limit, and by one
  backstop (design §13.2): `opts[:backstop_ms]`, else `backstop_model_ms`.
  Nothing else in a call is timed; the stream is read for as long as it
  lasts. A backstop that fires is an anomaly and gives
  `{:error, {:backstop, anomaly_id}}`; a reply that lands as it fires is
  late and is returned inside that error (J4). On a failed call,
  opts[:on_partial] receives the partial reply once before the error returns,
  so the loop can synchronously preserve content and reasoning in its record.
  opts[:on_delta] receives %{reasoning: text, content: text} with what each
  chunk of the stream added, as it arrives, so a long call can be watched.
  opts[:on_progress] receives llama.cpp's prompt progress (`total`, `cache`,
  `processed`, `time_ms`) while the prompt is read, before any token: on the
  CPU a 7k-token prompt takes ~11 minutes and would otherwise show nothing.
  """
  alias Trailblazer.{Backstop, Config}
  alias Trailblazer.Model.{SSEParser, NativeToolCalls}

  def chat(messages, opts \\ []) do
    started = now()
    partials = :ets.new(__MODULE__, [:public])

    try do
      task =
        Task.async(fn ->
          try do
            {:returned, do_chat(messages, opts, started, partials)}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end
        end)

      backstop =
        Backstop.arm(
          :model_call,
          Config.get(:code_model),
          {:ms, Keyword.get(opts, :backstop_ms, Config.get(:backstop_model_ms))},
          fn -> seen_so_far(partials, started) end
        )

      await(task, backstop, partials, opts)
    after
      :ets.delete(partials)
    end
  end

  defp await(task, backstop, partials, opts) do
    ref = task.ref

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])

        case Backstop.disarm(backstop) do
          :ok ->
            returned(result, partials, opts)

          # J4/J5: the backstop fired as the reply came; its outcome stands
          :fired ->
            receive do
              {:backstop, ^backstop, id} -> {:error, {:backstop, id, late: late(result)}}
            end
        end

      {:backstop, ^backstop, id} ->
        Task.shutdown(task, :brutal_kill)
        deliver_partial(partials, opts)
        {:error, {:backstop, id}}
    end
  end

  defp returned({:returned, result}, partials, opts) do
    if match?({:error, _}, result), do: deliver_partial(partials, opts)
    result
  end

  defp returned({:raised, kind, reason, stack}, _partials, _opts),
    do: :erlang.raise(kind, reason, stack)

  defp late({:returned, {:ok, reply}}), do: reply
  defp late(other), do: inspect(other, limit: 5)

  # what a backstop records as seen so far
  defp seen_so_far(partials, started) do
    case :ets.lookup(partials, :reply) do
      [{:reply, r}] ->
        %{
          reasoning_bytes: byte_size(r.reasoning),
          content_bytes: byte_size(r.content),
          first_token_ms: r[:first_token_ms],
          ms: now() - started
        }

      _ ->
        %{tokens: 0, ms: now() - started}
    end
  end

  defp do_chat(messages, opts, started, partials) do
    body = %{
      model: Config.get(:code_model),
      messages:
        Enum.map(
          messages,
          &Map.drop(&1, [:reasoning, :reasoning_content, "reasoning", "reasoning_content"])
        ),
      max_tokens: Config.get(:code_model_max_tokens),
      stream: true,
      stream_options: %{include_usage: true},
      return_progress: true,
      temperature: 1.0,
      top_p: 0.95,
      top_k: 0,
      min_p: 0,
      presence_penalty: 0,
      chat_template_kwargs: %{preserve_thinking: false}
    }

    body = if opts[:tools], do: Map.put(body, :tools, opts[:tools]), else: body
    request(body, opts, started, partials)
  end

  defp request(body, opts, started, partials) do
    state = %{
      parser: SSEParser.new(),
      partials: partials,
      on_delta: opts[:on_delta],
      on_progress: opts[:on_progress],
      started: started,
      token: false,
      first_token_ms: nil,
      content: "",
      reasoning: "",
      calls: %{},
      usage: %{prompt_tokens: 0, completion_tokens: 0},
      choice: false,
      finish: false,
      finish_reason: nil,
      done: false,
      error: nil,
      http_body: ""
    }

    req =
      Req.new(
        method: :post,
        url: String.trim_trailing(Config.get(:code_model_url), "/") <> "/chat/completions",
        json: body,
        into: &chunk/2,
        retry: false,
        decode_body: false,
        receive_timeout: :infinity
      )
      |> Req.merge(Keyword.get(opts, :req_options, []))
      |> Req.Request.put_private(:trailblazer_model, state)

    {req, response} = Req.Request.run_request(req)
    state = req.private.trailblazer_model

    result =
      case response do
        %Req.Response{status: 200} ->
          finish(state, now() - started)

        %Req.Response{status: 503} ->
          if String.contains?(String.downcase(state.http_body), "loading") do
            # the model is loading: the router answers no event when it is
            # ready, so this asks again, bounded by the call's backstop (the
            # one sleep design §13.6 keeps, outside the Backstop module)
            Process.sleep(500)
            request(body, opts, started, partials)
          else
            {:error, {:http, 503}}
          end

        %Req.Response{status: status} ->
          {:error, {:http, status}}

        %Req.TransportError{reason: :econnrefused} ->
          {:error, :model_down}

        %Req.TransportError{reason: reason} when reason in [:timeout, :connect_timeout] ->
          {:error, :timeout}

        error ->
          {:error, {:bad_response, {:transport, Exception.message(error)}}}
      end

    result
  end

  defp chunk({:data, bytes}, {req, resp}) do
    state = req.private.trailblazer_model

    state =
      if resp.status != 200 do
        %{state | http_body: String.slice(state.http_body <> bytes, 0, 2000)}
      else
        {frames, parser} = SSEParser.feed(state.parser, bytes)
        before = {byte_size(state.reasoning), byte_size(state.content)}
        state = Enum.reduce(frames, %{state | parser: parser}, &frame/2)
        delta(state, before)

        token? = state.content != "" or state.reasoning != "" or map_size(state.calls) > 0

        first =
          if token? and state.first_token_ms == nil,
            do: now() - state.started,
            else: state.first_token_ms

        %{state | token: token?, first_token_ms: first}
      end

    action = if state.error || state.done, do: :halt, else: :cont

    if state.content != "" or state.reasoning != "" or map_size(state.calls) > 0 do
      :ets.insert(state.partials, {:reply, reply(state, now() - state.started)})
    end

    {action, {Req.Request.put_private(req, :trailblazer_model, state), resp}}
  end

  defp delta(%{on_delta: callback} = s, {r, c}) when is_function(callback, 1) do
    reasoning = binary_part(s.reasoning, r, byte_size(s.reasoning) - r)
    content = binary_part(s.content, c, byte_size(s.content) - c)
    if reasoning != "" or content != "", do: callback.(%{reasoning: reasoning, content: content})
  end

  defp delta(_, _), do: :ok

  defp frame(_, %{error: error} = s) when not is_nil(error), do: s
  defp frame(:done, s), do: %{s | done: true}
  defp frame({:error, :protocol, _}, s), do: %{s | error: :invalid_sse}

  defp frame({:data, json}, s) do
    case Jason.decode(json) do
      {:ok, %{"choices" => choices} = data} when is_list(choices) ->
        progress(s, data["prompt_progress"])
        s = usage(s, data["usage"])
        Enum.reduce(choices, s, &choice/2)

      {:ok, %{"prompt_progress" => progress}} ->
        progress(s, progress)
        s

      _ ->
        %{s | error: :invalid_chunk}
    end
  end

  defp progress(%{on_progress: callback}, %{"total" => total, "processed" => processed} = p)
       when is_function(callback, 1) and is_integer(total) and is_integer(processed) do
    callback.(%{total: total, processed: processed, cache: p["cache"] || 0, ms: p["time_ms"]})
  end

  defp progress(_, _), do: :ok

  defp usage(s, nil), do: s

  defp usage(s, %{"prompt_tokens" => p, "completion_tokens" => c})
       when is_integer(p) and p >= 0 and is_integer(c) and c >= 0,
       do: %{s | usage: %{prompt_tokens: p, completion_tokens: c}}

  defp usage(s, _), do: %{s | error: :invalid_usage}

  defp choice(%{"delta" => delta} = choice, s) when is_map(delta) do
    s = %{
      s
      | choice: true,
        finish:
          s.finish or (is_binary(choice["finish_reason"]) and choice["finish_reason"] != ""),
        finish_reason:
          if(is_binary(choice["finish_reason"]) and choice["finish_reason"] != "",
            do: choice["finish_reason"],
            else: s.finish_reason
          )
    }

    s = append(s, :content, delta["content"])
    s = append(s, :reasoning, delta["reasoning_content"])

    case delta["tool_calls"] do
      nil -> s
      calls when is_list(calls) -> Enum.reduce(calls, s, &tool_delta/2)
      _ -> %{s | error: :invalid_tool_calls}
    end
  end

  defp choice(_, s), do: %{s | error: :invalid_choice}

  defp append(s, _, nil), do: s
  defp append(s, key, text) when is_binary(text), do: Map.update!(s, key, &(&1 <> text))
  defp append(s, _, _), do: %{s | error: :invalid_delta}

  defp tool_delta(%{"index" => index} = call, s) when is_integer(index) and index >= 0 do
    fun = Map.get(call, "function", %{})

    if is_map(fun) do
      previous = Map.get(s.calls, index, %{id: "", name: "", arguments: ""})
      fragments = %{id: call["id"], name: fun["name"], arguments: fun["arguments"]}

      if Enum.all?(fragments, fn {_, value} -> is_nil(value) or is_binary(value) end) do
        merged = Map.new(previous, fn {key, value} -> {key, value <> (fragments[key] || "")} end)
        %{s | calls: Map.put(s.calls, index, merged)}
      else
        %{s | error: :invalid_tool_delta}
      end
    else
      %{s | error: :invalid_tool_delta}
    end
  end

  defp tool_delta(_, s), do: %{s | error: :invalid_tool_delta}

  defp finish(%{error: :timeout}, _), do: {:error, :timeout}

  defp finish(%{error: error}, _) when not is_nil(error), do: {:error, {:bad_response, error}}

  defp finish(%{done: true, choice: true, finish: true} = s, ms) do
    {content, calls} = native(s.content, s.calls |> Enum.sort() |> Enum.map(&elem(&1, 1)))

    cond do
      content == "" and calls == [] ->
        {:error, {:bad_response, :no_message}}

      Enum.any?(calls, &(&1.id == "" or &1.name == "")) ->
        {:error, {:bad_response, :incomplete_tool_call}}

      true ->
        {:ok, Map.merge(reply(s, ms), %{content: content, tool_calls: calls})}
    end
  end

  defp finish(s, _),
    do:
      {:error,
       {:bad_response, %{reason: :incomplete_stream, content: s.content, reasoning: s.reasoning}}}

  defp reply(s, ms),
    do: %{
      content: s.content,
      reasoning: s.reasoning,
      tool_calls: s.calls |> Enum.sort() |> Enum.map(&elem(&1, 1)),
      usage: s.usage,
      ms: ms,
      first_token_ms: s.first_token_ms,
      finish_reason: s.finish_reason
    }

  defp deliver_partial(table, opts) do
    callback = opts[:on_partial]

    case :ets.lookup(table, :reply) do
      [{:reply, reply}] when is_function(callback, 1) ->
        callback.(reply)

      _ ->
        :ok
    end
  end

  defp native(content, []) do
    case NativeToolCalls.parse(content) do
      {:ok, calls, text} ->
        {text,
         Enum.map(calls, &%{id: &1.call_id, name: &1.name, arguments: Jason.encode!(&1.args)})}

      {:none, _} ->
        {content, []}
    end
  end

  defp native(content, calls), do: {content, calls}
  defp now, do: System.monotonic_time(:millisecond)
end
