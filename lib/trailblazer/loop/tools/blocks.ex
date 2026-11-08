defmodule Trailblazer.Loop.Tools.Blocks do
  @moduledoc "Decoding of edit tool arguments (submit_edits, edit) and JSON blocks into edit blocks."

  @hex64 ~r/\A[0-9a-f]{64}\z/

  @doc "Blocks of one edit-tool call: `submit_edits` (a batch) or `edit` (one block)."
  def edit_call_blocks("submit_edits", arguments), do: edit_blocks(arguments)

  def edit_call_blocks("edit", arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, %{} = block} ->
        case edit_blocks(Jason.encode!(%{blocks: [block]})) do
          {:ok, blocks} ->
            {:ok, blocks}

          {:error, _} ->
            {:error,
             "edit needs exactly path, search and replace as strings (path non-empty; empty search only creates a file)"}
        end

      _ ->
        {:error, "edit arguments must be a JSON object {path, search, replace}"}
    end
  end

  def edit_call_blocks(_name, _arguments), do: {:error, "not an edit tool"}

  @doc """
  Validates model arguments before the existing all-or-nothing edit application.

  `opts[:mode] == :text` is the plain-text coder's dialect: a range block may
  leave out `sha256` (a small model copying 64 hex characters makes them up;
  the first/last quotes already catch a stale or miscounted range), and a
  `{path, search, replace}` block is accepted only with an empty search, to
  create a file. Its refusals name the exact problem.
  """
  def edit_blocks(arguments, opts \\ [])

  def edit_blocks(arguments, opts) when is_binary(arguments) do
    mode = Keyword.get(opts, :mode)

    with {:ok, %{"blocks" => [_ | _] = blocks} = args} when map_size(args) == 1 <-
           Jason.decode(arguments),
         {:ok, decoded} <- decode_blocks(blocks, mode) do
      {:ok, decoded}
    else
      {:error, message} when is_binary(message) and mode == :text ->
        {:error, message}

      _ when mode == :text ->
        {:error,
         "the edits must be one JSON array of blocks: range blocks " <>
           "{path, start, end, first, last, replace} and, to create a file, {path, search: \"\", replace}"}

      _ ->
        {:error,
         "submit_edits requires a nonempty blocks array; each block is either " <>
           "{path, search, replace} strings, or a range block {path, sha256, start, end, first, last, replace} " <>
           "with a lowercase 64-hex sha256, integer line numbers and the quoted text of lines start and end"}
    end
  end

  def edit_blocks(_, _opts), do: {:error, "submit_edits arguments must be JSON"}

  defp decode_blocks(blocks, mode) do
    blocks
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, acc} ->
      case decode_block(block, mode) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp decode_block(%{"path" => path, "search" => search, "replace" => replace} = block, mode)
       when map_size(block) == 3 do
    cond do
      not (is_binary(path) and path != "" and is_binary(search) and is_binary(replace)) ->
        {:error, "legacy block needs a non-empty path and string search/replace"}

      mode == :text and search != "" ->
        {:error,
         "#{path}: a {path, search, replace} block only creates a new file (empty search); " <>
           "change an existing file with a range block {path, start, end, first, last, replace}"}

      true ->
        {:ok, %{path: path, search: search, replace: replace}}
    end
  end

  # Text mode: the same range block without sha256 (see edit_blocks/2).
  defp decode_block(%{"start" => _, "first" => _, "last" => _} = block, :text)
       when map_size(block) == 6 and not is_map_key(block, "sha256") do
    decode_block(Map.put(block, "sha256", nil), :text)
  end

  defp decode_block(
         %{
           "path" => path,
           "sha256" => sha256,
           "start" => start,
           "end" => last,
           "first" => first_text,
           "last" => last_text,
           "replace" => replace
         } = block,
         mode
       )
       when map_size(block) == 7 do
    cond do
      not (is_binary(path) and path != "") ->
        {:error, "range block needs a non-empty path"}

      not ((mode == :text and is_nil(sha256)) or
               (is_binary(sha256) and Regex.match?(@hex64, sha256))) ->
        {:error, "range block sha256 must be a lowercase 64-hex string"}

      not (is_integer(start) and start >= 1) ->
        {:error, "range block start must be an integer >= 1"}

      not (is_integer(last) and last >= 0) ->
        {:error, "range block end must be an integer >= 0"}

      not is_binary(replace) ->
        {:error, "range block replace must be a string"}

      not (is_binary(first_text) and is_binary(last_text)) ->
        {:error, "range block first and last must quote the current text of lines start and end"}

      true ->
        {:ok,
         %{
           path: path,
           digest: sha256,
           start: start,
           end: last,
           first: first_text,
           last: last_text,
           replace: replace,
           type: :range
         }}
    end
  end

  defp decode_block(_block, :text),
    do:
      {:error,
       "each block must be exactly a range block {path, start, end, first, last, replace} " <>
         "(sha256 optional) or, to create a file, {path, search: \"\", replace}"}

  defp decode_block(_block, _mode),
    do:
      {:error,
       "each block must be exactly {path, search, replace} or {path, sha256, start, end, first, last, replace}"}

  @doc false
  def json_edit_blocks(text, opts) do
    text = String.trim(text)
    text_mode? = Keyword.get(opts, :mode) == :text
    structured? = String.starts_with?(text, ["[", "{", "```json", "```JSON"])

    payload =
      case Regex.run(~r/\A```json[ \t]*\R([\s\S]*)\R```\z/i, text) do
        [_, json] -> json
        _ -> text
      end

    {structured?, payload} =
      case {structured?,
            text_mode? && Regex.run(~r/^```json[ \t]*\R([\s\S]*?)\R```[ \t]*$/im, text)} do
        {false, [_, json]} -> {true, json}
        _ -> {structured?, payload}
      end

    if structured? do
      case Jason.decode(payload) do
        {:ok, blocks} when is_list(blocks) -> edit_blocks(Jason.encode!(%{blocks: blocks}), opts)
        {:ok, args} when is_map(args) -> edit_blocks(Jason.encode!(args), opts)
        _ -> {:error, "structured edits must be one complete JSON array or blocks object"}
      end
    else
      :none
    end
  end

  @doc false
  def decode(%{} = args), do: {:ok, args}

  def decode(text) when is_binary(text) do
    case Jason.decode(if(String.trim(text) == "", do: "{}", else: text)) do
      {:ok, %{} = args} -> {:ok, args}
      {:ok, _other} -> {:error, "arguments must be a JSON object"}
      {:error, e} -> {:error, "arguments are not valid JSON (#{Exception.message(e)})"}
    end
  end

  def decode(_other), do: {:error, "arguments must be a JSON object"}
end
