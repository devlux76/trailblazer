defmodule Trailblazer.Loop.Edits.Matching do
  @moduledoc "Chunk matching of a SEARCH text in a file (Aider replace_most_similar_chunk)."

  defp ensure_newline(""), do: ""
  defp ensure_newline(text), do: if(String.ends_with?(text, "\n"), do: text, else: text <> "\n")

  ## Matching (Aider's replace_most_similar_chunk)

  @doc false
  def replace_most_similar_chunk(whole, part, replace) do
    {whole, whole_lines} = prep(whole)
    {part, part_lines} = prep(part)
    {replace, replace_lines} = prep(replace)

    perfect_or_whitespace(whole_lines, part_lines, replace_lines) ||
      ((length(part_lines) > 2 and String.trim(hd(part_lines)) == "") &&
         perfect_or_whitespace(whole_lines, tl(part_lines), replace_lines)) ||
      trailing_tolerant(whole_lines, part_lines, replace_lines) ||
      try_dotdotdots(whole, part, replace)
  end

  # Not in Aider: trailing spaces the model dropped (or added) still match.
  # Lines are compared without them, and the result is spliced into the file
  # as it was, so the lines the block does not touch keep theirs (Codex's
  # review of L2: the plan promised this and the port had only leading).
  defp trailing_tolerant(whole_lines, part_lines, replace_lines) do
    bare = fn lines -> Enum.map(lines, &(String.trim_trailing(&1) <> "\n")) end
    perfect_or_whitespace(bare.(whole_lines), bare.(part_lines), replace_lines, whole_lines)
  end

  defp prep(text) do
    text = ensure_newline(text)
    {text, lines_keeping_ends(text)}
  end

  defp lines_keeping_ends(""), do: []

  defp lines_keeping_ends(text) do
    text |> String.split(~r/(?<=\n)/) |> Enum.reject(&(&1 == ""))
  end

  # `whole_lines` are matched against; the result is spliced into `out_lines`,
  # the same lines as they are in the file (they differ in trailing_tolerant).
  defp perfect_or_whitespace(whole_lines, part_lines, replace_lines, out_lines \\ nil) do
    out_lines = out_lines || whole_lines

    perfect_replace(whole_lines, part_lines, replace_lines, out_lines) ||
      replace_part_with_missing_leading_whitespace(
        whole_lines,
        part_lines,
        replace_lines,
        out_lines
      )
  end

  defp splice(out_lines, i, n, replaced),
    do: Enum.join(Enum.take(out_lines, i) ++ replaced ++ Enum.drop(out_lines, i + n))

  defp perfect_replace(_whole, [], _replace, _out), do: nil

  defp perfect_replace(whole_lines, part_lines, replace_lines, out_lines) do
    n = length(part_lines)

    matches =
      0..max(length(whole_lines) - n, -1)//1
      |> Stream.filter(&(Enum.slice(whole_lines, &1, n) == part_lines))
      |> Enum.take(2)

    case matches do
      [i] -> splice(out_lines, i, n, replace_lines)
      _ -> nil
    end
  end

  defp replace_part_with_missing_leading_whitespace(_whole, [], _replace, _out), do: nil

  defp replace_part_with_missing_leading_whitespace(
         whole_lines,
         part_lines,
         replace_lines,
         out_lines
       ) do
    leading =
      for l <- part_lines ++ replace_lines, String.trim(l) != "", do: indent(l)

    {part_lines, replace_lines} =
      case leading do
        [] -> {part_lines, replace_lines}
        _ -> outdent(part_lines, replace_lines, Enum.min(leading))
      end

    n = length(part_lines)

    matches =
      0..max(length(whole_lines) - n, -1)//1
      |> Stream.map(fn i ->
        case match_but_for_leading_whitespace(Enum.slice(whole_lines, i, n), part_lines) do
          nil -> nil
          add -> {i, Enum.map(replace_lines, &if(String.trim(&1) != "", do: add <> &1, else: &1))}
        end
      end)
      |> Stream.reject(&is_nil/1)
      |> Enum.take(2)

    case matches do
      [{i, replaced}] -> splice(out_lines, i, n, replaced)
      _ -> nil
    end
  end

  defp indent(line), do: String.length(line) - String.length(String.trim_leading(line))

  defp outdent(part, replace, 0), do: {part, replace}

  defp outdent(part, replace, n) do
    cut = fn l -> if String.trim(l) != "", do: String.slice(l, n..-1//1), else: l end
    {Enum.map(part, cut), Enum.map(replace, cut)}
  end

  defp match_but_for_leading_whitespace(chunk, part_lines) do
    same_text? =
      Enum.zip(chunk, part_lines)
      |> Enum.all?(fn {w, p} -> String.trim_leading(w) == String.trim_leading(p) end)

    if same_text? and length(chunk) == length(part_lines) do
      adds =
        for {w, p} <- Enum.zip(chunk, part_lines), String.trim(w) != "", uniq: true do
          String.slice(w, 0, String.length(w) - String.length(p))
        end

      case adds do
        [add] -> add
        _ -> nil
      end
    end
  end

  # Unchanged lines elided with `...`: the pieces between the dots are matched
  # exactly, each once.
  defp try_dotdotdots(whole, part, replace) do
    dots = ~r/(^\s*\.\.\.\n)/m
    part_pieces = Regex.split(dots, part, include_captures: true)
    replace_pieces = Regex.split(dots, replace, include_captures: true)

    cond do
      length(part_pieces) == 1 ->
        nil

      length(part_pieces) != length(replace_pieces) ->
        nil

      Enum.take_every(tl(part_pieces), 2) != Enum.take_every(tl(replace_pieces), 2) ->
        nil

      true ->
        Enum.zip(Enum.take_every(part_pieces, 2), Enum.take_every(replace_pieces, 2))
        |> Enum.reduce_while(whole, fn
          {"", ""}, whole ->
            {:cont, whole}

          {"", piece}, whole ->
            {:cont, ensure_newline(whole) <> piece}

          {piece, replacement}, whole ->
            case count(whole, piece) do
              1 -> {:cont, String.replace(whole, piece, replacement, global: false)}
              _ -> {:halt, nil}
            end
        end)
    end
  end

  defp count(text, piece), do: length(:binary.matches(text, piece))
end
