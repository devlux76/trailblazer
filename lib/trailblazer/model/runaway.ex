defmodule Trailblazer.Model.Runaway do
  @moduledoc """
  Degenerate repetition at the end of a streamed reply: one non-blank line
  repeated `@run` times in a row. lucet wrote a complete answer in 85 lines,
  then `</fenced>` 347 times until the 15-minute window closed and the whole
  answer was lost (live, vortex:db9b82d attempt 2). Such a reply is stopped
  and the repeated run cut off, so what came before it is used.
  """

  @run 20
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
          else: :ok

      _ ->
        :ok
    end
  end

  # the last element is the line still being written (or "" after a newline)
  defp drop_partial_last([]), do: []
  defp drop_partial_last(lines), do: Enum.drop(lines, -1)

  # the content up to (not including) the run of `line`, plus its first copy
  # when it closes something real (a lone `</fenced>` after `</edit>` is junk,
  # but keeping one copy is harmless: parsers ignore unknown trailing tags)
  defp cut(content, line) do
    lines = String.split(content, "\n")
    {before, _} = Enum.split(lines, length(lines) - 1 - count_trailing(Enum.drop(lines, -1), line))
    Enum.join(before, "\n") <> "\n"
  end

  defp count_trailing(lines, line),
    do: lines |> Enum.reverse() |> Enum.take_while(&(&1 == line)) |> length()
end
