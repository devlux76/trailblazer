defmodule Trailblazer.Loop.Edits.Feedback do
  @moduledoc "What the model is told when edit blocks miss, and the similar-lines hint."

  alias Trailblazer.Loop.Edits

  @fence "```"
  @candidates 3

  ## Feedback (Aider's apply_edits failure message and find_similar_lines)

  @doc "What the model is told when blocks missed, compact and without re-printing the batch."
  @spec feedback([Edits.failure()]) :: String.t()
  def feedback(failures) do
    header =
      case failures do
        [_] -> "1 edit block failed to match; no file was changed.\n"
        _ -> "#{length(failures)} edit blocks failed to match; no file was changed.\n"
      end

    body = Enum.map_join(failures, "", &failure_note/1)

    footer =
      if Enum.all?(failures, &(Map.get(&1.block, :type) == :range)),
        do: "\nResubmit the complete corrected batch of range edits.\n",
        else:
          "\nResubmit the complete corrected batch. Each SEARCH must identify one location; use more context or a read-backed range for repeated text.\n"

    budget = 12_000 - String.length(header <> footer)
    notice = "\n... feedback truncated; use a smaller range.\n"

    body =
      if String.length(body) > budget,
        do: String.slice(body, 0, budget - String.length(notice)) <> notice,
        else: body

    header <> body <> footer
  end

  defp failure_note(%{block: b, reason: reason} = f) do
    "\n## #{b.path} (#{reason})\n" <> note_body(f)
  end

  defp note_body(%{reason: :file_exists, closest: hint}),
    do:
      "The file already exists. Empty SEARCH only creates a new or empty file; use a digest-bound range to replace existing contents.\n" <>
        hint <> "\n"

  defp note_body(%{reason: :stale_digest, closest: hint}), do: hint <> "\n"

  defp note_body(%{reason: :patch_failed, closest: output}), do: output <> "\n"

  defp note_body(%{reason: :anchor_mismatch, closest: hint}), do: hint <> "\n"

  defp note_body(%{reason: :invalid_range, closest: message}) when message != "",
    do: message <> "\n"

  defp note_body(%{reason: :invalid_range}),
    do: "The range is not valid for this file.\n"

  defp note_body(%{reason: :overlapping_ranges}),
    do: "Ranges in this file overlap; make them disjoint (adjacent is allowed).\n"

  defp note_body(%{reason: :duplicate_insertion}),
    do: "Two inserts target the same position; keep one or merge them.\n"

  defp note_body(%{reason: :mixed_edits}),
    do: "This file has both legacy and range blocks; use exactly one kind per file.\n"

  defp note_body(%{reason: :unreadable}),
    do: "The path is not a readable regular file.\n"

  defp note_body(%{reason: :no_such_file, closest: names}) when names != "",
    do: "No such file. Files with that name:\n#{names}\nName one of them in full.\n"

  defp note_body(%{reason: :no_such_file}),
    do: "No such file; leave the search empty to create it (legacy) or fix the path.\n"

  defp note_body(%{reason: :outside_worktree}),
    do: "This path is outside the repository; edit only files inside it.\n"

  defp note_body(%{reason: :no_match, block: b, closest: closest} = f) do
    already =
      if f[:already],
        do:
          "Are you sure you need this SEARCH/REPLACE block? The REPLACE lines are already in #{b.path}!\n\n",
        else: ""

    did =
      if closest != "",
        do:
          "Did you mean to match these exact lines in #{b.path}?\n\n" <>
            "#{@fence}\n#{closest}\n#{@fence}\n\n",
        else: ""

    already <> did
  end

  defp note_body(_failure), do: ""

  @doc false
  def find_similar_lines(search, content, threshold \\ 0.6) do
    search_lines = String.split(search, "\n", trim: true)
    content_lines = String.split(content, "\n")
    n = length(search_lines)

    best =
      if n == 0 or length(content_lines) < n,
        do: nil,
        else:
          content_lines
          |> candidate_windows(search_lines)
          |> Enum.map(fn i -> {ratio(search_lines, Enum.slice(content_lines, i, n)), i} end)
          |> Enum.max_by(&elem(&1, 0), fn -> nil end)

    case best do
      {r, i} when r >= threshold ->
        chunk = Enum.slice(content_lines, i, n)

        if hd(chunk) == hd(search_lines) and List.last(chunk) == List.last(search_lines) do
          Enum.join(chunk, "\n")
        else
          from = max(0, i - 5)

          content_lines
          |> Enum.slice(from, min(length(content_lines), i + n + 5) - from)
          |> Enum.join("\n")
        end

      _ ->
        ""
    end
  end

  # The character diff is too slow to run at every offset of a large file
  # (34 s for 3000 lines), so offsets are ranked by how many words their lines
  # share with the SEARCH lines, and only the best few are diffed.

  defp candidate_windows(content_lines, search_lines) do
    n = length(search_lines)
    search = Enum.map(search_lines, &words/1)
    content = content_lines |> Enum.map(&words/1) |> List.to_tuple()

    0..(tuple_size(content) - n)
    |> Enum.map(fn i ->
      score =
        search
        |> Enum.with_index()
        |> Enum.reduce(0, fn {words, k}, acc -> acc + overlap(words, elem(content, i + k)) end)

      {score, i}
    end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(@candidates)
    |> Enum.map(&elem(&1, 1))
  end

  defp words(line), do: ~r/\w+|[^\w\s]/u |> Regex.scan(line) |> List.flatten() |> MapSet.new()

  defp overlap(a, b) do
    case MapSet.size(a) + MapSet.size(b) do
      0 -> 1.0
      total -> 2 * MapSet.size(MapSet.intersection(a, b)) / total
    end
  end

  # SequenceMatcher's ratio over characters: 2 * matched / (len a + len b).
  defp ratio(a, b) do
    a = Enum.join(a, "\n")
    b = Enum.join(b, "\n")

    matched =
      String.myers_difference(a, b)
      |> Enum.map(fn
        {:eq, text} -> String.length(text)
        _ -> 0
      end)
      |> Enum.sum()

    2 * matched / max(String.length(a) + String.length(b), 1)
  end
end
