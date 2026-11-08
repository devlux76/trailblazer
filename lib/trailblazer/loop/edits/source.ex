defmodule Trailblazer.Loop.Edits.Source do
  @moduledoc "Line and byte helpers over the source text that edit blocks are matched against."

  @doc false
  def excerpt(text, first, last) do
    if not (is_integer(first) and is_integer(last)) do
      nil
    else
      all =
        text
        |> String.split(~r/\r?\n/)
        |> then(fn l -> if List.last(l) == "", do: Enum.drop(l, -1), else: l end)

      total = length(all)
      from = max(first - 2, 1)
      to = min(last + 2, total)

      if total == 0 or to - from + 1 > 80 or from > to do
        nil
      else
        all
        |> Enum.with_index(1)
        |> Enum.slice((from - 1)..(to - 1)//1)
        |> Enum.map_join("\n", fn {line, n} -> "#{n}| #{line}" end)
      end
    end
  end

  @doc false
  def source_lines(text) do
    text
    |> String.split(~r/\r?\n/)
    |> then(fn l -> if List.last(l) == "", do: Enum.drop(l, -1), else: l end)
    |> List.to_tuple()
  end

  @doc false
  def line_at(lines, n) when n >= 1 and n <= tuple_size(lines), do: elem(lines, n - 1)
  def line_at(_lines, _n), do: ""

  @doc false
  def sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  @doc false
  def line_offsets(text) do
    ends = for {index, 1} <- :binary.matches(text, "\n"), do: index + 1

    case ends do
      [] when text == "" ->
        {:ok, [0]}

      _ ->
        offsets = [0 | ends]

        if String.ends_with?(text, "\n") do
          {:ok, offsets}
        else
          {:ok, offsets ++ [byte_size(text)]}
        end
    end
  end
end
