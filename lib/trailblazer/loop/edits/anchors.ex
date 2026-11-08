defmodule Trailblazer.Loop.Edits.Anchors do
  @moduledoc "Range anchor checks: quoted first and last lines, relocation and miscount repair."

  alias Trailblazer.Loop.Edits
  alias Trailblazer.Loop.Edits.Source

  # A model block quotes the text of lines start and end (first/last); a
  # miscounted line number would otherwise splice silently over the wrong
  # lines (the range was valid, just not the one meant). Compared trimmed, so
  # dropped indentation is tolerated; internal blocks without quotes skip it.
  # A multi-line quote (models often copy the old code) must match line by
  # line: first from line start downward, last upward ending at line end.
  #
  # The quotes state the intended code; the numbers are what small models
  # miscount. A replacing range with a missed quote is relocated only when
  # both quotes are unique in the file, the result is consistent (start <=
  # end, quotes inside it) and its length is within max(2, 20%) of the stated
  # one. Anything ambiguous, absent or inconsistent, and every insertion, is
  # refused.
  @doc false
  def check_anchors(blocks, text) do
    lines = Source.source_lines(text)

    blocks
    |> Enum.map(fn block ->
      misses =
        [{:first, block.start}, {:last, block.end}]
        |> Enum.filter(fn {key, _} -> is_binary(Map.get(block, key)) end)
        |> Enum.reject(fn {key, n} -> anchor_ok?(lines, block, key, n) end)

      case {misses, relocate(lines, block, misses)} do
        {[], _} ->
          {:ok, block}

        {_, {:ok, moved}} ->
          {:ok, moved}

        _ ->
          {:error,
           Edits.failure(block, :anchor_mismatch, anchor_hint(block, misses, lines, text))}
      end
    end)
    |> Enum.split_with(&match?({:ok, _}, &1))
    |> case do
      {ok, []} -> {:ok, Enum.map(ok, &elem(&1, 1))}
      {_, failures} -> {:error, Enum.map(failures, &elem(&1, 1))}
    end
  end

  defp relocate(_lines, block, _misses) when block.end < block.start, do: :error

  # Once a miss proves the numbers wrong, a quote is trusted only where it is
  # unique in the file (a generic "}" at the stated line is no evidence), and
  # the range may change length only slightly, so it cannot swallow code.
  defp relocate(lines, %{first: first, last: last} = block, _misses)
       when is_binary(first) and is_binary(last) do
    unique = fn key, quoted ->
      case for(i <- 1..max(tuple_size(lines), 1)//1, quoted_at?(lines, quoted, key, i), do: i) do
        [only] -> only
        _ -> nil
      end
    end

    stated = block.end - block.start

    with s when is_integer(s) <- unique.(:first, first),
         e when is_integer(e) <- unique.(:last, last),
         true <- s <= e,
         true <- abs(e - s - stated) <= max(2, div(stated + 1, 5)),
         span = e - s + 1,
         true <- length(quote_lines(first)) <= span and length(quote_lines(last)) <= span do
      {:ok, Map.merge(block, %{start: s, end: e, relocated_from: {block.start, block.end}})}
    else
      _ -> :error
    end
  end

  defp relocate(_lines, _block, _misses), do: :error

  defp same?(quoted, actual), do: String.trim(quoted) == String.trim(actual)

  # The quote's lines, a trailing newline not counting as an extra empty line.
  defp quote_lines(quoted) do
    case String.split(quoted, ~r/\r?\n/) do
      [only] -> [only]
      parts -> if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
    end
  end

  # first: quote line i is line n + i; last: the final quote line is line n.
  # For a replacing range the quote must lie inside it (a longer quote means
  # the range was miscounted); an insertion's quotes are the lines after
  # (first) and before (last) the insertion point, checked in that direction.
  defp anchor_ok?(lines, block, key, n) do
    quoted = Map.fetch!(block, key)
    span = block.end - block.start + 1

    (span <= 0 or length(quote_lines(quoted)) <= span) and quoted_at?(lines, quoted, key, n)
  end

  defp quoted_at?(lines, quoted, key, n) do
    q = quote_lines(quoted)
    from = if key == :first, do: n, else: n - length(q) + 1

    q
    |> Enum.with_index(from)
    |> Enum.all?(fn {line, at} -> same?(line, Source.line_at(lines, at)) end)
  end

  defp anchor_hint(block, misses, lines, text) do
    notes =
      Enum.map_join(misses, "", fn {key, n} ->
        quoted = Map.fetch!(block, key)
        q = quote_lines(quoted)
        span = length(q) - 1

        # Where the quote does sit, reported at the line it would name.
        found =
          for i <- 1..max(tuple_size(lines), 1)//1,
              String.trim(quoted) != "",
              quoted_at?(lines, quoted, key, i),
              do: i

        range = block.end - block.start + 1

        where =
          case {Enum.take(found, 5), span} do
            {_, _} when range > 0 and span + 1 > range ->
              "it has #{span + 1} lines but the range #{block.start}-#{block.end} has #{range}; recount start/end"

            {[], 0} ->
              "it is not a line of the current file"

            {[], _} ->
              "those #{span + 1} lines do not appear consecutively in the current file"

            {at, _} ->
              "it fits #{key} = line #{Enum.join(at, ", ")}"
          end

        "#{key} quotes #{inspect(quoted)} but line #{n} is #{inspect(Source.line_at(lines, n))}; #{where}.\n"
      end)

    shown =
      case Source.excerpt(text, block.start, max(block.start, block.end)) do
        nil -> ""
        lines -> "Current lines #{block.start}-#{block.end}:\n" <> lines <> "\n"
      end

    "The range #{block.start}-#{block.end} is not the code you quoted, so nothing was applied.\n" <>
      notes <> shown <> "Recount start/end from the CURRENT numbered lines and quote them again."
  end

  # A text-mode block missing a quote (no <last>, or the model's native
  # edit(...) call with none) takes it from the file at its stated line: the
  # numbers came from the numbered source this attempt showed, and the check
  # and review still judge the result. Never for a digest block (JSON mode).
  @doc false
  def fill_anchors(blocks, text) do
    lines = Source.source_lines(text)

    Enum.map(blocks, fn
      %{digest: nil, type: :range, start: s, end: e} = block
      when is_integer(s) and is_integer(e) ->
        block
        |> Map.put(:filled, [])
        |> fill_anchor(:first, lines, s)
        |> fill_anchor(:last, lines, e)
        |> shift_miscount(lines)

      block ->
        block
    end)
  end

  # A quote that is not the file's text at its line but IS part of the
  # block's own replacement is the new code put in the quote tag (both
  # LFM2.5-24B and lucet did this live, 2026-11-06): dropped, then filled.
  defp fill_anchor(block, key, lines, n) do
    quoted = Map.get(block, key)

    cond do
      not is_binary(quoted) ->
        Map.merge(block, %{key => Source.line_at(lines, n), filled: [key | block.filled]})

      quoted != "" and not quoted_at?(lines, quoted, key, n) and
          String.contains?(block.replace || "", String.trim(quoted)) ->
        Map.merge(block, %{
          key => Source.line_at(lines, n),
          quote_was_new_code: true,
          filled: [key | block.filled]
        })

      true ->
        block
    end
  end

  # A range the model numbered but did not quote (both anchors filled) can be
  # off by a line or two (live, lucet 2026-11-06: "28-30" for a replacement
  # that starts with line 27's `for`). diff/patch writes exactly the range it
  # is given, so the range is corrected first: when the replacement's first
  # lines repeat the lines just ABOVE start (or its last lines the lines just
  # BELOW end), the whole range shifts by that many lines, keeping its length.
  # Only exact lines with real content count (never "}" or blank), at most 3.
  defp shift_miscount(%{filled: filled, start: s, end: e} = block, lines)
       when length(filled) == 2 and e >= s do
    new = block.replace |> String.split("\n") |> drop_last_blank()

    up = repeated_lines(Enum.take(new, 3), fn k -> slice(lines, s - k, s - 1) end)

    down =
      repeated_lines(new |> Enum.take(-3) |> Enum.reverse(), fn k ->
        slice(lines, e + 1, e + k) |> Enum.reverse()
      end)

    shift =
      cond do
        up > 0 -> -up
        down > 0 -> down
        true -> 0
      end

    if shift == 0 or s + shift < 1 or e + shift > tuple_size(lines) do
      block
    else
      Map.merge(block, %{
        start: s + shift,
        end: e + shift,
        first: Source.line_at(lines, s + shift),
        last: Source.line_at(lines, e + shift),
        relocated_from: {s, e}
      })
    end
  end

  defp shift_miscount(block, _lines), do: block

  # The largest k (1..3) where the first k replacement lines equal the k file
  # lines the function names, all of them substantive.
  defp repeated_lines(head, file_lines) do
    Enum.find(min(length(head), 3)..1//-1, 0, fn k ->
      want = Enum.take(head, k)
      want == file_lines.(k) and Enum.all?(want, &substantive?/1)
    end)
  end

  defp slice(lines, from, to) when from >= 1 and to <= tuple_size(lines) and from <= to,
    do: for(i <- from..to, do: elem(lines, i - 1))

  defp slice(_lines, _from, _to), do: [:none]

  defp substantive?(line), do: String.length(String.replace(line, ~r/[\s{}()\[\];,]/, "")) >= 4

  defp drop_last_blank(parts),
    do: if(List.last(parts) == "", do: Enum.drop(parts, -1), else: parts)
end
