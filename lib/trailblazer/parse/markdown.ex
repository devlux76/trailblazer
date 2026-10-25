defmodule Trailblazer.Parse.Markdown do
  @moduledoc """
  Reads a design document into nodes: the document itself, a `module` node
  named by its path, and one `doc_section` node for every `#` to `####`
  heading. A section runs to the next heading of the same or a higher level.
  It is named `"<path>#<number>"` when its heading starts with a section
  number (`## 7.6 Peers` is `#7.6`), and `"<path>#<slug>"` otherwise.

  The document `contains` its top sections, and each section `contains` the
  ones directly below it. Headings inside fenced code are text.
  """

  @heading ~r/^ {0,3}(\#{1,4})(?:[ \t]+(.*?))?[ \t]*$/
  @fence ~r/^ {0,3}(`{3,}|~{3,})/
  @closing_fence ~r/^ {0,3}(`{3,}|~{3,})[ \t]*$/
  @number ~r/^(\d+(?:\.\d+)*)(?:[.)]|\s|$)/

  @spec parse(String.t(), String.t()) :: {:ok, %{nodes: [map()], refs: [map()]}}
  def parse(path, source) do
    # Hashes are taken over the bytes as they are; everything read from the
    # text is read from a copy without a byte-order mark and with every byte
    # that is not UTF-8 replaced, so that names stay valid text.
    raw = lines(source)
    lines = readable(raw)
    last = max(length(lines), 1)
    numbered = raw |> Enum.with_index(1) |> Map.new(fn {line, n} -> {n, line} end)

    headings = headings(lines)
    doc = doc_node(path, last, numbered, List.first(lines, ""))

    sections =
      headings
      |> Enum.with_index()
      |> Enum.map(fn {heading, i} ->
        Map.put(heading, :end_line, end_line(heading, Enum.drop(headings, i + 1), last))
      end)
      |> name_sections(path)

    nodes = Enum.map(sections, &section_node(&1, path, numbered))

    {:ok, %{nodes: [doc | nodes], refs: contains(doc, sections, path)}}
  end

  # A source that ends in a newline has no line after it.
  defp lines(source) do
    case String.split(source, ~r/\r?\n/) do
      [] -> []
      lines -> if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
    end
  end

  defp readable([first | rest]) do
    [String.replace_prefix(first, "\uFEFF", "") | rest]
    |> Enum.map(&String.replace_invalid/1)
  end

  defp readable([]), do: []

  # The headings outside fenced code, with their line and level. A fence closes
  # on a line holding nothing but a run of the same character, at least as long
  # as the one that opened it (CommonMark 4.5).
  defp headings(lines) do
    {headings, _fence} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], nil}, fn {line, n}, {acc, fence} ->
        case {fence, fence && Regex.run(@closing_fence, line)} do
          {nil, _} ->
            case Regex.run(@fence, line) do
              [_, marks] -> {acc, marks}
              nil -> {heading(line, n, acc), nil}
            end

          {open, [_, marks]} ->
            {acc, if(closes?(open, marks), do: nil, else: open)}

          {open, nil} ->
            {acc, open}
        end
      end)

    Enum.reverse(headings)
  end

  defp closes?(open, marks),
    do: String.first(open) == String.first(marks) and byte_size(marks) >= byte_size(open)

  defp heading(line, n, acc) do
    case Regex.run(@heading, line) do
      [_, marks | text] ->
        text = text |> List.first("") |> String.replace(~r/[ \t]+#+$/, "") |> String.trim()
        [%{level: byte_size(marks), text: text, line: n, source: String.trim(line)} | acc]

      nil ->
        acc
    end
  end

  defp end_line(heading, later, last) do
    case Enum.find(later, &(&1.level <= heading.level)) do
      nil -> last
      next -> next.line - 1
    end
  end

  # Numbers and slugs are both kept unique within the document: a repeat gets
  # "-2", "-3" and so on, in order, skipping any name already taken, including
  # one a heading spelled out itself ("Notes-2").
  defp name_sections(sections, path) do
    {named, _taken} =
      Enum.map_reduce(sections, MapSet.new(), fn section, taken ->
        anchor = free_anchor(anchor(section.text), taken)

        {Map.put(section, :qualified, "#{path}##{anchor}"), MapSet.put(taken, anchor)}
      end)

    named
  end

  defp free_anchor(base, taken) do
    if MapSet.member?(taken, base) do
      Stream.iterate(2, &(&1 + 1))
      |> Stream.map(&"#{base}-#{&1}")
      |> Enum.find(&(not MapSet.member?(taken, &1)))
    else
      base
    end
  end

  defp anchor(text) do
    case Regex.run(@number, text) do
      [_, number] -> number
      nil -> slug(text)
    end
  end

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp doc_node(path, last, numbered, first_line) do
    %{
      key: "markdown:module:#{path}##{path}",
      lang: "markdown",
      kind: "module",
      name: path,
      qualified: path,
      path: path,
      start_line: 1,
      end_line: last,
      signature: first_line |> String.trim() |> String.slice(0, 200),
      text_hash: text_hash(numbered, 1, last)
    }
  end

  defp section_node(section, path, numbered) do
    %{
      key: section_key(path, section),
      lang: "markdown",
      kind: "doc_section",
      name: section.text,
      qualified: section.qualified,
      path: path,
      start_line: section.line,
      end_line: section.end_line,
      signature: String.slice(section.source, 0, 200),
      text_hash: text_hash(numbered, section.line, section.end_line)
    }
  end

  defp section_key(path, section), do: "markdown:doc_section:#{path}##{section.qualified}"

  # Each section is contained in the nearest section above it with a lower
  # level, or in the document when there is none.
  defp contains(doc, sections, path) do
    {refs, _stack} =
      Enum.map_reduce(sections, [], fn section, stack ->
        stack = Enum.drop_while(stack, &(&1.level >= section.level))
        from_key = if parent = List.first(stack), do: section_key(path, parent), else: doc.key

        ref = %{
          from_key: from_key,
          kind: "contains",
          target: section.qualified,
          arity: nil,
          line: section.line,
          ambiguous: false
        }

        {ref, [section | stack]}
      end)

    refs
  end

  defp text_hash(numbered, first, last) do
    first..max(last, first)
    |> Enum.map_join("\n", &Map.get(numbered, &1, ""))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
