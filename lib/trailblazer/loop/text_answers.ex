defmodule Trailblazer.Loop.TextAnswers do
  @moduledoc """
  Reading a text-mode coder's answer beyond the tag dialect (Tools): the
  whole-file form (`code_whole_file`: the coder writes each changed file
  complete and the host computes the diff; live 2026-11-06, every local
  coder failed our invented range tags but writes a whole file naturally),
  the repository's own import lines for packages a request names, and the
  named-lines hint for an unreadable tag answer. Split out of Loop, which is
  over the 500-line limit.
  """

  alias Trailblazer.{Config, Files}
  alias Trailblazer.Loop.RangedSource

  @doc "Whole-file answers are on for a text-mode task when `code_whole_file` is true."
  def whole_file?(task), do: task.edit_mode == :text and Config.get(:code_whole_file) == true

  @doc """
  `<edit>` range blocks of a text-mode reply (Tools.text_edit_blocks/2). A
  block from line 1 of a file that is not there yet (`missing?.(path)`) is
  that file written whole: lucet created a new file as
  `<edit path="v6/hub/store-schema.ts" start="1" end="1">` (live,
  vortex:c8047e0), which as a range found no file and ended the case.
  `{root, named}` checks the disk, for the task's named files only (a
  misspelt path stays a failed edit, not a stray new file).
  """
  def edit_blocks(text, {root, named}),
    do: edit_blocks(text, &(&1 in named and not File.exists?(Path.join(root, &1))))

  # Whole-file mode shows a short named file plain, without line numbers, so
  # an <edit> range on it that quotes neither line is a guess (live,
  # vortex:85be62a: start=29 end=38 for code at 47-52, unquoted; the host
  # filled the anchors and broke codex/server.ts). Refused: write it whole.
  def edit_blocks(text, {root, named, true}) do
    with {:ok, blocks} <- edit_blocks(text, {root, named}) do
      case Enum.find(blocks, &(&1.path in named and unnumbered_guess?(&1, root))) do
        nil ->
          {:ok, blocks}

        b ->
          {:error,
           "#{b.path} was shown whole without line numbers, so start=#{b.start} end=#{b.end} is a guess; " <>
             "write #{b.path} out complete instead (its path on a line, then one fenced block)"}
      end
    end
  end

  def edit_blocks(text, {root, named, _whole?}), do: edit_blocks(text, {root, named})

  def edit_blocks(text, missing?) do
    case Trailblazer.Loop.Tools.text_edit_blocks(text, mode: :text) do
      {:ok, blocks} -> {:ok, Enum.map(blocks, &create_missing(&1, missing?))}
      other -> other
    end
  end

  @plain_max 150
  defp unnumbered_guess?(%{type: :range, first: nil, last: nil, path: path}, root) do
    case Files.read(root, path) do
      # counted as Prompts.whole_source counts: one trailing empty line dropped
      {:ok, text} ->
        lines = String.split(text, ~r/\r?\n/)
        lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
        length(lines) <= @plain_max

      _ ->
        false
    end
  end

  defp unnumbered_guess?(_block, _root), do: false

  defp create_missing(%{type: :range, start: s, path: path, replace: body} = block, missing?)
       when s <= 1 do
    if missing?.(path), do: %{path: path, search: "", replace: body}, else: block
  end

  defp create_missing(block, _missing?), do: block

  @doc "The named files as they are now (nil: not there yet); only these may be written whole."
  def current_files(root, paths) do
    Map.new(paths, fn path ->
      case Files.read(root, path) do
        {:ok, text} -> {path, text}
        {:error, _} -> {path, nil}
      end
    end)
  end

  @doc """
  The files a unified diff changes, complete as they are now in `root`, for
  the reviewer; only text files within the 500-line rule (larger stay
  diff-only), deleted files skipped.
  """
  def changed_files(root, diff) do
    ~r/^\+\+\+ b\/(.+)$/m
    |> Regex.scan(diff, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(fn path ->
      case Files.read(root, path) do
        {:ok, text} ->
          if String.valid?(text) and length(String.split(text, "\n")) <= 501,
            do: [{path, text}],
            else: []

        _ ->
          []
      end
    end)
  end

  @doc """
  For each `@scope/name` package the request names, one real import line
  from the repository, so the coder copies how the code base already imports
  it (live: lucet imported multiaddr from the wrong module with only prose).
  """
  def usages(root, task) do
    request = "#{Map.get(task, :request)}\n#{inspect(Map.get(task, :design))}"

    ~r/@[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+/
    |> Regex.scan(request)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.take(4)
    |> Enum.flat_map(&import_line(root, &1))
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  defp import_line(root, pkg) do
    case System.cmd("git", ["-C", root, "grep", "-h", "-m", "1", "-F", "from '#{pkg}'"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out |> String.split("\n", trim: true) |> Enum.take(1) |> Enum.map(&String.trim/1)

      _ ->
        []
    end
  end

  @doc """
  Whole-file answers: each file as its path on a line (or in the fence's
  info string) followed by one fenced block holding the complete new file.
  `current` maps a path to its current text (nil when it does not exist);
  only those paths are accepted. An existing file becomes one range block
  over all its lines (anchored by its first and last line), a new one a
  create; both then go through Edits (diff -u + git apply) like any edit.
  `:none` when the reply holds no such file.
  """
  def whole_file_blocks(text, current) when is_binary(text) and is_map(current) do
    case native_writes(text, current) do
      [] -> fenced_files(text, current)
      files -> to_blocks(files, current)
    end
  end

  @edit_span ~r/^[ \t]*<edit\b.*?^[ \t]*<\/edit>[ \t]*$/ms
  @fence_span ~r/(?:^|\n)(`{3,})[^\n`]*\n.*?\n\1[ \t]*(?=\n|\z)/s

  @doc """
  A whole-file-mode reply: files written whole (`whole_file_blocks/2`) plus
  `<edit>` range blocks for long files (shown numbered, too long to retype
  inside the generation window: live, vortex:d51a661 2026-11-06, ~490 lines at
  ~3.7 tok/s). Either form alone, or both for different files; one file in
  both forms is refused. `:none` when the reply holds no whole file: an
  edit-only reply then goes the plain range-block way (Loop.tag_blocks).

  Each form is read only outside the other: `<edit>` tags inside a fenced
  whole file (a prompt or doc that shows the format) are file content, and a
  fence inside an `<edit>` replace is edit content.
  """
  def answer_blocks(text, current) when is_binary(text) and is_map(current) do
    spans = spans(text, 0, [])

    case whole_file_blocks(without(text, spans, :edit), current) do
      {:ok, whole} ->
        outside = without(text, spans, :fence)

        case if(outside =~ ~r/^\s*<edit\b/m,
               do: edit_blocks(outside, &(Map.has_key?(current, &1) and current[&1] == nil)),
               else: :none
             ) do
          :none -> {:ok, whole}
          {:ok, edits} -> merge_forms(whole, edits)
          {:error, _} = error -> error
        end

      other ->
        other
    end
  end

  # Fenced and <edit> spans, left to right: whichever starts first owns its
  # text, so a fence inside an edit and an edit inside a fence stay content.
  defp spans(text, from, acc) do
    found =
      for {kind, re} <- [fence: @fence_span, edit: @edit_span],
          # the whole match is the first index pair (the fence has a capture)
          [{start, len} | _] <- [Regex.run(re, text, return: :index, offset: from)],
          do: {start, len, kind}

    case Enum.min_by(found, &elem(&1, 0), fn -> nil end) do
      nil -> Enum.reverse(acc)
      {start, len, kind} -> spans(text, start + len, [{start, len, kind} | acc])
    end
  end

  # `text` with the spans of `kind` cut out (byte offsets from Regex :index).
  defp without(text, spans, kind) do
    {parts, last} =
      Enum.reduce(spans, {[], 0}, fn
        {start, len, ^kind}, {parts, at} ->
          {[binary_part(text, at, start - at) | parts], start + len}

        _, acc ->
          acc
      end)

    IO.iodata_to_binary(Enum.reverse([binary_part(text, last, byte_size(text) - last) | parts]))
  end

  defp merge_forms(whole, edits) do
    both = MapSet.intersection(MapSet.new(whole, & &1.path), MapSet.new(edits, & &1.path))

    if MapSet.size(both) == 0,
      do: {:ok, whole ++ edits},
      else:
        {:error,
         "#{Enum.join(both, ", ")}: written whole and with <edit> blocks; use one form per file"}
  end

  # The coder's own write tool (live, lucet 2026-11-06: the correct whole
  # file as `<tool_call>write<arg_key>path</arg_key><arg_value>...` with a
  # `content` argument): the most natural whole-file answer of all.
  defp native_writes(text, current) do
    for [inner] <-
          Regex.scan(
            ~r/<tool_call>\s*(?:write|create|write_file|create_file)\b(.*?)<\/tool_call>/s,
            text,
            capture: :all_but_first
          ),
        args = call_args(inner),
        path = args["path"] || args["file_path"] || args["filename"],
        is_binary(path),
        path = String.trim_leading(String.trim(path), "./"),
        Map.has_key?(current, path),
        content = args["content"] || args["text"] || args["contents"],
        is_binary(content),
        do: {path, String.trim_trailing(content, "\n")}
  end

  defp call_args(inner) do
    pairs =
      ~r/<arg_key>(.*?)<\/arg_key>\s*<arg_value>(.*?)<\/arg_value>/s
      |> Regex.scan(inner, capture: :all_but_first)
      |> Map.new(fn [k, v] -> {String.trim(k), v} end)

    attrs =
      ~r/(\w+)\s*=\s*"([^"]*)"/
      |> Regex.scan(inner |> String.split(~r/<arg_(?:key|value)>/, parts: 2) |> hd(),
        capture: :all_but_first
      )
      |> Map.new(fn [k, v] -> {k, v} end)

    Map.merge(attrs, pairs)
  end

  defp fenced_files(text, current) do
    fences =
      Regex.scan(~r/(?:^|\n)([^\n]*)\n(`{3,})([^\n`]*)\n(.*?)\n\2[ \t]*(?=\n|\z)/s, text)

    files =
      for [_, before, _ticks, info, body] <- fences,
          path = whole_path(before, info, current),
          path != nil,
          do: {path, body}

    case files do
      [] -> :none
      files -> to_blocks(files, current)
    end
  end

  defp to_blocks(files, current) do
    case files do
      files ->
        Enum.reduce_while(files, {:ok, []}, fn {path, body}, {:ok, acc} ->
          case whole_block(path, body <> "\n", current[path]) do
            {:ok, block} -> {:cont, {:ok, acc ++ [block]}}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp whole_path(before, info, current) do
    candidates =
      [info, before]
      |> Enum.flat_map(&String.split(&1, ~r/[\s`*#:"']+/, trim: true))
      |> Enum.map(&String.trim_leading(&1, "./"))

    Enum.find(candidates, &Map.has_key?(current, &1)) ||
      Enum.find_value(candidates, fn c ->
        Enum.find(Map.keys(current), &String.ends_with?(c, "/" <> &1))
      end)
  end

  @placeholder ~r/^\s*(?:\/\/|#|--|\/\*)?\s*\.\.\.\s*(?:\(?\s*(?:rest|existing|unchanged|remaining)[^\n]*)?$/im

  defp whole_block(path, body, nil), do: {:ok, %{path: path, search: "", replace: body}}

  defp whole_block(path, body, current) do
    old =
      current
      |> String.split("\n")
      |> then(&if(List.last(&1) == "", do: Enum.drop(&1, -1), else: &1))

    cond do
      Regex.match?(@placeholder, body) and not Regex.match?(@placeholder, current) ->
        {:error,
         "#{path}: the file has a `...` placeholder; write the whole file, every line, changed or not"}

      old == [] ->
        {:ok, %{path: path, search: "", replace: body}}

      # a file this long reached the coder ranged (Loop.RangedSource): a whole
      # write would delete every line it was not shown
      length(old) > RangedSource.max_lines() ->
        {:error,
         "#{path}: #{length(old)} lines is too long to write whole; change it with <edit> blocks by line range"}

      true ->
        {:ok,
         %{
           path: path,
           digest: nil,
           start: 1,
           end: length(old),
           first: hd(old),
           last: List.last(old),
           replace: body,
           type: :range
         }}
    end
  end

  # For an unreadable text-mode reply: the lines each of its <edit> tags
  # names, as they are now, and that block filled in with them. A 4B model
  # copies a concrete shape far better than it follows a rule (live, Bolt,
  # 2026-11-05: two attempts of bare code inside <edit>).
  @named_edit ~r/^[ \t]*<edit\b[^>\n]*\bpath="([^"]+)"[^>\n]*>/m
  @named_cap 40

  @doc false
  def named_lines(root, content) do
    @named_edit
    |> Regex.scan(content)
    |> Enum.map(fn [tag, path] ->
      {path, tag_number(tag, "start"), tag_number(tag, "end")}
    end)
    |> Enum.uniq()
    |> Enum.take(3)
    |> Enum.map_join("", fn
      {path, s, e} when is_integer(s) and is_integer(e) and s >= 1 and e >= s ->
        case Files.read(root, path) do
          {:ok, text} ->
            lines = text |> String.split(~r/\r?\n/) |> Enum.with_index(1)

            shown =
              Enum.filter(lines, fn {_, n} -> n >= s and n <= min(e, s + @named_cap - 1) end)

            line = fn n -> lines |> Enum.find({"", n}, &(elem(&1, 1) == n)) |> elem(0) end

            if shown == [],
              do: "",
              else:
                "\n\n#{path} lines #{s}-#{e} are now:\n" <>
                  Enum.map_join(shown, "\n", fn {l, n} -> "#{n}| #{l}" end) <>
                  "\nWritten as a block (keep start/end only if these are the lines to replace):\n" <>
                  "<edit path=\"#{path}\" start=\"#{s}\" end=\"#{e}\">\n" <>
                  "<first>" <>
                  line.(s) <>
                  "</first>\n<last>" <>
                  line.(e) <>
                  "</last>\n<replace>\n" <>
                  "the new lines\n</replace>\n</edit>"

          _ ->
            ""
        end

      _ ->
        ""
    end)
  end

  defp tag_number(tag, key) do
    case Regex.run(~r/\b#{key}="(\d+)"/, tag, capture: :all_but_first) do
      [n] -> String.to_integer(n)
      _ -> nil
    end
  end
end
