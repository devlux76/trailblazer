defmodule Trailblazer.Parse.ElixirCallsTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Parse.Elixir, as: Parser

  @path "lib/example.ex"

  describe "the caller a reference comes from" do
    test "a local call is a reference from the function that makes it" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          def run(x), do: helper(x)
          def helper(x), do: x
        end
        """)

      assert [%{kind: "calls", target: "M.helper", arity: 1, from_key: key}] = calls(parsed)
      assert key == "elixir:function:#{@path}#M.run/1"
    end

    test "a local call inside a test is what the test exercises" do
      {:ok, parsed} =
        parse("""
        defmodule ExampleTest do
          use ExUnit.Case

          test "local" do
            helper()
          end

          def helper, do: :ok
        end
        """)

      assert [%{kind: "tests", target: "ExampleTest.helper", arity: 0, from_key: key}] =
               calls(parsed)

      assert key == "elixir:test:#{@path}#ExampleTest.local"
    end

    test "a local call is looked for in the imports where it is written" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          def a(x) do
            import Trailblazer.Store
            put(x, [])
          end

          def b(x) do
            import Trailblazer.Vectors
            put(x)
          end
        end
        """)

      assert [
               %{target: "Trailblazer.Store.put", arity: 2, line: 4},
               %{target: "Trailblazer.Vectors.put", arity: 1, line: 9}
             ] = calls(parsed)
    end

    test "a nested module inherits the aliases and imports of the module around it" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          alias Trailblazer.Store
          import Trailblazer.Vectors

          defmodule N do
            def run(x), do: put(x)
            def other(x), do: Store.put(x, [])
          end
        end
        """)

      assert [
               %{target: "Trailblazer.Vectors.put", arity: 1, from_key: run},
               %{target: "Trailblazer.Store.put", arity: 2}
             ] = calls(parsed)

      assert run == "elixir:function:#{@path}#M.N.run/1"
    end
  end

  describe "the arguments of a call" do
    test "a call inside the arguments of a remote call" do
      {:ok, parsed} = parse("defmodule M do\n  def run(x), do: Outer.f(Inner.g(x))\nend\n")

      assert [%{target: "Outer.f", arity: 1}, %{target: "Inner.g", arity: 1}] = calls(parsed)
    end

    test "a call inside the arguments of a local call" do
      {:ok, parsed} = parse("defmodule M do\n  def run(x), do: f(Inner.h(x))\nend\n")

      assert [%{target: "M.f", arity: 1}, %{target: "Inner.h", arity: 1}] = calls(parsed)
    end

    test "a call inside the arguments of the right side of a pipe" do
      {:ok, parsed} = parse("defmodule M do\n  def run(x), do: x |> Outer.f(Inner.k())\nend\n")

      assert [%{target: "Outer.f", arity: 2}, %{target: "Inner.k", arity: 0}] = calls(parsed)
    end

    test "a capture inside the arguments of a call" do
      {:ok, parsed} =
        parse("defmodule M do\n  def run(xs), do: Enum.map(xs, &Inner.p/1)\nend\n")

      assert [%{target: "Enum.map", arity: 2}, %{kind: "references", target: "Inner.p", arity: 1}] =
               calls(parsed)
    end

    test "a call inside a callback passed to another call comes from the caller" do
      {:ok, parsed} =
        parse("defmodule M do\n  def run(xs), do: Enum.map(xs, &Inner.p/1) + Outer.g()\nend\n")

      assert [
               %{target: "Enum.map", arity: 2, from_key: key},
               %{kind: "references", target: "Inner.p", arity: 1},
               %{target: "Outer.g", arity: 0}
             ] = calls(parsed)

      assert key == "elixir:function:#{@path}#M.run/1"
    end
  end

  describe "pipelines and captures" do
    test "the right side of a pipe takes the left side as an argument" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          def run(x), do: x |> Trailblazer.Store.put([])
        end
        """)

      assert [%{target: "Trailblazer.Store.put", arity: 2}] = calls(parsed)
    end

    test "a piped local call counts the piped value" do
      {:ok, parsed} = parse("defmodule M do\n  def run(x), do: x |> f(1)\nend\n")

      assert [%{target: "M.f", arity: 2}] = calls(parsed)
    end

    test "a remote capture is a reference" do
      {:ok, parsed} = parse("defmodule M do\n  def run, do: &Trailblazer.Store.put/2\nend\n")

      assert [%{kind: "references", target: "Trailblazer.Store.put", arity: 2}] = calls(parsed)
    end

    test "a local capture is a reference of the module's own function" do
      {:ok, parsed} =
        parse("defmodule M do\n  def f(x), do: x\n  def run, do: &f/1\nend\n")

      assert [%{kind: "references", target: "M.f", arity: 1}] = calls(parsed)
    end

    test "a capture of __MODULE__ is a reference of that module" do
      {:ok, parsed} = parse("defmodule M do\n  def run, do: &__MODULE__.put/2\nend\n")

      assert [%{kind: "references", target: "M.put", arity: 2}] = calls(parsed)
    end
  end

  defp parse(source), do: Parser.parse(@path, source)

  defp refs(parsed), do: parsed.refs

  defp calls(parsed) do
    Enum.filter(refs(parsed), &(&1.kind in ["calls", "references", "tests"]))
  end
end
