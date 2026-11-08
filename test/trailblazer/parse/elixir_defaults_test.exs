defmodule Trailblazer.Parse.ElixirDefaultsTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Parse.Elixir, as: Parser

  @path "lib/example.ex"

  describe "a call through a variable bound to a default module" do
    test "mod/3 with an alias default reads as a guessed call to that module" do
      {:ok, parsed} =
        parse("""
        defmodule Loop do
          alias Trailblazer.Loop.Workspace

          def succeeded(st, a, b, c) do
            workspace = mod(st, :workspace, Workspace)
            workspace.close(st.ws)
          end
        end
        """)

      assert [
               %{
                 kind: "calls",
                 target: "Trailblazer.Loop.Workspace.close",
                 arity: 1,
                 ambiguous: true,
                 provenance: "default_module",
                 from_key: key
               }
             ] = guessed(parsed)

      assert key == "elixir:function:#{@path}#Loop.succeeded/4"
    end

    test "Keyword.get/3 with an alias default reads the same way" do
      {:ok, parsed} =
        parse("""
        defmodule Loop do
          alias Trailblazer.Loop.Workspace

          def run(opts) do
            ws = Keyword.get(opts, :workspace, Workspace)
            ws.close(opts)
          end
        end
        """)

      assert [
               %{
                 target: "Trailblazer.Loop.Workspace.close",
                 ambiguous: true,
                 provenance: "default_module"
               }
             ] = guessed(parsed)
    end

    test "a variable bound twice gives no such call" do
      {:ok, parsed} =
        parse("""
        defmodule Loop do
          alias Trailblazer.Loop.Workspace

          def run(st, other) do
            workspace = mod(st, :workspace, Workspace)
            workspace = other
            workspace.close(st)
          end
        end
        """)

      refute Enum.any?(calls(parsed), &(&1.provenance == "default_module"))
      assert Enum.any?(calls(parsed), &(&1.target == "?.close" and &1.ambiguous == false))
    end

    test "a variable bound from an ordinary call gives no such call" do
      {:ok, parsed} =
        parse("""
        defmodule Loop do
          alias Trailblazer.Loop.Workspace

          def run(st) do
            workspace = pick(st)
            workspace.close(st)
          end
        end
        """)

      refute Enum.any?(calls(parsed), &(&1.provenance == "default_module"))
    end

    test "a parameter of the same name gives no such call" do
      {:ok, parsed} =
        parse("""
        defmodule Loop do
          alias Trailblazer.Loop.Workspace

          def run(workspace, st) do
            workspace = mod(st, :workspace, Workspace)
            workspace.close(st)
          end
        end
        """)

      refute Enum.any?(calls(parsed), &(&1.provenance == "default_module"))
    end

    test "a variable rebound in a case clause gives no such call" do
      {:ok, parsed} =
        parse("""
        defmodule Loop do
          alias Trailblazer.Loop.Workspace

          def run(st) do
            workspace = mod(st, :workspace, Workspace)

            case st do
              {:ok, workspace} -> workspace.close(st)
              _ -> :none
            end
          end
        end
        """)

      refute Enum.any?(calls(parsed), &(&1.provenance == "default_module"))
    end

    test "a settled call keeps no provenance" do
      {:ok, parsed} =
        parse("""
        defmodule Loop do
          alias Trailblazer.Loop.Workspace

          def run(st) do
            Workspace.close(st)
          end
        end
        """)

      assert [%{target: "Trailblazer.Loop.Workspace.close", ambiguous: false} = ref] =
               calls(parsed)

      assert ref.provenance == nil
    end
  end

  defp parse(source), do: Parser.parse(@path, source)

  defp calls(parsed), do: Enum.filter(parsed.refs, &(&1.kind == "calls"))
  defp guessed(parsed), do: Enum.filter(calls(parsed), &(&1.provenance == "default_module"))
end
