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

  defp functions(parsed) do
    parsed.nodes |> Enum.filter(&(&1.kind == "function")) |> Enum.sort_by(& &1.start_line)
  end

  defp calls(parsed) do
    Enum.filter(refs(parsed), &(&1.kind in ["calls", "references", "tests"]))
  end

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
