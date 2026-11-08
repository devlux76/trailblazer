defmodule Trailblazer.Loop.Tools.Native do
  @moduledoc "Native tool-call syntaxes some models answer in: edit(...) calls and arg_key/arg_value calls."

  alias Trailblazer.Loop.Tools.Blocks
  alias Trailblazer.Loop.Tools.Tags

  ## The model's native call syntax (text mode)
  #
  # LFM models answer in their own tool-call form even when told to write
  # tags (seen live 2026-11-06):
  #
  #     <|tool_call_start|>[edit(path='a.ts', start='7', end='9', replace='x\ny')]<|tool_call_end|>
  #
  # Read as range blocks: string values are Python literals (quotes and
  # backslash escapes), numbers may be bare or quoted; first/last optional.
  @doc false
  def native_edit_blocks(text) do
    calls =
      ~r/<\|tool_call_start\|>(.*?)(?:<\|tool_call_end\|>|\z)/s
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.flat_map(fn [inner] -> native_calls(inner) end)

    case calls do
      [] ->
        {:error,
         "the tool call holds no edit(path=..., start=..., end=..., replace=...); write <edit> blocks in plain text"}

      calls ->
        Enum.reduce_while(calls, {:ok, []}, fn args, {:ok, acc} ->
          case native_block(args) do
            {:ok, block} -> {:cont, {:ok, acc ++ [block]}}
            error -> {:halt, error}
          end
        end)
    end
  end

  @doc """
  Native edit calls the server lifted into tool_calls: each argument object
  (a map or its JSON) read like the text form's `edit(...)`; numbers may be
  integers there. `{:error, _}` when any is not a complete range edit.
  """
  def native_call_blocks(arguments) when is_list(arguments) do
    Enum.reduce_while(arguments, {:ok, []}, fn args, {:ok, acc} ->
      with {:ok, %{} = map} <- Blocks.decode(args),
           {:ok, block} <- native_block(stringify_numbers(map)) do
        {:cont, {:ok, acc ++ [block]}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, "edit arguments must be an object"}}
      end
    end)
  end

  defp stringify_numbers(map),
    do: Map.new(map, fn {k, v} -> {k, if(is_integer(v), do: Integer.to_string(v), else: v)} end)

  # Spark-family native calls (lucet-coder, live 2026-11-06), raw values:
  #   <tool_call>edit<arg_key>path</arg_key><arg_value>a.ts</arg_value>...</tool_call>
  @doc false
  def argkey_edit_blocks(text) do
    ~r/<tool_call>\s*(?:edit|submit_edits)\s*(.*?)<\/tool_call>/s
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(&argkey_args/1)
    |> case do
      [] ->
        {:error,
         "a <tool_call> edit was not closed with </tool_call>; write <edit> blocks in plain text"}

      calls ->
        native_call_blocks(calls)
    end
  end

  # One call's arguments, read leniently: <arg_key>/<arg_value> pairs, plus
  # key="value" attributes (live, lucet 2026-11-06 mixed the two:
  # `<tool_call>edit path="a" start="7" end="9" replace</arg_key><arg_value>...`);
  # a replace with no key of its own is the last <arg_value>.
  defp argkey_args([inner]) do
    pairs =
      ~r/<arg_key>(.*?)<\/arg_key>\s*<arg_value>(.*?)<\/arg_value>/s
      |> Regex.scan(inner, capture: :all_but_first)
      |> Map.new(fn [k, v] -> {String.trim(k), v} end)

    head = inner |> String.split(~r/<arg_(?:key|value)>/, parts: 2) |> hd()
    attrs = Tags.attrs(head)

    values = Regex.scan(~r/<arg_value>(.*?)<\/arg_value>/s, inner, capture: :all_but_first)

    args = Map.merge(attrs, pairs)

    if Map.has_key?(args, "replace") or values == [],
      do: args,
      else: Map.put(args, "replace", values |> List.last() |> hd())
  end

  defp native_calls(inner) do
    case :binary.match(inner, "edit(") do
      :nomatch ->
        []

      {at, len} ->
        rest = binary_part(inner, at + len, byte_size(inner) - at - len)

        case native_args(rest, %{}) do
          {:ok, args, tail} -> [args | native_calls(tail)]
          :error -> []
        end
    end
  end

  defp native_args(text, acc) do
    text = String.trim_leading(text)

    cond do
      String.starts_with?(text, ")") ->
        {:ok, acc, binary_part(text, 1, byte_size(text) - 1)}

      String.starts_with?(text, ",") ->
        native_args(binary_part(text, 1, byte_size(text) - 1), acc)

      true ->
        with [_, key, after_eq] <- Regex.run(~r/\A(\w+)\s*=\s*(.*)\z/s, text),
             {:ok, value, rest} <- native_value(after_eq) do
          native_args(rest, Map.put(acc, key, value))
        else
          _ -> :error
        end
    end
  end

  defp native_value(<<q, rest::binary>>) when q in [?', ?"], do: native_string(rest, q, [])

  defp native_value(text) do
    case Regex.run(~r/\A(-?\d+)(.*)\z/s, text) do
      [_, n, rest] -> {:ok, n, rest}
      _ -> :error
    end
  end

  defp native_string(<<>>, _q, _acc), do: :error

  defp native_string(<<?\\, c, rest::binary>>, q, acc) do
    ch =
      case c do
        ?n -> "\n"
        ?t -> "\t"
        ?r -> "\r"
        other -> <<other>>
      end

    native_string(rest, q, [ch | acc])
  end

  defp native_string(<<c, rest::binary>>, q, acc) when c == q,
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp native_string(<<c, rest::binary>>, q, acc), do: native_string(rest, q, [<<c>> | acc])

  defp native_block(%{"path" => path} = args) when path != "" do
    with {:ok, start} <- Tags.tag_int(args, "start", 1),
         {:ok, last} <- Tags.tag_int(args, "end", 0),
         replace when is_binary(replace) <- Map.get(args, "replace") do
      replace =
        if replace == "" or String.ends_with?(replace, "\n"), do: replace, else: replace <> "\n"

      {:ok,
       %{
         path: path,
         digest: nil,
         start: start,
         end: last,
         first: args["first"] && anchor(args["first"]),
         last: args["last"] && anchor(args["last"]),
         replace: replace,
         type: :range
       }}
    else
      nil -> {:error, "#{path}: edit(...) needs replace='the new lines'"}
      error -> error
    end
  end

  defp native_block(_args), do: {:error, "edit(...) needs path='...', start=N, end=M"}

  # One quoted line; a copied "12| " number prefix from the numbered source is
  # not part of it.
  @doc false
  def anchor(text),
    do: text |> String.replace(~r/\A[\r\n]+|[\r\n]+\z/, "") |> String.replace(~r/\A\d+\| ?/, "")
end
