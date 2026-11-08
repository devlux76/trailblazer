defmodule Trailblazer.Parse.ElixirNamesTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Parse.Elixir, as: Parser

  @path "lib/example.ex"

  describe "names the source settles" do
    test "an aliased module is called by its full name" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          alias Trailblazer.Store
          def run(x), do: Store.put(x, [])
        end
        """)

      assert [%{kind: "calls", target: "Trailblazer.Store.put", arity: 2}] =
               calls(parsed)
    end

    test "an alias with :as is called by its full name" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          alias Trailblazer.Store, as: S
          def run(x), do: S.put(x, [])
        end
        """)

      assert [%{target: "Trailblazer.Store.put", arity: 2}] = calls(parsed)
    end

    test "an aliased group is called by full name" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          alias Trailblazer.{Store, Vectors}
          def run(x), do: Vectors.collection(x)
        end
        """)

      assert [%{target: "Trailblazer.Vectors.collection", arity: 1}] = calls(parsed)
    end

    test "__MODULE__ is the module it stands in" do
      {:ok, parsed} = parse("defmodule M do\n  def run(x), do: __MODULE__.put(x)\nend\n")

      assert [%{target: "M.put", arity: 1}] = calls(parsed)
    end

    test "a local call of a function of the module is a call of the module" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          def h(x), do: x
          def run(x), do: h(x)
        end
        """)

      assert [%{target: "M.h", arity: 1}] = calls(parsed)
    end

    test "a local call with no local function is looked for in the imports" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          import Trailblazer.Store
          def run(x), do: put(x)
        end
        """)

      assert [%{target: "Trailblazer.Store.put", arity: 1}] = calls(parsed)
    end

    test "a local call with nothing to settle it keeps the module's own name" do
      {:ok, parsed} = parse("defmodule M do\n  def run(x), do: unknown(x)\nend\n")

      assert [%{target: "M.unknown", arity: 1}] = calls(parsed)
    end

    test "an alias inside a function stays inside that function" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          def a(x) do
            alias Trailblazer.Store, as: S
            S.put(x, [])
          end

          def b(x), do: S.put(x, [])
        end
        """)

      assert [
               %{target: "Trailblazer.Store.put", arity: 2, line: 4},
               %{target: "S.put", arity: 2, line: 7}
             ] = calls(parsed)
    end

    test "an import inside a function stays inside that function" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          def a(x) do
            import Trailblazer.Store
            put(x, [])
          end

          def b(x), do: put(x)
        end
        """)

      assert [
               %{target: "Trailblazer.Store.put", arity: 2, line: 4},
               %{target: "M.put", arity: 1, line: 7}
             ] = calls(parsed)
    end

    test "a nested defmodule binds its own name in the module around it" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          defmodule Child do
            def helper(x), do: x
          end

          def run(x), do: Child.helper(x)
        end
        """)

      assert [%{target: "M.Child.helper", arity: 1}] = calls(parsed)
    end

    test "__MODULE__ names the module around it in a nested call" do
      {:ok, parsed} = parse("defmodule M do\n  def run(x), do: __MODULE__.Child.put(x)\nend\n")

      assert [%{target: "M.Child.put", arity: 1}] = calls(parsed)
    end

    test "an alias group with a multi-segment prefix binds each member under it" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          alias Trailblazer, as: T
          alias T.Parse.{Elixir, TreeSitter}

          def a(x), do: Elixir.parse(x)
          def b(x), do: TreeSitter.parse(x, :javascript, "y")
        end
        """)

      assert [
               %{target: "Trailblazer.Parse.Elixir.parse", arity: 1},
               %{target: "Trailblazer.Parse.TreeSitter.parse", arity: 3}
             ] = calls(parsed)
    end

    test "an import with only settles the names it admits" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          import Trailblazer.Vectors, only: [nearest: 2]
          import Trailblazer.Store, only: [put: 2]
          def run(x), do: put(x, [])
        end
        """)

      assert [%{target: "Trailblazer.Store.put", arity: 2}] = calls(parsed)
    end

    test "an import with except does not admit the name it excludes" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          import Trailblazer.Vectors, except: [put: 1]
          import Trailblazer.Store, only: [put: 1]
          def run(x), do: put(x)
        end
        """)

      assert [%{target: "Trailblazer.Store.put", arity: 1}] = calls(parsed)
    end

    test "the import that admits the name settles it, not the first one" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          import Foo, only: [foo: 0]
          import Bar, only: [bar: 0]
          def run, do: bar()
        end
        """)

      assert [%{target: "Bar.bar", arity: 0}] = calls(parsed)
    end

    test "a name several imports admit is left to the resolver" do
      {:ok, parsed} =
        parse("""
        defmodule M do
          import Foo
          import Bar
          def run, do: shared()
        end
        """)

      assert [
               %{target: "Foo.shared", arity: 0, ambiguous: true},
               %{target: "Bar.shared", arity: 0, ambiguous: true}
             ] = calls(parsed)
    end

    test "an empty only filter imports nothing" do
      {:ok, parsed} = parse("defmodule M do\n import Foo, only: []\n def run, do: f()\nend")
      assert [%{target: "M.f", ambiguous: false}] = calls(parsed)
    end

    test "an empty only filter leaves the other import as the settled target" do
      {:ok, parsed} =
        parse("defmodule M do\n import Foo, only: []\n import Bar\n def run, do: f()\nend")

      assert [%{target: "Bar.f", ambiguous: false}] = calls(parsed)
    end
  end

  defp parse(source), do: Parser.parse(@path, source)

  defp refs(parsed), do: parsed.refs

  defp calls(parsed) do
    Enum.filter(refs(parsed), &(&1.kind in ["calls", "references", "tests"]))
  end
end
