defmodule Trailblazer.Model.Runaway do
  @moduledoc """
  Degenerate repetition at the end of a streamed reply: one non-blank line
  repeated `@run` times in a row. lucet wrote a complete answer in 85 lines,
  then `</fenced>` 347 times until the 15-minute window closed and the whole
  answer was lost (live, vortex:db9b82d attempt 2). Such a reply is stopped
  and the repeated run cut off, so what came before it is used.
  """

  # high enough that data (zero-filled tables, repeated rows) rarely reaches
  # it; the live runaway was 347 repeats (review of c44a2bf)
  @run 40
  # only the tail is examined, so the per-delta check stays cheap
  @tail_bytes 4_096

  @doc "`{:runaway, content_before_the_run}` or `:ok`."
  def trim(content) when is_binary(content) do
    # a run can only complete when a line does
    if String.ends_with?(content, "\n"), do: check(content), else: :ok
  end

  defp check(content) do
    size = byte_size(content)
    tail = if size > @tail_bytes, do: binary_part(content, size - @tail_bytes, @tail_bytes), else: content
    lines = tail |> String.split("\n") |> drop_partial_last()

    case Enum.take(lines, -@run) do
      [line | _] = last when length(last) == @run ->
        if String.trim(line) != "" and Enum.all?(last, &(&1 == line)),
          do: {:runaway, cut(content, line)},
          else: numbered_copy(content, lines)

      _ ->
        numbered_copy(content, lines)
    end
  end

  # The numbered source view copied back, prefixes and all: `145| return`,
  # `146| }` … on consecutive numbers (live, vortex:31f3d17: lucet retyped
  # the 190-line vx.ts from its numbered view at ~3 tok/s, twice, until the
  # 15-minute window closed). An answer never holds those prefixes; the
  # reply is stopped where the copy began, keeping what came before it.
  @numbered_run 8
  defp numbered_copy(content, lines) do
    last = Enum.take(lines, -@numbered_run)
    nums = Enum.map(last, &line_number/1)

    if length(last) == @numbered_run and Enum.all?(nums, &is_integer/1) and
         nums == Enum.to_list(hd(nums)..(hd(nums) + @numbered_run - 1)//1) do
      all = content |> String.split("\n") |> Enum.drop(-1)
      copied = all |> Enum.reverse() |> Enum.take_while(&is_integer(line_number(&1))) |> length()
      {:runaway, Enum.join(Enum.drop(all, -copied), "\n") <> "\n"}
    else
      :ok
    end
  end

  defp line_number(line) do
    case Regex.run(~r/^\s*(\d+)\| /, line) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  # the last element is the line still being written (or "" after a newline)
  defp drop_partial_last([]), do: []
  defp drop_partial_last(lines), do: Enum.drop(lines, -1)

  # the content up to (not including) the run of `line`
  defp cut(content, line) do
    lines = String.split(content, "\n")
    {before, _} = Enum.split(lines, length(lines) - 1 - count_trailing(Enum.drop(lines, -1), line))
    Enum.join(before, "\n") <> "\n"
  end

  defp count_trailing(lines, line),
    do: lines |> Enum.reverse() |> Enum.take_while(&(&1 == line)) |> length()
end
