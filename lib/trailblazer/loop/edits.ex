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
  require Logger

  @head ~r/^<{5,9} SEARCH>?\s*$/
  @divider ~r/^={5,9}\s*$/
  @updated ~r/^>{5,9} REPLACE\s*$/
  @fence "```"

  @type block ::
          %{path: String.t(), type: :search, search: String.t(), replace: String.t()}
          | %{
              path: String.t(),
              type: :range,
              digest: String.t(),
              start: integer(),
              end: integer(),
              replace: String.t()
            }
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
    blocks = Enum.map(blocks, &normalize/1)
    blocks = Enum.map(blocks, &resolve(&1, worktree, files, shown))

    case split_by_kind(worktree, blocks) do
      {:error, failures} ->
        {:error, failures}

      {:ok, range_blocks, legacy_blocks} ->
        case apply_ranges(worktree, range_blocks) do
          {:error, failures} ->
            {:error, failures}

          {:ok, contents, relocations} ->
            with {:ok, paths} <- apply(worktree, legacy_blocks, contents, files, shown, opts) do
              # Reported only for a batch that was written in full.
              unless opts[:dry_run] do
                on_relocate = Keyword.get(opts, :on_relocate, &log_relocation/1)
                Enum.each(relocations, on_relocate)
              end

              {:ok, paths}
            end
        end
    end
  end

  defp apply(worktree, blocks, contents, _files, _shown, opts) do
    {contents, failures} =
      Enum.reduce(blocks, {contents, []}, fn block, {contents, failures} ->
        case edit(worktree, block, contents) do
          {:ok, path, text} -> {Map.put(contents, path, text), failures}
          {:error, failure} -> {contents, [failure | failures]}
        end
      end)

    if failures == [] do
      # only files whose bytes change: a batch that changes nothing returns []
      changed =
        for {path, text} <- contents,
            File.read(Path.join(worktree, path)) != {:ok, text},
            into: %{},
            do: {path, text}

      paths = changed |> Map.keys() |> Enum.sort()

      cond do
        opts[:dry_run] ->
          {:ok, paths}

        true ->
          case write_by_patch(worktree, changed) do
            :ok ->
              {:ok, paths}

            {:error, output} ->
              block = %{path: Enum.join(paths, ", "), type: :patch, search: "", replace: ""}
              {:error, [failure(block, :patch_failed, output)]}
          end
      end
    else
      {:error, Enum.reverse(failures)}
    end
  end

  # Every batch is checked by vendored tooling before a byte is written: one
  # unified diff (`diff -u`) of all files, applied with `git apply` to scratch
  # copies of the originals outside any repository (so the worktree's
  # autocrlf/eol attributes and symlinks play no part), must reproduce exactly
  # the bytes the edits produced. Only then are the files written, as before
  # (through symlinks). Any disagreement writes nothing.
  defp write_by_patch(_worktree, changed) when map_size(changed) == 0, do: :ok

  defp write_by_patch(worktree, changed) do
    scratch =
      Path.join(System.tmp_dir!(), "trailblazer-patch-#{System.unique_integer([:positive])}")

    tree = Path.join(scratch, "tree")
    File.mkdir_p!(tree)

    try do
      files =
        changed
        |> Enum.sort()
        |> Enum.with_index()
        |> Enum.map(fn {{path, text}, i} ->
          full = Path.join(worktree, path)
          copy = Path.join(tree, path)
          new = Path.join(scratch, "new-#{i}")
          File.write!(new, text)

          old =
            case File.read(full) do
              {:ok, bytes} ->
                File.mkdir_p!(Path.dirname(copy))
                File.write!(copy, bytes)
                bytes

              _ ->
                nil
            end

          %{path: path, full: full, copy: copy, new: new, text: text, old: old}
        end)

      with {:ok, patch, direct} <- unified_diff(files),
           :ok <- git_apply(tree, scratch, patch) do
        direct_paths = MapSet.new(direct, & &1.path)

        case Enum.reject(
               files,
               &(&1.path in direct_paths or File.read(&1.copy) == {:ok, &1.text})
             ) do
          [] ->
            for f <- files do
              File.mkdir_p!(Path.dirname(f.full))
              File.write!(f.full, f.text)
            end

            :ok

          wrong ->
            {:error,
             "git apply produced different bytes than the edits in " <>
               Enum.map_join(wrong, ", ", & &1.path) <> "; nothing was changed"}
        end
      end
    after
      File.rm_rf(scratch)
    end
  end

  defp unified_diff(files) do
    Enum.reduce_while(files, {:ok, "", []}, fn f, {:ok, patch, direct} ->
      {old, old_label} = if f.old, do: {f.copy, "a/" <> f.path}, else: {"/dev/null", "/dev/null"}

      # -a: compare as text even when a file looks binary to diff
      case System.cmd(
             "diff",
             ["-u", "-a", "--label", old_label, "--label", "b/" <> f.path, old, f.new],
             stderr_to_stdout: true
           ) do
        # an empty new file has no hunk to apply: it is written directly
        {"", 0} -> {:cont, {:ok, patch, [f | direct]}}
        {out, 1} -> {:cont, {:ok, patch <> out, direct}}
        {out, _} -> {:halt, {:error, "diff failed for #{f.path}: #{String.trim(out)}"}}
      end
    end)
  end

  defp git_apply(_tree, _scratch, ""), do: :ok

  # Outside any repository: GIT_CEILING_DIRECTORIES stops git from finding one
  # above the scratch tree, and autocrlf is off, so git apply acts as a plain,
  # byte-exact patch tool.
  defp git_apply(tree, scratch, patch) do
    file = Path.join(scratch, "edits.patch")
    File.write!(file, patch)

    case System.cmd(
           "git",
           ["-c", "core.autocrlf=false", "apply", "--whitespace=nowarn", file],
           cd: tree,
           env: [{"GIT_CEILING_DIRECTORIES", scratch}, {"GIT_DIR", nil}, {"GIT_WORK_TREE", nil}],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, _} -> {:error, "git apply refused the edits: #{String.trim(out)}"}
    end
  end

  # A block is either a legacy SEARCH block or a read-backed range block.
  defp normalize(%{type: :search} = block), do: block
  defp normalize(%{type: :range} = block), do: block

  defp normalize(%{path: _, search: _, replace: _} = block),
    do: Map.put(block, :type, :search)

  defp normalize(block), do: block

  defp split_by_kind(worktree, blocks) do
    {range_blocks, legacy_blocks, unknown_blocks} =
      Enum.reduce(blocks, {[], [], []}, fn block, {r, l, u} ->
        case Map.get(block, :type) do
          :range -> {[block | r], l, u}
          :search -> {r, [block | l], u}
          _ -> {r, l, [block | u]}
        end
      end)

    unknown_tmp = Enum.reverse(unknown_blocks)

    cond do
      unknown_tmp != [] ->
        {:error, Enum.map(unknown_tmp, &failure(&1, :invalid_range, "unknown block type"))}

      true ->
        range_paths =
          blocks
          |> Enum.filter(&(&1.type == :range))
          |> Enum.map(&target_key(worktree, &1.path))
          |> MapSet.new()

        search_paths =
          blocks
          |> Enum.filter(&(&1.type == :search))
          |> Enum.map(&target_key(worktree, &1.path))
          |> MapSet.new()

        case MapSet.intersection(range_paths, search_paths) |> Enum.to_list() do
          [] ->
            {:ok, Enum.reverse(range_blocks), Enum.reverse(legacy_blocks)}

          mixed ->
            {:error,
             Enum.map(mixed, fn p ->
               failure(%{path: p, type: :search, search: "", replace: ""}, :mixed_edits, "")
             end)}
        end
    end
  end

  defp target_key(worktree, path) do
    full = Path.expand(path, worktree)

    case Files.canonical_path(full) do
      {:ok, canonical} -> canonical
      _ -> full
    end
  end

  ## Read-backed range edits

  @doc "The notice for a relocated range, for the model and the case evidence."
  def relocation_notice(%{path: path, from: {a, b}, to: {c, d}}),
    do:
      "Note: your range #{a}-#{b} in #{path} was applied as lines #{c}-#{d}, " <>
        "where your first/last quotes are. Verify that is the code you meant in the current source.\n"

  defp log_relocation(relocation),
    do: Logger.warning("trailblazer: edit relocated " <> relocation_notice(relocation))

  defp apply_ranges(_worktree, []), do: {:ok, %{}, []}

  defp apply_ranges(worktree, blocks) do
    blocks
    |> Enum.group_by(&target_key(worktree, &1.path))
    |> Enum.reduce_while({:ok, %{}, []}, fn {_, group}, {:ok, contents, moved} ->
      case apply_range_group(worktree, hd(group).path, group) do
        {:ok, rel, text, relocations} ->
          {:cont, {:ok, Map.put(contents, rel, text), moved ++ relocations}}

        {:error, failures} ->
          {:halt, {:error, failures}}
      end
    end)
  end

  defp apply_range_group(worktree, path, blocks) do
    case contained(worktree, path) do
      {:error, reason} when is_atom(reason) ->
        {:error, Enum.map(blocks, &failure(&1, reason, ""))}

      {:ok, rel} ->
        with {:ok, text} <- read_full(Path.join(worktree, rel)),
             :ok <- check_digests(blocks, text),
             {:ok, offsets} <- line_offsets(text),
             blocks = fill_anchors(blocks, text),
             :ok <- validate_ranges(blocks, length(offsets) - 1, text),
             {:ok, blocks} <- check_anchors(blocks, text),
             :ok <- check_spans(blocks, offsets) do
          rel = Path.relative_to(target_key(worktree, rel), target_key(worktree, "."))

          relocations =
            for %{relocated_from: from} = b <- blocks,
                do: %{path: b.path, from: from, to: {b.start, b.end}}

          {:ok, rel, splice_all(text, blocks, offsets), relocations}
        else
          {:error, :no_such_file} -> {:error, Enum.map(blocks, &failure(&1, :no_such_file, ""))}
          {:error, :unreadable} -> {:error, Enum.map(blocks, &failure(&1, :unreadable, ""))}
          {:error, failures} -> {:error, failures}
        end
    end
  end

  defp read_full(full) do
    case File.read(full) do
      {:ok, text} -> {:ok, text}
      {:error, :enoent} -> {:error, :no_such_file}
      {:error, _} -> {:error, :unreadable}
    end
  end

  # A block without a digest (the text coder's dialect) relies on its
  # first/last quotes alone.
  defp check_digests(blocks, text) do
    sha = sha256(text)
    mismatched = Enum.reject(blocks, &(is_nil(&1.digest) or &1.digest == sha))

    case mismatched do
      [] -> :ok
      _ -> {:error, Enum.map(mismatched, &failure(&1, :stale_digest, digest_hint(&1, text, sha)))}
    end
  end

  # The excerpt is the exact current source at the failing range (bounded),
  # or just the digest when the window is too large to show.
  defp digest_hint(block, text, sha) do
    hint = "current sha256: #{sha}\n"

    case excerpt(text, block.start, max(block.start, block.end)) do
      nil -> hint
      lines -> hint <> lines
    end
  end

  defp excerpt(text, first, last) do
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
  defp check_anchors(blocks, text) do
    lines = source_lines(text)

    blocks
    |> Enum.map(fn block ->
      misses =
        [{:first, block.start}, {:last, block.end}]
        |> Enum.filter(fn {key, _} -> is_binary(Map.get(block, key)) end)
        |> Enum.reject(fn {key, n} -> anchor_ok?(lines, block, key, n) end)

      case {misses, relocate(lines, block, misses)} do
        {[], _} -> {:ok, block}
        {_, {:ok, moved}} -> {:ok, moved}
        _ -> {:error, failure(block, :anchor_mismatch, anchor_hint(block, misses, lines, text))}
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

  defp source_lines(text) do
    text
    |> String.split(~r/\r?\n/)
    |> then(fn l -> if List.last(l) == "", do: Enum.drop(l, -1), else: l end)
    |> List.to_tuple()
  end

  defp line_at(lines, n) when n >= 1 and n <= tuple_size(lines), do: elem(lines, n - 1)
  defp line_at(_lines, _n), do: ""

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
    |> Enum.all?(fn {line, at} -> same?(line, line_at(lines, at)) end)
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

        "#{key} quotes #{inspect(quoted)} but line #{n} is #{inspect(line_at(lines, n))}; #{where}.\n"
      end)

    shown =
      case excerpt(text, block.start, max(block.start, block.end)) do
        nil -> ""
        lines -> "Current lines #{block.start}-#{block.end}:\n" <> lines <> "\n"
      end

    "The range #{block.start}-#{block.end} is not the code you quoted, so nothing was applied.\n" <>
      notes <> shown <> "Recount start/end from the CURRENT numbered lines and quote them again."
  end

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp line_offsets(text) do
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

  # A text-mode block missing a quote (no <last>, or the model's native
  # edit(...) call with none) takes it from the file at its stated line: the
  # numbers came from the numbered source this attempt showed, and the check
  # and review still judge the result. Never for a digest block (JSON mode).
  defp fill_anchors(blocks, text) do
    lines = source_lines(text)

    Enum.map(blocks, fn
      %{digest: nil, type: :range, start: s, end: e} = block
      when is_integer(s) and is_integer(e) ->
        block
        |> fill_anchor(:first, lines, s)
        |> fill_anchor(:last, lines, e)

      block ->
        block
    end)
  end

  defp fill_anchor(block, key, lines, n) do
    if is_binary(Map.get(block, key)),
      do: block,
      else: Map.put(block, key, line_at(lines, n))
  end

  defp validate_ranges(blocks, len, _text) do
    Enum.reduce_while(blocks, :ok, fn block, :ok ->
      cond do
        not is_integer(block.start) or not is_integer(block.end) ->
          {:halt,
           {:error,
            Enum.map(blocks, &failure(&1, :invalid_range, "start and end must be integers"))}}

        # no digest (text mode): the first/last quotes alone bind the range
        is_nil(block.digest) and
            not (is_binary(Map.get(block, :first)) and is_binary(Map.get(block, :last))) ->
          {:halt,
           {:error,
            Enum.map(blocks, &failure(&1, :invalid_range, "first and last quotes are required"))}}

        block.start < 1 or block.start > len + 1 ->
          {:halt,
           {:error, Enum.map(blocks, &failure(&1, :invalid_range, "start is out of the file"))}}

        block.end < block.start - 1 ->
          {:halt,
           {:error, Enum.map(blocks, &failure(&1, :invalid_range, "end precedes start - 1"))}}

        block.end > len ->
          {:halt,
           {:error, Enum.map(blocks, &failure(&1, :invalid_range, "end is out of the file"))}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  # Reject overlapping replacements, insertions strictly inside a replaced
  # span and duplicate insertions at one position. Adjacent disjoint
  # replacements and boundary insertions are valid; same-start operations are
  # sorted deterministically (insertions first, then lowest end).
  defp check_spans(blocks, offsets) do
    span = fn b -> {Enum.at(offsets, b.start - 1), Enum.at(offsets, b.end)} end
    insertion? = fn b -> b.end == b.start - 1 end

    sorted =
      Enum.sort_by(blocks, fn b ->
        {Enum.at(offsets, b.start - 1), if(insertion?.(b), do: 0, else: 1), b.end}
      end)

    Enum.reduce_while(sorted, {:ok, 0, [], MapSet.new()}, fn b, {:ok, max_end, spans, inserts} ->
      {s, e} = span.(b)

      cond do
        insertion?.(b) ->
          cond do
            Enum.any?(spans, fn {rs, re} -> rs < s and s < re end) ->
              {:halt, {:error, [failure(b, :overlapping_ranges, "")]}}

            MapSet.member?(inserts, s) ->
              {:halt, {:error, [failure(b, :duplicate_insertion, "")]}}

            true ->
              {:cont, {:ok, max_end, spans, MapSet.put(inserts, s)}}
          end

        s < max_end ->
          {:halt, {:error, [failure(b, :overlapping_ranges, "")]}}

        true ->
          {:cont, {:ok, max(max_end, e), [{s, e} | spans], inserts}}
      end
    end)
    |> case do
      {:ok, _, _, _} -> :ok
      {:error, failures} -> {:error, failures}
    end
  end

  defp splice_all(text, blocks, offsets) do
    # Descending from the end in original-byte coordinates: splices already
    # applied sit above the current position, so original offsets stay valid
    # and no shift may accumulate. At the same start, a consuming replacement is
    # applied before an insertion so the insertion lands before the replaced
    # bytes, never inside them.
    sorted =
      Enum.sort_by(
        blocks,
        fn b ->
          {b.start, if(b.end == b.start - 1, do: 0, else: 1)}
        end,
        :desc
      )

    Enum.reduce(sorted, text, fn b, acc ->
      a = Enum.at(offsets, b.start - 1)

      case b.end == b.start - 1 do
        true ->
          binary_part(acc, 0, a) <> b.replace <> binary_part(acc, a, byte_size(acc) - a)

        false ->
          b_end = Enum.at(offsets, b.end)

          replacement =
            if b_end < byte_size(text) and b.replace != "" and
                 not String.ends_with?(b.replace, "\n") do
              separator =
                if b_end >= 2 and binary_part(text, b_end - 2, 2) == "\r\n",
                  do: "\r\n",
                  else: "\n"

              b.replace <> separator
            else
              b.replace
            end

          binary_part(acc, 0, a) <> replacement <> binary_part(acc, b_end, byte_size(acc) - b_end)
      end
    end)
  end

  defp edit(worktree, block, contents) do
    with {:ok, rel} <- contained(worktree, block.path),
         {:ok, current} <- current(worktree, rel, contents, block) do
      cond do
        String.trim(block.search) == "" and current in [nil, ""] ->
          {:ok, rel, block.replace}

        String.trim(block.search) == "" ->
          {:ok, offsets} = line_offsets(current)

          hint =
            "sha256: #{sha256(current)}\nFull-file replacement: start: 1, end: #{length(offsets) - 1}\n"

          {:error, failure(block, :file_exists, hint)}

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

  defp resolve(%{type: :range} = block, _worktree, _files, _shown), do: block

  defp resolve(%{} = block, _worktree, _files, _shown) when not is_map_key(block, :search),
    do: block

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
  # A model that invents a root (/workspace/src/a.ts) means the repository
  # file at the longest tail of that path that exists; that tail is then
  # checked like any relative path. Only for a root that does not exist on
  # this machine: a real outside path (/tmp/calc.py) is never matched to a
  # file inside (A9).
  defp contained(worktree, path) do
    case Path.type(path) do
      :relative -> contained_relative(worktree, path)
      _ -> contained_relative(worktree, invented_tail(worktree, path) || path)
    end
  end

  defp invented_tail(worktree, path) do
    parts = path |> Path.split() |> Enum.reject(&(&1 in ["/", ".", ".."]))
    invented? = parts != [] and not File.exists?(Path.join("/", hd(parts)))
    if invented?, do: longest_tail(worktree, parts)
  end

  defp longest_tail(worktree, parts) do
    0..max(length(parts) - 1, 0)//1
    |> Enum.map(&(parts |> Enum.drop(&1) |> Path.join()))
    |> Enum.find(&(&1 != "" and File.regular?(Path.join(worktree, &1))))
  end

  defp contained_relative(worktree, path) do
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

  ## Feedback (Aider's apply_edits failure message and find_similar_lines)

  @doc "What the model is told when blocks missed, compact and without re-printing the batch."
  @spec feedback([failure()]) :: String.t()
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
