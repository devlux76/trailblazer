# Copied from mirai-agent; kept local per docs/design-2.md §9.
defmodule Trailblazer.Model.NativeToolCalls do
  @moduledoc """
  Robust parser for LFM2.5's *native* tool-call envelope (docs/13-llm-runtime.md §13.3).

  LFM2.5-8B-A1B writes tool calls as a Pythonic list between
  `<|tool_call_start|>` and `<|tool_call_end|>` special tokens, e.g.

      <|tool_call_start|>[skill_write(name="pacing", body="---\\nname: pacing\\n...")]<|tool_call_end|>

  This is her real interface with the world, so the parser must survive
  *arbitrary* string arguments — commas, parens, brackets, newlines, quotes,
  and escapes inside a value must never break argument splitting. A naive
  regex (`[^)]*`, `[(.*?)]`, non-dotall `.`) cannot do that; this module
  uses a depth-and-quote-aware character scanner instead.

  `parse/1` returns:

    * `{:ok, calls, stripped_text}` — one or more calls were found; `calls`
      is `[%{call_id, name, args :: map}]` (same shape as the structured
      path), `stripped_text` is the text with the envelope removed.
    * `{:none, text}` — no well-formed native call; caller treats `text` as
      an ordinary assistant message. Malformed input degrades here (never
      raises), so a broken emission becomes visible text, not a crash.
  """

  @start_tok "<|tool_call_start|>"
  @end_tok "<|tool_call_end|>"

  @type call :: %{call_id: String.t(), name: String.t(), args: map()}

  @spec parse(String.t()) :: {:ok, [call()], String.t()} | {:none, String.t()}
  def parse(text) when is_binary(text) do
    with {:ok, inner} <- extract_envelope(text),
         [_ | _] = calls <- parse_calls(inner) do
      {:ok, calls, String.trim(strip_envelope(text))}
    else
      _ -> {:none, text}
    end
  end

  def parse(other), do: {:none, other}

  # ── envelope ────────────────────────────────────────────────────

  # The inner payload between the first start token and the next end token.
  # Multiline-safe (literal split, not regex `.`).
  defp extract_envelope(text) do
    with [_before, after_start] <- String.split(text, @start_tok, parts: 2),
         [inner, _after_end] <- String.split(after_start, @end_tok, parts: 2) do
      {:ok, String.trim(inner)}
    else
      _ -> :error
    end
  end

  defp strip_envelope(text) do
    case String.split(text, @start_tok, parts: 2) do
      [before, rest] ->
        case String.split(rest, @end_tok, parts: 2) do
          [_inner, tail] -> before <> tail
          _ -> before
        end

      _ ->
        text
    end
  end

  # ── call list ───────────────────────────────────────────────────

  defp parse_calls(inner) do
    inner
    |> strip_list_brackets()
    |> split_top_level(?,)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> parse_each()
  end

  # All-or-nothing: if any segment is not a well-formed call, treat the whole
  # emission as non-call text (safer than executing a half-parsed batch).
  defp parse_each(segments) do
    segments
    |> Enum.reduce_while({[], 0}, fn seg, {acc, i} ->
      case parse_one_call(seg, i) do
        {:ok, call} -> {:cont, {[call | acc], i + 1}}
        :error -> {:halt, :failed}
      end
    end)
    |> case do
      :failed -> []
      {calls, _} -> Enum.reverse(calls)
    end
  end

  # `name( ... )` — greedy `.*` with the dotall flag grabs to the LAST `)`,
  # which is this call's closing paren because the segment was already
  # isolated at top-level.
  defp parse_one_call(segment, index) do
    case Regex.run(~r/^\s*([A-Za-z_][\w.]*)\s*\((.*)\)\s*$/s, segment, capture: :all_but_first) do
      [name, args_str] ->
        {:ok, %{call_id: "txt_#{index}", name: name, args: parse_kwargs(args_str)}}

      _ ->
        :error
    end
  end

  # ── arguments ───────────────────────────────────────────────────

  defp parse_kwargs(args_str) do
    case String.trim(args_str) do
      "" ->
        %{}

      trimmed ->
        trimmed
        |> split_top_level(?,)
        |> Enum.reduce(%{}, fn pair, acc ->
          case split_kv(pair) do
            {k, v} -> Map.put(acc, k, parse_value(String.trim(v)))
            :positional -> acc
          end
        end)
    end
  end

  # Split on the FIRST top-level `=` (kwargs). Positional args (no top-level
  # `=`) are ignored — the tools are keyword-only.
  defp split_kv(pair) do
    case split_top_level_once(pair, ?=) do
      {k, v} -> {String.trim(k), v}
      :none -> :positional
    end
  end

  # ── values ──────────────────────────────────────────────────────

  defp parse_value(v) do
    cond do
      quoted?(v, ?') or quoted?(v, ?") ->
        v |> String.slice(1..-2//1) |> unescape()

      v == "True" ->
        true

      v == "False" ->
        false

      v == "None" ->
        nil

      String.starts_with?(v, "[") and String.ends_with?(v, "]") ->
        v
        |> strip_list_brackets()
        |> split_top_level(?,)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&parse_value/1)

      true ->
        parse_number(v)
    end
  end

  defp quoted?(v, q) do
    String.length(v) >= 2 and String.first(v) == <<q>> and String.last(v) == <<q>>
  end

  defp parse_number(v) do
    case Integer.parse(v) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(v) do
          {float, ""} -> float
          _ -> v
        end
    end
  end

  # Python-ish escape sequences inside a string literal.
  defp unescape(s) do
    s
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\r", "\r")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\'", "'")
    |> String.replace("\\\\", "\\")
  end

  # ── scanner ─────────────────────────────────────────────────────

  defp strip_list_brackets(s) do
    s = String.trim(s)

    if String.starts_with?(s, "[") and String.ends_with?(s, "]") and String.length(s) >= 2 do
      s |> String.slice(1..-2//1) |> String.trim()
    else
      s
    end
  end

  # Split `str` on `delim` only at bracket/paren/brace depth 0 and outside
  # single/double quotes (with backslash escapes). UTF-8 safe (codepoints).
  defp split_top_level(str, delim) do
    {parts, cur, _state} =
      str
      |> String.to_charlist()
      |> Enum.reduce({[], [], %{depth: 0, quote: nil, esc: false}}, fn ch, {parts, cur, st} ->
        scan(ch, delim, parts, cur, st)
      end)

    [Enum.reverse(cur) | parts]
    |> Enum.reverse()
    |> Enum.map(&List.to_string/1)
  end

  # Split on the FIRST top-level occurrence of `delim`. Returns {before, after}
  # or :none.
  defp split_top_level_once(str, delim) do
    do_split_once(String.to_charlist(str), delim, [], %{depth: 0, quote: nil, esc: false})
  end

  defp do_split_once([], _delim, _acc, _st), do: :none

  defp do_split_once([ch | rest], delim, acc, st) do
    cond do
      st.esc ->
        do_split_once(rest, delim, [ch | acc], %{st | esc: false})

      st.quote != nil ->
        st = quote_state(ch, st)
        do_split_once(rest, delim, [ch | acc], st)

      ch in [?', ?"] ->
        do_split_once(rest, delim, [ch | acc], %{st | quote: ch})

      ch in [?(, ?[, ?{] ->
        do_split_once(rest, delim, [ch | acc], %{st | depth: st.depth + 1})

      ch in [?), ?], ?}] ->
        do_split_once(rest, delim, [ch | acc], %{st | depth: st.depth - 1})

      ch == delim and st.depth == 0 ->
        {acc |> Enum.reverse() |> List.to_string(), List.to_string(rest)}

      true ->
        do_split_once(rest, delim, [ch | acc], st)
    end
  end

  defp scan(ch, delim, parts, cur, st) do
    cond do
      st.esc ->
        {parts, [ch | cur], %{st | esc: false}}

      st.quote != nil ->
        {parts, [ch | cur], quote_state(ch, st)}

      ch in [?', ?"] ->
        {parts, [ch | cur], %{st | quote: ch}}

      ch in [?(, ?[, ?{] ->
        {parts, [ch | cur], %{st | depth: st.depth + 1}}

      ch in [?), ?], ?}] ->
        {parts, [ch | cur], %{st | depth: max(st.depth - 1, 0)}}

      ch == delim and st.depth == 0 ->
        {[Enum.reverse(cur) | parts], [], st}

      true ->
        {parts, [ch | cur], st}
    end
  end

  # Inside a quote: a backslash starts an escape; the matching quote closes.
  defp quote_state(?\\, st), do: %{st | esc: true}
  defp quote_state(ch, %{quote: q} = st) when ch == q, do: %{st | quote: nil}
  defp quote_state(_ch, st), do: st
end
