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

  @doc "Whole-file answers are on for a text-mode task when `code_whole_file` is true."
  def whole_file?(task), do: task.edit_mode == :text and Config.get(:code_whole_file) == true

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
    fences =
      Regex.scan(~r/(?:^|\n)([^\n]*)\n(`{3,})([^\n`]*)\n(.*?)\n\2[ \t]*(?=\n|\z)/s, text)

    files =
      for [_, before, _ticks, info, body] <- fences,
          path = whole_path(before, info, current),
          path != nil,
          do: {path, body}

    case files do
      [] ->
        :none

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
