defmodule Trailblazer.Loop.RangedSource do
  @moduledoc """
  A named source too long to send whole, cut to what the change needs.

  Prompt size is the lever on our router (measured 2026-11-06, lucet on the
  oneAPI build: prefill ~43 tok/s at 3.4k tokens, ~22 tok/s at 16k; a 766-line
  file is ~17k tokens, most of a 15-minute window just to read). So a file over
  `@max_lines` is shown as: its header (imports), the trail's ranges for that
  file widened by `@context` lines, and an outline (line number + first line of
  every top-level declaration) for the parts not shown. Line numbers are the
  file's real ones, so `<edit>` ranges apply unchanged. A file the trail does
  not reach is shown whole: guessing which part matters would hide the change.
  """

  @max_lines 300
  @context 6
  @header_scan 60
  @outline_max 80

  @doc "Line cap above which a file is ranged (planner window_fit mirrors it)."
  def max_lines, do: @max_lines

  @doc """
  `{:whole, lines}` when the file fits or the trail names none of it, else
  `{:ranged, title, body, outline}`: a title line, the numbered shown ranges
  with gap markers (to fence), and an outline of the rest ("" when none).
  `lines` are the file's lines (no trailing empty line).
  """
  @spec cut(String.t(), [String.t()], String.t() | nil) ::
          {:whole, [String.t()]} | {:ranged, String.t(), String.t(), String.t()}
  def cut(path, lines, trail) do
    count = length(lines)
    wanted = trail_ranges(trail, path, count)

    if count <= @max_lines or wanted == [] do
      {:whole, lines}
    else
      shown = merge([{1, header_end(lines)} | wanted]) |> fit(@max_lines)
      {title, body} = render(path, lines, shown)
      {:ranged, title, body, outline(lines, shown)}
    end
  end

  # Trail entries open with "path:start-end" (Prompts.lean_trail splits on it).
  defp trail_ranges(nil, _path, _count), do: []

  defp trail_ranges(trail, path, count) do
    ~r/(?:^|\n)(\S+):(\d+)-(\d+)\n/
    |> Regex.scan(trail)
    |> Enum.flat_map(fn [_, p, a, b] ->
      if p == path do
        {a, b} = {String.to_integer(a), String.to_integer(b)}
        [{max(1, min(a, b) - @context), min(count, max(a, b) + @context)}]
      else
        []
      end
    end)
    |> Enum.reject(fn {a, b} -> a > b end)
  end

  # Imports and the like at the top: up to the last such line in the first
  # @header_scan lines (at least line 1).
  @header ~r/^\s*(import|export\s+\*|export\s*\{[^}]*\}\s*from|from\s|use\s|alias\s|require\s|#!|"use |'use |package\s|using\s|@moduledoc|defmodule\s)/
  defp header_end(lines) do
    lines
    |> Enum.take(@header_scan)
    |> Enum.with_index(1)
    |> Enum.filter(fn {l, _} -> Regex.match?(@header, l) end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.max(fn -> 1 end)
  end

  # Ranges in the order given (header, then trail rank) while they fit `cap`
  # lines in total, then sorted and merged.
  defp fit(ranges, cap) do
    {kept, _} =
      Enum.reduce(ranges, {[], 0}, fn {a, b} = r, {kept, used} ->
        size = b - a + 1

        cond do
          used + size <= cap -> {[r | kept], used + size}
          used < cap -> {[{a, a + cap - used - 1} | kept], cap}
          true -> {kept, used}
        end
      end)

    kept |> Enum.reverse() |> merge()
  end

  defp merge(ranges) do
    ranges
    |> Enum.sort()
    |> Enum.reduce([], fn
      {a, b}, [{pa, pb} | rest] when a <= pb + 1 -> [{pa, max(b, pb)} | rest]
      r, acc -> [r | acc]
    end)
    |> Enum.reverse()
  end

  defp render(path, lines, shown) do
    count = length(lines)
    indexed = lines |> Enum.with_index(1) |> List.to_tuple()
    at = fn n -> elem(indexed, n - 1) |> elem(0) end

    {parts, last} =
      Enum.reduce(shown, {[], 0}, fn {a, b}, {parts, prev} ->
        gap = if a > prev + 1, do: ["… lines #{prev + 1}-#{a - 1} not shown …"], else: []
        body = Enum.map(a..b, &"#{&1}| #{at.(&1)}")
        {parts ++ gap ++ body, b}
      end)

    parts = if last < count, do: parts ++ ["… lines #{last + 1}-#{count} not shown …"], else: parts
    ranges = Enum.map_join(shown, ", ", fn {a, b} -> "#{a}-#{b}" end)

    {"#{path} (#{count} lines; showing #{ranges}, real line numbers)", Enum.join(parts, "\n")}
  end

  # Top-level declarations outside the shown ranges: where the rest of the
  # file is, so the coder can place or move code without seeing all of it.
  @decl ~r/^(export\s|async\s|function\s|class\s|interface\s|type\s|enum\s|const\s|let\s|var\s|def\s|class\s|pub\s|fn\s|struct\s|impl\s|  defp?\s|  defmacro\s)/
  defp path_hint(lines), do: "the #{length(lines)}-line file,"

  defp outline(lines, shown) do
    inside? = fn n -> Enum.any?(shown, fn {a, b} -> n >= a and n <= b end) end

    entries =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {l, n} -> not inside?.(n) and Regex.match?(@decl, l) end)
      |> Enum.take(@outline_max)
      |> Enum.map_join("\n", fn {l, n} -> "#{n}| #{String.trim_trailing(l)}" end)

    if entries == "", do: "", else: "Outline of #{path_hint(lines)} parts not shown:\n" <> entries
  end
end
