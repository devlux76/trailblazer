defmodule Trailblazer.Loop.Edits do
  @moduledoc """
  SEARCH/REPLACE edit blocks: how the code model says what to change, how the
  change is matched against the file, and what the model is told on a miss.

  Derived from Aider (`aider/coders/editblock_coder.py`, v0.86.2, Apache-2.0,
  Paul Gauthier and contributors; see NOTICE). Changed from Aider:

  - written in Elixir; Python's `SequenceMatcher` ratio is replaced by the
    same measure over a character diff (`String.myers_difference/2`), so a
    window that differs by one character in every line still scores high
    (Aider compares whole lines and would find nothing);
  - all or nothing: if any block misses, no file is written, and the attempt
    is retried with the feedback (Aider writes the blocks that matched);
  - a block never edits a file it does not name (Aider retries a miss against
    the other files in the chat);
  - every path is held to the worktree: absolute paths, `..` and symlinks
    out are refused (A9/A10/E3 in the register);
  - the fuzzy edit-distance matcher Aider ships disabled is left out, and so
    are shell blocks (the loop runs no commands from the model).
  """

  alias Trailblazer.Files

  @head ~r/^<{5,9} SEARCH>?\s*$/
  @divider ~r/^={5,9}\s*$/
  @updated ~r/^>{5,9} REPLACE\s*$/
  @fence "```"

  @type block :: %{path: String.t(), search: String.t(), replace: String.t()}
  @type failure :: %{block: block(), reason: atom(), closest: String.t()}

  ## Parsing

  @doc "The edit blocks of a model's reply, in order."
  @spec parse(String.t()) :: {:ok, [block()]} | {:error, String.t()}
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

  ## Applying

  @doc """
  Applies the blocks inside `worktree`, all or nothing: every block is matched
  in memory first (several blocks on one file chain), and files are written
  only when all of them matched.

  `opts[:files]` are the repository's files (relative paths). A block with a
  SEARCH that names a file that does not exist is taken to mean the one
  file of that name, or the one close match, as Aider does (a model shown
  `calc.py` wrote `lib/calc.py` three times in the first live trial); a miss
  lists the files with that name. A block that creates a file keeps its name.

  When the name settles nothing (no such file, or several of that name), the
  block goes to the one file among `opts[:shown]` (the files the model was
  given) or those of that name whose text its SEARCH matches: shown `calc.py`,
  the second trial's model wrote `lib/greeting.ex`, the prompt's example (D20).
  """
  @spec apply(Path.t(), [block()], keyword()) :: {:ok, [String.t()]} | {:error, [failure()]}
  def apply(worktree, blocks, opts \\ []) do
    files = Keyword.get(opts, :files, [])
    shown = Keyword.get(opts, :shown, [])
    blocks = Enum.map(blocks, &resolve(&1, worktree, files, shown))

    {contents, failures} =
      Enum.reduce(blocks, {%{}, []}, fn block, {contents, failures} ->
        case edit(worktree, block, contents) do
          {:ok, path, text} -> {Map.put(contents, path, text), failures}
          {:error, failure} -> {contents, [failure | failures]}
        end
      end)

    if failures == [] do
      for {path, text} <- contents do
        full = Path.join(worktree, path)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, text)
      end

      {:ok, contents |> Map.keys() |> Enum.sort()}
    else
      {:error, Enum.reverse(failures)}
    end
  end

  defp edit(worktree, block, contents) do
    with {:ok, rel} <- contained(worktree, block.path),
         {:ok, current} <- current(worktree, rel, contents, block) do
      cond do
        String.trim(block.search) == "" and current in [nil, ""] ->
          {:ok, rel, block.replace}

        String.trim(block.search) == "" ->
          {:ok, rel, ensure_newline(current) <> block.replace}

        current == nil ->
          {:error,
           failure(block, :no_such_file, block |> Map.get(:candidates, []) |> Enum.join("\n"))}

        true ->
          case replace_most_similar_chunk(current, block.search, block.replace) do
            nil ->
              failure = failure(block, :no_match, find_similar_lines(block.search, current))
              {:error, Map.put(failure, :already, already?(current, block.replace))}

            text ->
              {:ok, rel, text}
          end
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, failure(block, reason, "")}
    end
  end

  ## File names (Aider's find_filename, after the block is parsed)

  defp resolve(%{search: search} = block, worktree, files, shown) do
    cond do
      String.trim(search) == "" -> block
      # Codex's review of D17: `../calc.py` was matched to `calc.py` before the
      # containment check saw it. A name that would leave the worktree is
      # refused as written, never repaired into one that does not (A9).
      unsafe_name?(block.path) -> block
      block.path in files -> block
      File.exists?(Path.join(worktree, block.path)) -> block
      files == [] -> by_content(block, worktree, shown)
      true -> block |> resolve_name(files) |> by_content(worktree, shown)
    end
  end

  defp unsafe_name?(path),
    do: Path.type(path) != :relative or ".." in Path.split(path) or String.contains?(path, "\0")

  defp by_content(%{asked: _} = block, _worktree, _shown), do: block

  defp by_content(block, worktree, shown) do
    pool = Map.get(block, :candidates) || shown

    matching =
      Enum.filter(pool, fn path ->
        with {:ok, rel} <- contained(worktree, path),
             {:ok, text} <- File.read(Path.join(worktree, rel)) do
          replace_most_similar_chunk(text, block.search, block.replace) != nil
        else
          _ -> false
        end
      end)

    case matching do
      [one] -> block |> Map.delete(:candidates) |> Map.merge(%{path: one, asked: block.path})
      _ -> block
    end
  end

  defp resolve_name(block, files) do
    base = Path.basename(block.path)
    same_name = Enum.filter(files, &(Path.basename(&1) == base))

    case same_name do
      [one] ->
        Map.merge(block, %{path: one, asked: block.path})

      [] ->
        case files
             |> Enum.map(&{name_ratio(block.path, &1), &1})
             |> Enum.filter(&(elem(&1, 0) >= 0.8)) do
          [{_, one}] -> Map.merge(block, %{path: one, asked: block.path})
          _ -> block
        end

      several ->
        Map.put(block, :candidates, Enum.take(several, 10))
    end
  end

  defp name_ratio(a, b) do
    matched =
      String.myers_difference(a, b)
      |> Enum.map(fn
        {:eq, text} -> String.length(text)
        _ -> 0
      end)
      |> Enum.sum()

    2 * matched / max(String.length(a) + String.length(b), 1)
  end

  defp current(worktree, rel, contents, _block) do
    case Map.fetch(contents, rel) do
      {:ok, text} ->
        {:ok, text}

      :error ->
        case File.read(Path.join(worktree, rel)) do
          {:ok, text} -> {:ok, text}
          {:error, :enoent} -> {:ok, nil}
          {:error, _} -> {:error, :unreadable}
        end
    end
  end

  # The path, relative to the worktree, if it stays inside it: no absolute
  # path, no `..` that climbs out, no symlink leading out. A new file does not
  # exist yet, so the check is made on the nearest path that does, found with
  # lstat so that a link whose target is missing counts as there: such a link
  # cannot be resolved and is refused (Codex's review of L2). Anything that
  # cannot be resolved is refused, never assumed inside.
  defp contained(worktree, path) do
    with true <- Path.type(path) == :relative,
         {:ok, root} <- worktree |> Path.expand() |> real(),
         full = Path.expand(path, root),
         true <- inside?(full, root),
         {:ok, existing} <- full |> nearest_existing() |> real(),
         true <- inside?(existing, root) do
      {:ok, Path.relative_to(full, root)}
    else
      _ -> {:error, :outside_worktree}
    end
  end

  defp nearest_existing(path) do
    case File.lstat(path) do
      {:ok, _} -> path
      {:error, _} when path == "/" -> path
      {:error, _} -> nearest_existing(Path.dirname(path))
    end
  end

  defp real(path) do
    with {:ok, real} <- Files.canonical_path(path),
         true <- File.exists?(real) do
      {:ok, real}
    else
      _ -> :error
    end
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp failure(block, reason, closest), do: %{block: block, reason: reason, closest: closest}

  defp ensure_newline(""), do: ""
  defp ensure_newline(text), do: if(String.ends_with?(text, "\n"), do: text, else: text <> "\n")

  ## Matching (Aider's replace_most_similar_chunk)

  defp replace_most_similar_chunk(whole, part, replace) do
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

    Enum.find_value(0..max(length(whole_lines) - n, -1)//1, fn i ->
      if Enum.slice(whole_lines, i, n) == part_lines, do: splice(out_lines, i, n, replace_lines)
    end)
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

    Enum.find_value(0..max(length(whole_lines) - n, -1)//1, fn i ->
      chunk = Enum.slice(whole_lines, i, n)

      case match_but_for_leading_whitespace(chunk, part_lines) do
        nil ->
          nil

        add ->
          replaced = Enum.map(replace_lines, &if(String.trim(&1) != "", do: add <> &1, else: &1))
          splice(out_lines, i, n, replaced)
      end
    end)
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

  ## Feedback (Aider's apply_edits failure message and find_similar_lines)

  @doc "What the model is told when blocks missed, in Aider's words."
  @spec feedback([failure()]) :: String.t()
  def feedback(failures) do
    blocks = if length(failures) == 1, do: "block", else: "blocks"

    body =
      Enum.map_join(failures, "", fn %{block: b} = f ->
        """

        ## SearchReplaceNoExactMatch: This SEARCH block failed to exactly match lines in #{b.path}
        <<<<<<< SEARCH
        #{b.search}=======
        #{b.replace}>>>>>>> REPLACE

        """ <> reason_note(f) <> closest_note(f) <> already_note(f)
      end)

    "# #{length(failures)} SEARCH/REPLACE #{blocks} failed to match!\n" <>
      body <>
      "The SEARCH section must exactly match an existing block of lines including all white" <>
      " space, comments, indentation, docstrings, etc\n" <>
      "No file was changed: send every block again, the ones that matched included.\n"
  end

  defp reason_note(%{reason: :outside_worktree, block: b}),
    do: "#{b.path} is outside the repository; edit only files inside it.\n\n"

  defp reason_note(%{reason: :no_such_file, block: b, closest: ""}),
    do: "#{b.path} does not exist. To create it, leave the SEARCH section empty.\n\n"

  defp reason_note(%{reason: :no_such_file, block: b, closest: names}),
    do: "#{b.path} does not exist. Files with that name:\n#{names}\nName one of them in full.\n\n"

  defp reason_note(_failure), do: ""

  defp closest_note(%{closest: ""}), do: ""
  defp closest_note(%{reason: :no_such_file}), do: ""

  defp closest_note(%{closest: closest, block: b}),
    do:
      "Did you mean to match some of these actual lines from #{b.path}?\n\n#{@fence}\n#{closest}\n#{@fence}\n\n"

  defp already_note(%{block: %{replace: ""}}), do: ""

  defp already_note(%{block: b, reason: :no_match} = f) do
    if f[:already],
      do:
        "Are you sure you need this SEARCH/REPLACE block?\nThe REPLACE lines are already in #{b.path}!\n\n",
      else: ""
  end

  defp already_note(_failure), do: ""

  defp already?(_current, ""), do: false
  defp already?(current, replace), do: String.contains?(current, String.trim(replace))

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
  @candidates 3

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
