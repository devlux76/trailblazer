defmodule Trailblazer.DefaultModuleEdgesTest do
  use ExUnit.Case, async: false

  alias Trailblazer.{Graph.Resolve, Query, Store}
  alias Trailblazer.Parse.Elixir, as: ElixirParser

  # A call through a variable bound to a default module is resolved to that
  # module's definition as an uncertain edge carrying its provenance. A variable
  # bound twice gives no such edge, and a settled call carries no provenance.
  @files %{
    "lib/workspace.ex" => """
    defmodule Mini.Workspace do
      def close(ws), do: ws
    end
    """,
    "lib/loop.ex" => """
    defmodule Mini.Loop do
      alias Mini.Workspace

      def succeeded(st, a, b, c) do
        workspace = mod(st, :workspace, Workspace)
        workspace.close(st)
      end

      def direct(st), do: Workspace.close(st)
    end
    """,
    "lib/reassigned.ex" => """
    defmodule Mini.Reassigned do
      alias Mini.Workspace

      def run(st, other) do
        workspace = mod(st, :workspace, Workspace)
        workspace = other
        workspace.close(st)
      end
    end
    """
  }

  defmodule Fresh do
    def ensure_fresh(_repo, _files), do: :ok
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "trailblazer-default-edges-#{System.unique_integer([:positive])}"
      )

    for {path, source} <- @files do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), source)
    end

    {:ok, repo_id} = Store.add_repo(dir)

    for {path, source} <- @files do
      {:ok, parsed} = ElixirParser.parse(path, source)
      :ok = Store.replace_file(repo_id, path, Map.put(parsed, :hash, path))
    end

    :ok = Store.put_edges(repo_id, Resolve.edges(repo_id))
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, opts: [indexer: Fresh]}
  end

  test "uses of a definition include the call made through its default module", %{
    dir: dir,
    opts: opts
  } do
    [close] = Query.where_declared(dir, "Mini.Workspace.close/1", opts)
    uses = Query.who_uses(dir, close.id, opts)

    assert [guessed] = Enum.filter(uses, &(&1.node.qualified == "Mini.Loop.succeeded/4"))

    assert %{kind: "calls", uncertain: true, provenance: "default_module"} = guessed
  end

  test "a settled call is not marked with any provenance", %{dir: dir, opts: opts} do
    [close] = Query.where_declared(dir, "Mini.Workspace.close/1", opts)
    uses = Query.who_uses(dir, close.id, opts)

    assert [settled] = Enum.filter(uses, &(&1.node.qualified == "Mini.Loop.direct/1"))
    assert settled.uncertain == false
    refute Map.has_key?(settled, :provenance)
  end

  test "a variable bound twice leaves no edge from its function", %{dir: dir, opts: opts} do
    [close] = Query.where_declared(dir, "Mini.Workspace.close/1", opts)

    refute Enum.any?(
             Query.who_uses(dir, close.id, opts),
             &(&1.node.qualified == "Mini.Reassigned.run/2")
           )
  end
end
