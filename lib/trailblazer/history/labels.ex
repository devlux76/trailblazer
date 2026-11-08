defmodule Trailblazer.History.Labels do
  @moduledoc "The outcome label of each history entry: reverted, fixed_up, open or succeeded. Recomputed on every ingest."

  @fixup_seconds 24 * 3600

  @doc false
  def reverted(commits) do
    for c <- commits,
        [sha] <-
          Regex.scan(~r/This reverts commit ([0-9a-f]{7,40})/, c.message, capture: :all_but_first),
        do: sha
  end

  @doc false
  # reverted > fixed_up > open > succeeded.
  def label(entries, reverted) do
    by_change = Enum.group_by(entries, &{&1.bug, &1.path})

    Enum.map(entries, fn e ->
      label =
        cond do
          Enum.any?(reverted, &String.starts_with?(e.commit, &1)) -> "reverted"
          e.bug && fixed_up?(e, by_change[{e.bug, e.path}]) -> "fixed_up"
          e.card_status == "open" -> "open"
          true -> "succeeded"
        end

      %{e | label: label}
    end)
  end

  # A later same-bug commit whose changed old lines (or insertion point) fall
  # inside lines `e` wrote; `e`'s pure deletions wrote nothing.
  defp fixed_up?(e, siblings) do
    written = Enum.filter(e.new_ranges, fn [c, d] -> d >= c end)

    Enum.any?(siblings, fn s ->
      s.commit != e.commit and s.at > e.at and s.at - e.at <= @fixup_seconds and
        Enum.any?(s.old_ranges, fn [a, b] ->
          Enum.any?(written, fn [c, d] -> a <= d and c <= max(a, b) end)
        end)
    end)
  end
end
