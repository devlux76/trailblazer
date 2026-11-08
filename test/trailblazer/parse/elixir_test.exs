defmodule Trailblazer.Parse.ElixirTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Parse.Elixir, as: Parser

  @path "lib/example.ex"

  test "a leading UTF-8 BOM does not hide a module or shift its lines" do
    source = "defmodule M do\n  def f, do: :ok\nend\n"
    assert {:ok, plain} = Parser.parse(@path, source)
    assert {:ok, bom} = Parser.parse(@path, <<0xEF, 0xBB, 0xBF>> <> source)

    assert Enum.map(bom.nodes, &{&1.qualified, &1.start_line, &1.end_line}) ==
             Enum.map(plain.nodes, &{&1.qualified, &1.start_line, &1.end_line})

    assert Enum.any?(bom.refs, &(&1.target == "M.f/0"))
  end

  test "contains targets use qualified names even when the path contains a hash" do
    {:ok, parsed} =
      Parser.parse(
        "lib/a#b.ex",
        "defmodule M do\n defmodule N do\n @type t :: integer()\n def f, do: :ok\n end\nend"
      )

    contains = Enum.filter(parsed.refs, &(&1.kind == "contains"))
    assert Enum.map(contains, & &1.target) == ["M.N", "M.N.t", "M.N.f/0"]
    assert Enum.all?(contains, &String.contains?(&1.from_key, "lib/a#b.ex#"))
  end

  describe "modules" do
    test "a nested defmodule is a module of its own" do
      {:ok, parsed} = parse("defmodule A do\n  defmodule B do\n  end\nend\n")

      assert ["A", "A.B"] = Enum.map(nodes(parsed), & &1.qualified)
      assert [a, b] = nodes(parsed)
      assert a.kind == "module"
      assert a.key == "elixir:module:#{@path}#A"
      assert {a.start_line, a.end_line} == {1, 4}
      assert {b.start_line, b.end_line} == {2, 3}
      assert b.key == "elixir:module:#{@path}#A.B"
    end

    test "a function inside a nested module is named after both modules" do
      {:ok, parsed} =
        parse("defmodule A do\n  defmodule B do\n    def f(x), do: x\n  end\nend\n")

      assert [outer, module, function] = nodes(parsed)
      assert {outer.kind, outer.qualified} == {"module", "A"}
      assert {module.kind, module.qualified} == {"module", "A.B"}
      assert {function.kind, function.qualified} == {"function", "A.B.f/1"}
      assert function.key == "elixir:function:#{@path}#A.B.f/1"
      assert function.name == "f"
    end
  end

  describe "functions" do
    test "the clauses of one function are one node spanning them" do
      {:ok, parsed} = parse("defmodule M do\n  def f(0), do: :zero\n  def f(n), do: n\nend\n")

      assert [function] = functions(parsed)
      assert function.qualified == "M.f/1"
      assert {function.start_line, function.end_line} == {2, 3}
    end

    test "a default argument gives a node for each arity" do
      {:ok, parsed} = parse("defmodule M do\n  def g(a, b \\\\ 1), do: a\nend\n")

      assert ["M.g/1", "M.g/2"] = Enum.map(functions(parsed), & &1.qualified)
      assert [one, two] = functions(parsed)
      assert {one.start_line, one.end_line} == {2, 2}
      assert {two.start_line, two.end_line} == {2, 2}
    end

    test "defp and defdelegate are functions" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          defp hidden(a), do: a
          defdelegate listed(a), to: Other
        end
        """)

      assert ["M.hidden/1", "M.listed/1"] = Enum.map(functions(parsed), & &1.qualified)
      assert Enum.all?(functions(parsed), &(&1.kind == "function"))
    end

    test "defmacro and defguard are macros" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          defmacro mac(a), do: a
          defguard positive(x) when is_integer(x) and x > 0
        end
        """)

      macros = Enum.filter(nodes(parsed), &(&1.kind == "macro"))

      assert ["M.mac/1", "M.positive/1"] = Enum.map(macros, & &1.qualified)
      assert ["mac", "positive"] = Enum.map(macros, & &1.name)
    end

    test "the signature is the head of the first clause" do
      {:ok, parsed} =
        parse("defmodule M do\n  def put(hikes, opts \\\\ []) do\n    :ok\n  end\nend\n")

      assert [one, two] = functions(parsed)
      assert one.signature == "put(hikes, opts \\\\ [])"
      assert two.signature == "put(hikes, opts \\\\ [])"
    end

    test "a long signature is cut at 200 characters" do
      parameters = Enum.map_join(1..40, ", ", &"argument#{String.duplicate("x", 5)}#{&1}")
      {:ok, parsed} = parse("defmodule M do\n  def wide(#{parameters}), do: nil\nend\n")

      assert [function] = functions(parsed)
      assert String.length(function.signature) == 200
      assert String.starts_with?(function.signature, "wide(")
      assert function.signature =~ "argumentxxxxx1"
    end

    test "a signature is always one line" do
      parameters = Enum.map_join(1..40, ", ", &"argument#{String.duplicate("x", 5)}#{&1}")

      {:ok, parsed} =
        parse("""
        defmodule M do
          def wide(#{parameters}), do: nil

          def wide(#{parameters}, one_more), do: nil
        end
        """)

      assert [one, two] = functions(parsed)

      for signature <- [one.signature, two.signature] do
        refute signature =~ "\n"
        assert String.length(signature) <= 200
      end

      assert String.starts_with?(one.signature, "wide( argumentxxxxx1")
    end

    test "the hash is of the definition's own source lines" do
      {:ok, parsed} =
        parse("defmodule M do\n  def f(a) do\n    a\n  end\n\n  def g, do: nil\nend\n")

      assert [f, g] = functions(parsed)
      assert f.text_hash == sha256("  def f(a) do\n    a\n  end")
      assert g.text_hash == sha256("  def g, do: nil")
    end
  end

  describe "types" do
    test "@type, @typep and @opaque are types" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          @type t :: %__MODULE__{}
          @typep key :: binary()
          @opaque handle :: reference()
        end
        """)

      types = Enum.filter(nodes(parsed), &(&1.kind == "type"))

      assert ["M.t", "M.key", "M.handle"] = Enum.map(types, & &1.qualified)
      assert Enum.all?(types, &(&1.key == "elixir:type:#{@path}#M." <> &1.name))
    end
  end

  defp parse(source), do: Parser.parse(@path, source)

  defp nodes(parsed), do: parsed.nodes

  defp functions(parsed) do
    parsed.nodes |> Enum.filter(&(&1.kind == "function")) |> Enum.sort_by(& &1.start_line)
  end

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
