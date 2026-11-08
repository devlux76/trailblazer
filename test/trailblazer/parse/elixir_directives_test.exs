defmodule Trailblazer.Parse.ElixirDirectivesTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Parse.Elixir, as: Parser

  @path "lib/example.ex"

  describe "alias, import, use and require" do
    test "each gives a reference of its own kind" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          alias Trailblazer.Store
          import Trailblazer.Vectors
          use Trailblazer
          require Logger
        end
        """)

      assert [
               %{kind: "aliases", target: "Trailblazer.Store"},
               %{kind: "imports", target: "Trailblazer.Vectors"},
               %{kind: "uses", target: "Trailblazer"},
               %{kind: "uses", target: "Logger"}
             ] =
               Enum.filter(refs(parsed), &(&1.kind in ["aliases", "imports", "uses"]))
    end

    test "the reference comes from the module it is written in" do
      {:ok, parsed} = parse("defmodule M do\n  alias Trailblazer.Store\nend\n")

      assert [%{from_key: "elixir:module:#{@path}#M", kind: "aliases", line: 2}] = refs(parsed)
    end
  end

  describe "tests" do
    @exunit """
    defmodule ExampleTest do
      use ExUnit.Case

      test "saves hikes" do
        Trailblazer.Store.put([], [])
      end

      describe "listing" do
        test "reads them back" do
          Trailblazer.Store.put([], [])
        end
      end
    end
    """

    test "a test is a node of its own" do
      {:ok, parsed} = parse(@exunit)

      tests = Enum.filter(nodes(parsed), &(&1.kind == "test"))

      assert ["saves hikes", "listing reads them back"] = Enum.map(tests, & &1.name)

      assert ["ExampleTest.saves hikes", "ExampleTest.listing reads them back"] =
               Enum.map(tests, & &1.qualified)

      assert [%{key: key} | _] = tests
      assert key == "elixir:test:#{@path}#ExampleTest.saves hikes"
    end

    test "a test inside a describe is named after both" do
      {:ok, parsed} = parse(@exunit)

      names = Enum.map(nodes(parsed), & &1.name)

      assert "listing reads them back" in names
      refute "reads them back" in names
    end

    test "a call inside a test is a reference of what the test exercises" do
      {:ok, parsed} = parse(@exunit)

      assert [%{kind: "tests", target: "Trailblazer.Store.put", arity: 2, line: 5}] =
               refs(parsed) |> Enum.filter(&(&1.kind == "tests" and &1.line == 5))
    end

    test "the reference comes from the test it is in" do
      {:ok, parsed} = parse(@exunit)

      assert [%{kind: "tests", from_key: "elixir:test:#{@path}#ExampleTest.saves hikes"}] =
               refs(parsed) |> Enum.filter(&(&1.kind == "tests" and &1.line == 5))
    end

    test "a file that does not use ExUnit has no test nodes" do
      {:ok, parsed} = parse("defmodule M do\n  def run, do: test(\"not a test\")\nend\n")

      assert [] = Enum.filter(nodes(parsed), &(&1.kind == "test"))
    end
  end

  describe "a file that does not parse" do
    test "a syntax error is a line and a message" do
      assert {:error, {line, message}} = parse("defmodule M do\n  def f(\n")
      assert is_integer(line)
      assert is_binary(message)
    end

    test "the line is where the source went wrong" do
      assert {:error, {2, _message}} = parse("defmodule M do\n  def f( do\nend\n")
    end
  end

  describe "what is not a definition" do
    test "a module contains the definitions inside it" do
      {:ok, parsed} = parse("defmodule M do\n  def f(x), do: x\n  def g(x), do: x\nend\n")

      assert [
               %{kind: "contains", target: "M.f/1", line: 2},
               %{kind: "contains", target: "M.g/1", line: 3}
             ] = Enum.filter(refs(parsed), &(&1.kind == "contains"))
    end

    test "a call at the top level of a file belongs to no definition" do
      {:ok, parsed} = parse("Trailblazer.Store.put([], [])\n")

      assert [%{kind: "calls", from_key: nil, target: "Trailblazer.Store.put"}] = refs(parsed)
    end

    test "an operator is not a call" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          def f(a, b), do: a <> b
          def g(a), do: _ = a
          def h(a), do: {:ok, a}
          def i(a), do: [a]
          def j(a), do: %{}
        end
        """)

      assert [] = calls(parsed)
    end

    test "a call inside a function is a reference from that function" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          def run(x), do: Trailblazer.Store.put(x, [])
          alias Trailblazer.Store
        end
        """)

      assert [%{kind: "calls", target: "Trailblazer.Store.put", from_key: key}] = calls(parsed)
      assert key == "elixir:function:#{@path}#M.run/1"
    end

    test "a reference at the top of a module comes from the module" do
      {:ok, parsed} = parse("defmodule M do\n  @attr Trailblazer.Store.put(1, [])\nend\n")

      assert [_attribute, _call] = calls(parsed)
      assert Enum.all?(calls(parsed), &(&1.from_key == "elixir:module:#{@path}#M"))
    end
  end

  # Found in mirai-agent's deps/nx (lib/nx/defn/compiler.ex) once vendored
  # directories were indexed: a bare `def` quotes as {:def, meta, nil}.
  test "A15: a bare def, with no head, is an expression, not a definition" do
    assert {:ok, parsed} = parse("defmodule M do\n  def\n  def f, do: :ok\nend\n")
    assert Enum.map(parsed.nodes, & &1.qualified) == ["M", "M.f/0"]
  end

  defp parse(source), do: Parser.parse(@path, source)

  defp nodes(parsed), do: parsed.nodes

  defp refs(parsed), do: parsed.refs

  defp calls(parsed) do
    Enum.filter(refs(parsed), &(&1.kind in ["calls", "references", "tests"]))
  end
end
