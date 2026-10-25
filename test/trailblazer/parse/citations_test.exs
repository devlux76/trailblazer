defmodule Trailblazer.Parse.CitationsTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Parse.Citations

  @path "lib/example.ex"

  defp targets(refs), do: Enum.map(refs, &{&1.target, &1.line})

  describe "forms" do
    test "a path followed by a section sign" do
      source = "# The rooms, as in docs/07-conversations.md §7.6.\nx = 1\n"

      assert [ref] = Citations.scan(@path, source)

      assert ref == %{
               from_key: nil,
               kind: "implements",
               target: "docs/07-conversations.md#7.6",
               arity: nil,
               line: 1,
               ambiguous: false
             }
    end

    test "a Markdown link followed by a section sign" do
      source = "x = 1\n// see [07](07-conversations.md) §7.4\n"

      # kept as written: the resolver finds the document by its path's end (H5)
      assert targets(Citations.scan(@path, source)) == [{"07-conversations.md#7.4", 2}]
    end

    test "a parenthesised citation" do
      source = "# Kept until it parses again (docs/12-status.md §12.5)\n"

      assert targets(Citations.scan(@path, source)) == [{"docs/12-status.md#12.5", 1}]
    end

    test "a bare section sign uses the document named earlier in the same comment" do
      source = """
      # Rooms follow docs/07-conversations.md §7.4,
      # and peers §7.6.

      # A lone §9 with no document named is not a citation.
      """

      assert targets(Citations.scan(@path, source)) == [
               {"docs/07-conversations.md#7.4", 1},
               {"docs/07-conversations.md#7.6", 2}
             ]
    end

    test "a link with a path keeps it, relative segments dropped" do
      source = "# [design](../docs/design.md) §2 and [x](./notes/x.md) §1\n"

      assert targets(Citations.scan(@path, source)) == [
               {"docs/design.md#2", 1},
               {"notes/x.md#1", 1}
             ]
    end
  end

  describe "where a citation comes from" do
    test "a citation inside a def body comes from that function" do
      source = """
      defmodule M do
        @moduledoc "Storage, docs/design.md §2."

        def put(x) do
          # docs/design.md §2.1
          x
        end
      end
      """

      {:ok, %{nodes: nodes}} = Trailblazer.Parse.Elixir.parse(@path, source)

      assert [module_ref, function_ref] = Citations.scan(@path, source, nodes)
      assert module_ref.from_key == "elixir:module:#{@path}#M"
      assert module_ref.target == "docs/design.md#2"
      assert function_ref.from_key == "elixir:function:#{@path}#M.put/1"
      assert {function_ref.target, function_ref.line} == {"docs/design.md#2.1", 5}
    end

    test "a citation outside every definition comes from the file" do
      source = "# docs/design.md §1\ndefmodule M do\nend\n"
      {:ok, %{nodes: nodes}} = Trailblazer.Parse.Elixir.parse(@path, source)

      assert [%{from_key: nil}] = Citations.scan(@path, source, nodes)
    end

    test "C4: of definitions sharing lines, the one the parser credits with the body" do
      source = """
      defmodule M do
        def g(a, b \\\\ 1) do
          # docs/design.md §2
          x(a)
        end

        def h, do: :a; def k, do: :b # docs/design.md §3
      end
      """

      {:ok, %{nodes: nodes, refs: refs}} = Trailblazer.Parse.Elixir.parse(@path, source)
      body_call = Enum.find(refs, &(&1.target == "M.x"))

      assert [in_g, on_line] = Citations.scan(@path, source, nodes)
      assert in_g.from_key == body_call.from_key
      assert in_g.from_key == "elixir:function:#{@path}#M.g/2"
      assert on_line.from_key == "elixir:function:#{@path}#M.k/0"
    end

    # Codex's repros: the order of the keys must not decide (g/10 sorts before
    # g/9, and a/0 before z/0).
    test "C4: the declared head wins whatever its arity sorts like" do
      args = Enum.map_join(1..9, ", ", &"a#{&1}")

      source = """
      defmodule M do
        def g(#{args}, a10 \\\\ 0) do
          # docs/design.md §2
          X.call()
        end
      end
      """

      {:ok, %{nodes: nodes, refs: refs}} = Trailblazer.Parse.Elixir.parse(@path, source)
      body_call = Enum.find(refs, &(&1.target == "X.call"))

      assert [citation] = Citations.scan(@path, source, nodes)
      assert citation.from_key == body_call.from_key
      assert citation.from_key == "elixir:function:#{@path}#M.g/10"
    end

    # Codex's repros of 696e778: the order holds across kinds, not only functions.
    test "C4: a type after a function on one line is the later definition" do
      source = "defmodule M do\n  def f, do: :ok; @type t :: term() # docs/design.md §2\nend\n"
      {:ok, %{nodes: nodes}} = Trailblazer.Parse.Elixir.parse(@path, source)

      assert [%{from_key: from_key}] = Citations.scan(@path, source, nodes)
      assert from_key == "elixir:type:#{@path}#M.t"
    end

    test "C4: a nested module after a function on one line comes after it" do
      source =
        "defmodule M do\n  def f, do: :ok; defmodule N do def g, do: :ok end # docs/design.md §2\nend\n"

      {:ok, %{nodes: nodes}} = Trailblazer.Parse.Elixir.parse(@path, source)

      assert Enum.map(nodes, & &1.qualified) == ["M", "M.f/0", "M.N", "M.N.g/0"]
      assert [%{from_key: from_key}] = Citations.scan(@path, source, nodes)
      refute from_key == "elixir:function:#{@path}#M.f/0"
    end

    test "C4: of two definitions on one line, the later in the source" do
      source = "defmodule M do\n  def z, do: :a; def a, do: :b # docs/design.md §2\nend\n"
      {:ok, %{nodes: nodes}} = Trailblazer.Parse.Elixir.parse(@path, source)

      assert [%{from_key: from_key}] = Citations.scan(@path, source, nodes)
      assert from_key == "elixir:function:#{@path}#M.a/0"
    end
  end

  # Found by the acceptance run on sojourney (A11 in the register).
  describe "in a Markdown document" do
    @doc_path "docs/specs/pipeline.md"

    test "a bare section sign is the document's own, not the last one named" do
      source = "`AGENTS.md` wins, and the pack contract supersedes §5 and §7.\n"

      assert Citations.scan(@doc_path, source) == []
    end

    test "an explicit citation still counts" do
      source = "See docs/design.md §2 for the storage rules.\n"

      assert targets(Citations.scan(@doc_path, source)) == [{"docs/design.md#2", 1}]
    end

    test "a relative link is read against the document's own directory" do
      source = "Per [the registry](../registry.md) §3 and [a sibling](other.md) §1.\n"

      assert targets(Citations.scan(@doc_path, source)) == [
               {"docs/registry.md#3", 1},
               {"docs/specs/other.md#1", 1}
             ]
    end

    test "a bare file name stays as written, never forced into docs/" do
      source = "The rules in AGENTS.md §5 win.\n"

      assert targets(Citations.scan("README.md", source)) == [{"AGENTS.md#5", 1}]
    end
  end

  # The edge-case register in plan Task 1 names each of these.
  describe "edge cases" do
    test "A4: bytes that are not UTF-8 do not stop the scan" do
      source = "# caf" <> <<0xE9>> <> " docs/design.md §2\n"

      assert [%{target: "docs/design.md#2", line: 1}] = Citations.scan(@path, source)
    end

    test "A3: a byte-order mark does not hide a citation on the first line" do
      source = <<0xEF, 0xBB, 0xBF>> <> "# docs/design.md §1\n"

      assert [%{target: "docs/design.md#1", line: 1}] = Citations.scan(@path, source)
    end

    test "A6: CRLF lines keep the bare-section context and the line numbers" do
      source = "# docs/a.md §1\r\n# and §2\r\n"

      assert targets(Citations.scan(@path, source)) == [{"docs/a.md#1", 1}, {"docs/a.md#2", 2}]
    end

    test "A5: look-alikes are not section signs" do
      source = "# docs/a.md S1, docs/a.md &sect;2, docs/a.md §3\n"

      assert targets(Citations.scan(@path, source)) == [{"docs/a.md#3", 1}]
    end
  end
end
