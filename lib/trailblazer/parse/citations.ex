defmodule Trailblazer.Parse.Citations do
  @moduledoc """
  Finds the design sections a code file says it implements. Each citation is
  an `implements` ref to `"<doc path>#<number>"`, from the innermost
  definition whose lines hold it, or from the file (`from_key: nil`) outside
  every definition.

  Recognised: `docs/07-conversations.md §7.6`, `[07](07-conversations.md)
  §7.4` and `(docs/12-status.md §12.5)`. In code, a bare `§7.6` cites the
  document named last before it in the same comment, read as the same run of
  non-blank lines, so that it works the same way for comments, docstrings and
  `@moduledoc`. In a Markdown document a bare `§` is the document's own, so
  there a section counts only right after the document it names (A11 in the
  register: "`AGENTS.md` wins … supersedes §5" meant the spec's own §5).

  Document paths are kept as written, without leading `./` and `../`; a link
  inside a Markdown document is read against that document's directory. The
  resolver finds a document by the end of its path when the path is not exact.
  """

  @token ~r/\[[^\]\n]*\]\((?<link>[^)\s]+\.md)\)|(?<path>(?:\.{1,2}\/)*[\w.\/-]*\w\.md)\b|§\s*(?<section>\d+(?:\.\d+)*)/u

  @spec scan(String.t(), String.t(), [map()]) :: [map()]
  def scan(path, source, definitions \\ []) do
    context = %{path: path, markdown: String.ends_with?(path, ".md"), definitions: definitions}

    # A byte-order mark and bytes that are not UTF-8 are not text a citation
    # can be made of; they are dropped or replaced so the scan reads the rest.
    {refs, _doc} =
      source
      |> String.replace_prefix("﻿", "")
      |> String.replace_invalid()
      |> String.split(~r/\r?\n/)
      |> Enum.with_index(1)
      |> Enum.flat_map_reduce(nil, fn {line, n}, doc ->
        if String.trim(line) == "", do: {[], nil}, else: cite(line, n, doc, context)
      end)

    Enum.uniq(refs)
  end

  # `doc` is the document named last, with where on this line its name ended
  # (nil when it was named on an earlier line).
  defp cite(line, n, doc, context) do
    {refs, {doc, _end}} =
      @token
      |> Regex.scan(line, capture: :all, return: :index)
      |> Enum.flat_map_reduce(carry(doc), fn [{start, len} | groups], {doc, ended} ->
        # trailing groups that did not take part are left out by Regex.scan
        groups = groups ++ List.duplicate({-1, 0}, 3 - length(groups))

        case Enum.map(groups, &text(line, &1)) do
          [link, path, ""] ->
            {[], {doc_path(link, path, context), start + len}}

          [_, _, section] ->
            if doc && adjacent?(line, ended, start, context),
              do: {[ref(doc, section, n, context.definitions)], {doc, start + len}},
              else: {[], {doc, ended}}
        end
      end)

    {refs, doc}
  end

  defp carry(nil), do: {nil, nil}
  defp carry(doc), do: {doc, nil}

  defp text(_line, {-1, _}), do: ""
  defp text(line, {start, len}), do: binary_part(line, start, len)

  # In code any earlier mention in the comment will do; in Markdown the section
  # sign must follow the document's name with nothing but space between.
  defp adjacent?(_line, _ended, _start, %{markdown: false}), do: true
  defp adjacent?(_line, nil, _start, _context), do: false

  defp adjacent?(line, ended, start, _context),
    do: start >= ended and String.trim(binary_part(line, ended, start - ended)) == ""

  defp doc_path("", path, _context), do: strip(path)

  defp doc_path(link, _path, %{markdown: true, path: citing}) do
    citing |> Path.dirname() |> Path.join(link) |> collapse()
  end

  defp doc_path(link, _path, _context), do: strip(link)

  defp strip(path), do: String.replace(path, ~r/^(?:\.{1,2}\/)+/, "")

  # `docs/specs/../registry.md` is `docs/registry.md`; climbing above the
  # repository's root stops at it.
  defp collapse(path) do
    path
    |> Path.split()
    |> Enum.reduce([], fn
      ".", acc -> acc
      "..", [] -> []
      "..", [_ | rest] -> rest
      part, acc -> [part | acc]
    end)
    |> Enum.reverse()
    |> Path.join()
  end

  defp ref(doc, section, line, definitions) do
    %{
      from_key: enclosing(definitions, line),
      kind: "implements",
      target: "#{doc}##{section}",
      arity: nil,
      line: line,
      ambiguous: false
    }
  end

  # The narrowest definition holding the line. Definitions sharing those lines
  # (`def g(a, b \\ 1)` is g/1 and g/2; two definitions on one line) go to the
  # last one listed, which is the one the parsers credit with the body's calls.
  defp enclosing(definitions, line) do
    definitions
    |> Enum.filter(&(&1.start_line <= line and line <= &1.end_line))
    |> Enum.reduce(nil, fn
      definition, nil -> definition
      definition, best -> if span(definition) <= span(best), do: definition, else: best
    end)
    |> case do
      nil -> nil
      definition -> definition.key
    end
  end

  defp span(definition), do: definition.end_line - definition.start_line
end
