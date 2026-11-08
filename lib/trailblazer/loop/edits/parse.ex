defmodule Trailblazer.Loop.Edits.Parse do
  @moduledoc "SEARCH/REPLACE block parsing: the model reply to edit blocks, with Aider-style filename recovery."

  alias Trailblazer.Loop.Edits

  @head ~r/^<{5,9} SEARCH>?\s*$/
  @divider ~r/^={5,9}\s*$/
  @updated ~r/^>{5,9} REPLACE\s*$/
  @fence "```"

  ## Parsing

  @doc "The edit blocks of a model's reply, in order."
  @spec parse(String.t()) :: {:ok, [Edits.block()]} | {:error, String.t()}
  def parse(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> blocks([], nil, [])
  end

  defp blocks([], acc, _current, _seen), do: {:ok, Enum.reverse(acc)}

  defp blocks([line | rest] = lines, acc, current, seen) do
    if Regex.match?(@head, String.trim(line)) do
      new_file? =
        match?([next | _] when is_binary(next), rest) and
          Regex.match?(@divider, String.trim(hd(rest)))

      case find_filename(Enum.take(seen, 3), new_file?) || current do
        nil ->
          {:error,
           error(
             seen,
             line,
             "Bad/missing filename. The filename must be alone on the line before the opening fence #{@fence}"
           )}

        path ->
          with {:ok, search, rest} <- until(rest, [@divider], "=======", seen, line),
               {:ok, replace, rest} <-
                 until(rest, [@updated, @divider], ">>>>>>> REPLACE", seen, line) do
            block = %{path: path, search: joined(search), replace: joined(replace)}
            blocks(rest, [block | acc], path, [])
          end
      end
    else
      blocks(tl(lines), acc, current, [line | seen])
    end
  end

  # The lines up to a marker, and what follows the marker.
  defp until(lines, markers, expected, seen, head) do
    {taken, rest} =
      Enum.split_while(lines, fn l ->
        not Enum.any?(markers, &Regex.match?(&1, String.trim(l)))
      end)

    case rest do
      [_marker | after_marker] -> {:ok, taken, after_marker}
      [] -> {:error, error(seen, head, "Expected `#{expected}`")}
    end
  end

  defp joined([]), do: ""
  defp joined(lines), do: Enum.join(lines, "\n") <> "\n"

  defp error(seen, line, message) do
    context = seen |> Enum.take(3) |> Enum.reverse() |> Enum.concat([line]) |> Enum.join("\n")
    "#{context}\n^^^ #{message}"
  end

  # Aider's find_filename/strip_filename: the nearest of the three lines before
  # the block that names a file, looking past fence lines.
  defp find_filename(previous, _new_file?) do
    previous
    |> Enum.reduce_while([], fn line, found ->
      found = if name = strip_filename(line), do: [name | found], else: found
      fence? = String.starts_with?(line, @fence)
      if fence?, do: {:cont, found}, else: {:halt, found}
    end)
    |> Enum.reverse()
    |> case do
      [] -> nil
      names -> Enum.find(names, &String.contains?(&1, ".")) || hd(names)
    end
  end

  defp strip_filename(line) do
    line = String.trim(line)

    cond do
      line == "" or line == "..." ->
        nil

      String.starts_with?(line, @fence) ->
        candidate = String.slice(line, 3..-1//1)
        if candidate != "" and String.contains?(candidate, [".", "/"]), do: candidate

      true ->
        name =
          line
          |> String.trim_trailing(":")
          |> String.trim_leading("#")
          |> String.trim()
          |> String.trim("`")
          |> String.trim("*")

        if name == "", do: nil, else: name
    end
  end
end
