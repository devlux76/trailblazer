defmodule Trailblazer.Parse.MarkdownTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Parse.Markdown

  @path "docs/07-conversations.md"

  @source """
  # 7 Conversations

  Intro.

  ## 7.1 Rooms

  Rooms text.

  ### Who may join

  Joining text.

  ## 7.6 Peers

  Peers text.
  """

  defp parse(source, path \\ @path) do
    {:ok, parsed} = Markdown.parse(path, source)
    parsed
  end

  defp sections(parsed), do: Enum.filter(parsed.nodes, &(&1.kind == "doc_section"))
  defp by_qualified(parsed), do: Map.new(parsed.nodes, &{&1.qualified, &1})

  describe "sections" do
    test "numbered headings are named by their number, others by their slug" do
      assert Enum.map(sections(parse(@source)), & &1.qualified) == [
               "#{@path}#7",
               "#{@path}#7.1",
               "#{@path}#who-may-join",
               "#{@path}#7.6"
             ]
    end

    test "a section runs to the next heading of the same or a higher level" do
      nodes = by_qualified(parse(@source))

      assert {nodes["#{@path}#7"].start_line, nodes["#{@path}#7"].end_line} == {1, 15}
      assert {nodes["#{@path}#7.1"].start_line, nodes["#{@path}#7.1"].end_line} == {5, 12}

      assert {nodes["#{@path}#who-may-join"].start_line, nodes["#{@path}#who-may-join"].end_line} ==
               {9, 12}

      assert {nodes["#{@path}#7.6"].start_line, nodes["#{@path}#7.6"].end_line} == {13, 15}
    end

    test "a section node carries the attrs every node has" do
      section = by_qualified(parse(@source))["#{@path}#7.6"]

      assert section.key == "markdown:doc_section:#{@path}##{@path}#7.6"
      assert section.lang == "markdown"
      assert section.name == "7.6 Peers"
      assert section.path == @path
      assert section.signature == "## 7.6 Peers"

      lines = "## 7.6 Peers\n\nPeers text."
      assert section.text_hash == Base.encode16(:crypto.hash(:sha256, lines), case: :lower)
    end

    test "the document is a module node containing its top sections" do
      parsed = parse(@source)
      doc = by_qualified(parsed)[@path]

      assert doc.kind == "module"
      assert doc.key == "markdown:module:#{@path}##{@path}"
      assert {doc.start_line, doc.end_line} == {1, 15}

      assert [%{from_key: from, target: target, line: 1}] =
               Enum.filter(parsed.refs, &(&1.from_key == doc.key))

      assert from == doc.key
      assert target == "#{@path}#7"
    end

    test "a nested section is contained in the section above it" do
      parsed = parse(@source)
      nodes = by_qualified(parsed)

      contains =
        parsed.refs
        |> Enum.filter(&(&1.kind == "contains"))
        |> Enum.map(&{&1.from_key, &1.target, &1.line})

      assert {nodes["#{@path}#7"].key, "#{@path}#7.1", 5} in contains
      assert {nodes["#{@path}#7"].key, "#{@path}#7.6", 13} in contains
      assert {nodes["#{@path}#7.1"].key, "#{@path}#who-may-join", 9} in contains
      assert length(contains) == 4
      assert Enum.all?(parsed.refs, &(&1.ambiguous == false and &1.arity == nil))
    end

    test "headings inside fenced code are text, and deeper headings stay inside" do
      source = """
      ## Usage

      ```sh
      # not a heading
      ```

      ~~~
      ## nor this
      ~~~

      ##### Fine print

      ## 2. Storage
      """

      assert Enum.map(sections(parse(source)), &{&1.qualified, &1.start_line, &1.end_line}) == [
               {"#{@path}#usage", 1, 12},
               {"#{@path}#2", 13, 13}
             ]
    end

    test "a repeated slug is numbered in order" do
      source = "## Notes\n\n## Notes!\n\n## Notes\n"

      assert Enum.map(sections(parse(source)), & &1.qualified) == [
               "#{@path}#notes",
               "#{@path}#notes-2",
               "#{@path}#notes-3"
             ]
    end
  end

  # The edge-case register in plan Task 1 names each of these.
  describe "edge cases" do
    test "A3: a byte-order mark does not hide the first heading" do
      parsed = parse(<<0xEF, 0xBB, 0xBF>> <> "# 1 Title\n\ntext\n")

      assert [%{qualified: "#{@path}#1", signature: "# 1 Title", start_line: 1}] =
               sections(parsed)
    end

    test "A4: bytes that are not UTF-8 are read, and names stay valid UTF-8" do
      source = "# Caf" <> <<0xE9>> <> "\n\ntext\n"
      parsed = parse(source)

      assert [section] = sections(parsed)
      assert String.valid?(section.name) and String.valid?(section.signature)
      assert section.qualified == "#{@path}#caf"

      raw = "# Caf" <> <<0xE9>> <> "\n\ntext"
      assert section.text_hash == Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
    end

    test "A6: CRLF lines give the same sections and ranges as LF" do
      lf = "## One\n\ntext\n## Two\n"
      crlf = String.replace(lf, "\n", "\r\n")

      ranges = fn source ->
        Enum.map(sections(parse(source)), &{&1.qualified, &1.start_line, &1.end_line})
      end

      assert ranges.(crlf) == ranges.(lf)
    end

    test "A7: a closing fence is the whole line, so an info string inside does not close it" do
      source = "```\n```not-a-close\n## Fake\n```  \n## Real\n"

      assert Enum.map(sections(parse(source)), & &1.qualified) == ["#{@path}#real"]
    end

    test "A7: a tilde fence closes only on tildes at least as long" do
      source = "~~~~\n~~~\n```\n## Fake\n~~~~~\n## Real\n"

      assert Enum.map(sections(parse(source)), & &1.qualified) == ["#{@path}#real"]
    end

    test "A8: a number followed directly by ) or . is a section number" do
      source = "## 7)Overview\n## 8.Title\n## 9 Plain\n## 2026plans\n"

      assert Enum.map(sections(parse(source)), & &1.qualified) == [
               "#{@path}#7",
               "#{@path}#8",
               "#{@path}#9",
               "#{@path}#2026plans"
             ]
    end

    test "G1: a repeated section number is numbered in order" do
      source = "## 7 A\n## 7 B\n"

      assert Enum.map(sections(parse(source)), & &1.qualified) == ["#{@path}#7", "#{@path}#7-2"]
    end

    test "G2: a generated name never collides with a literal one" do
      for source <- ["## Notes\n## Notes\n## Notes-2\n", "## Notes-2\n## Notes\n## Notes\n"] do
        names = Enum.map(sections(parse(source)), & &1.qualified)
        assert length(Enum.uniq(names)) == 3, inspect(names)
      end
    end

    test "G2: every section survives a round trip through the Store" do
      parsed = parse("## Notes\n## Notes\n## Notes-2\n")

      {:ok, repo} =
        Trailblazer.Store.add_repo("/tmp/markdown-g2-#{System.unique_integer([:positive])}")

      :ok = Trailblazer.Store.replace_file(repo, @path, Map.put(parsed, :hash, "h"))

      stored = Trailblazer.Store.nodes_in_file(repo, @path)
      assert length(stored) == length(parsed.nodes)
    end
  end
end
