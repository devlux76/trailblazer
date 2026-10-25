defmodule Trailblazer.QueryTest do
  use ExUnit.Case, async: false

  alias Trailblazer.{Backstop, Query, Store}
  alias Trailblazer.Parse.Elixir, as: ElixirParser

  # A small repository written to a temporary directory, parsed by the real
  # Elixir parser, with its edges written by hand (Task 6 resolves them; the
  # questions only read them).
  @files %{
    "lib/store.ex" => """
    defmodule Mini.Store do
      def put(a, b), do: {a, b}
    end
    """,
    "lib/app.ex" => """
    defmodule Mini.App do
      alias Mini.Store

      def run do
        Store.put(1, 2)
      end
    end
    """,
    "lib/web.ex" => """
    defmodule Mini.Web do
      def handle, do: Mini.App.run()
      def ready?, do: true
    end
    """,
    "test/support/store.ex" => """
    defmodule Mini.Store do
      def put(a, b), do: [a, b]
    end
    """,
    "lib/odd:name.ex" => """
    defmodule Mini.Odd do
      def colon, do: :saveHikes
    end
    """
  }

  defmodule Fresh do
    def ensure_fresh(repo, files) do
      send(Process.get(:query_test_pid) || self(), {:fresh, repo, files})
      :ok
    end
  end

  defmodule FakeEmbed do
    def query(_text, _opts), do: {:ok, [0.1]}
  end

  defmodule DownEmbed do
    def query(_text, _opts), do: {:error, :embedder_down}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "trailblazer-query-#{System.unique_integer([:positive])}")

    for {path, source} <- @files do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), source)
    end

    {:ok, repo_id} = Store.add_repo(dir)

    for {path, source} <- @files do
      {:ok, parsed} = ElixirParser.parse(path, source)
      :ok = Store.replace_file(repo_id, path, Map.put(parsed, :hash, path))
    end

    node = fn path, qualified ->
      Enum.find(Store.nodes_in_file(repo_id, path), &(&1.qualified == qualified)).id
    end

    run = node.("lib/app.ex", "Mini.App.run/0")
    put = node.("lib/store.ex", "Mini.Store.put/2")
    put2 = node.("test/support/store.ex", "Mini.Store.put/2")
    handle = node.("lib/web.ex", "Mini.Web.handle/0")

    :ok =
      Store.put_edges(repo_id, [
        %{from_id: run, to_id: put, kind: "calls", uncertain: true, line: 5},
        %{from_id: run, to_id: put2, kind: "calls", uncertain: true, line: 5},
        %{from_id: handle, to_id: run, kind: "calls", uncertain: false, line: 2},
        # a cycle, so the walk has to stop on its own
        %{from_id: put, to_id: handle, kind: "calls", uncertain: false, line: 2}
      ])

    Process.put(:query_test_pid, self())
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, opts: [indexer: Fresh], ids: %{run: run, put: put, put2: put2, handle: handle}}
  end

  describe "where_declared" do
    test "a bare name finds every definition of it", %{dir: dir, opts: opts} do
      assert [a, b] = Query.where_declared(dir, "put", opts)
      assert Enum.sort([a.path, b.path]) == ["lib/store.ex", "test/support/store.ex"]

      assert Map.keys(a) |> Enum.sort() ==
               ~w(end_line id kind path qualified signature stale start_line)a
    end

    test "a qualified name, with or without its arity", %{dir: dir, opts: opts} do
      assert [_, _] = Query.where_declared(dir, "Mini.Store.put/2", opts)
      assert [_, _] = Query.where_declared(dir, "Mini.Store.put", opts)
      assert [%{qualified: "Mini.App.run/0"}] = Query.where_declared(dir, "Mini.App.run", opts)
    end

    test "A10: punctuation in a name is literal", %{dir: dir, opts: opts} do
      assert [%{qualified: "Mini.Web.ready?/0"}] = Query.where_declared(dir, "ready?", opts)
      assert [] = Query.where_declared(dir, ".*", opts)
    end

    test "a position gives the definitions its reference leads to", %{dir: dir, opts: opts} do
      assert [a, b] = Query.where_declared(dir, {"lib/app.ex", 5}, opts)
      assert Enum.map([a, b], & &1.qualified) == ["Mini.Store.put/2", "Mini.Store.put/2"]
      assert_received {:fresh, ^dir, ["lib/app.ex"]}
    end
  end

  describe "who_uses and impact_of" do
    test "B8: who uses a twice-defined name is uncertain", %{dir: dir, opts: opts, ids: ids} do
      assert [%{node: %{qualified: "Mini.App.run/0"}, kind: "calls", line: 5, uncertain: true}] =
               Query.who_uses(dir, ids.put, opts)
    end

    # Found by the release smoke test: two definitions behind one name gave
    # two rows that looked the same.
    test "each use names the definition it uses", %{dir: dir, opts: opts} do
      uses = Query.who_uses(dir, "Mini.Store.put/2", opts)

      assert [%{node: %{qualified: "Mini.App.run/0"}}, %{node: %{qualified: "Mini.App.run/0"}}] =
               uses

      assert uses |> Enum.map(& &1.target.path) |> Enum.sort() == [
               "lib/store.ex",
               "test/support/store.ex"
             ]

      assert Enum.all?(uses, &(&1.target.qualified == "Mini.Store.put/2"))
    end

    test "who_uses takes a name as well as an id", %{dir: dir, opts: opts} do
      assert [%{node: %{qualified: "Mini.Web.handle/0"}, uncertain: false}] =
               Query.who_uses(dir, "Mini.App.run", opts)
    end

    test "impact walks the users breadth first, and stops on a cycle", %{
      dir: dir,
      opts: opts,
      ids: ids
    } do
      impact = Query.impact_of(dir, ids.put, 5, opts)

      assert [
               %{
                 node: %{qualified: "Mini.App.run/0"},
                 distance: 1,
                 via: "calls",
                 uncertain: true
               },
               %{node: %{qualified: "Mini.Web.handle/0"}, distance: 2, via: "calls"}
             ] = Enum.reject(impact, &(&1.node.id == ids.put))

      assert Enum.count(impact, &(&1.node.id == ids.put)) <= 1
    end

    test "impact honours its depth", %{dir: dir, opts: opts, ids: ids} do
      assert [%{distance: 1}] = Query.impact_of(dir, ids.put, 1, opts)
    end
  end

  describe "read_range" do
    test "the lines asked for", %{dir: dir, opts: opts} do
      assert {:ok, "  def run do\n    Store.put(1, 2)"} =
               Query.read_range(dir, "lib/app.ex", 4, 5, opts)

      assert_received {:fresh, ^dir, ["lib/app.ex"]}
    end

    test "a range running past the end stops at the end", %{dir: dir, opts: opts} do
      assert {:ok, "end"} = Query.read_range(dir, "lib/app.ex", 7, 99, opts)
    end

    test "outside the repository is refused", %{dir: dir, opts: opts} do
      assert {:error, :outside_repo} = Query.read_range(dir, "../escape", 1, 2, opts)
    end

    test "D4: a range that is not one is refused", %{dir: dir, opts: opts} do
      assert {:error, :bad_range} = Query.read_range(dir, "lib/app.ex", 0, 2, opts)
      assert {:error, :bad_range} = Query.read_range(dir, "lib/app.ex", 5, 4, opts)
      assert {:error, :bad_range} = Query.read_range(dir, "lib/app.ex", "1", 2, opts)
    end
  end

  describe "search" do
    defmodule NoVectors do
      def nearest(_repo, _vector, _limit, _opts), do: {:ok, []}
    end

    # B9: a guarded search runs the embedder and Qdrant in a process of its
    # own, so a fake is given what it needs in `opts`, never in the caller's
    # process dictionary.
    defmodule SomeVectors do
      def nearest(_repo, _vector, _limit, opts),
        do: {:ok, [{Keyword.fetch!(opts, :hit_id), 0.8}, {999_999_999, 0.7}]}
    end

    defmodule HangingEmbed do
      def query(_text, opts) do
        send(opts[:probe], {:embed_hanging, self()})
        receive do: (:never -> :ok)
      end
    end

    defmodule DeadEmbed do
      def query(_text, _opts), do: exit(:embedder_crashed)
    end

    test "an exact name is found with no vectors", %{dir: dir, opts: opts} do
      opts = opts ++ [embed: FakeEmbed, vectors: NoVectors]

      assert [%{node: %{qualified: "Mini.App.run/0"}, via: :exact} | _] =
               Query.search(dir, "run", 10, opts)
    end

    test "vector hits are mapped to nodes, and other repos' ids are dropped", %{
      dir: dir,
      opts: opts,
      ids: ids
    } do
      opts = opts ++ [embed: FakeEmbed, vectors: SomeVectors, hit_id: ids.handle]

      assert [%{node: %{id: id}, via: :vector, score: 0.8}] =
               Query.search(dir, "zzz unmatched", 10, opts)

      assert id == ids.handle
    end

    test "A9/A10: text is matched literally, in a file whose name holds a colon", %{
      dir: dir,
      opts: opts
    } do
      opts = opts ++ [embed: DownEmbed, vectors: NoVectors]

      assert [%{node: %{qualified: "Mini.Odd.colon/0", path: "lib/odd:name.ex"}, via: :exact}] =
               Query.search(dir, ":saveHikes", 10, opts)

      assert [] = Query.search(dir, "--version", 10, opts)
      assert [] = Query.search(dir, "$(touch /tmp/trailblazer-pwned)", 10, opts)
      refute File.exists?("/tmp/trailblazer-pwned")
    end

    test "the embedder down still answers from names and text", %{dir: dir, opts: opts} do
      opts = opts ++ [embed: DownEmbed, vectors: NoVectors]
      assert [%{via: :exact} | _] = Query.search(dir, "handle", 10, opts)
    end

    test "B9: a search that loses its backstop answers by name and text, with no vector hits", %{
      dir: dir,
      opts: opts
    } do
      Application.put_env(:trailblazer, :backstop_search_ms, 20)
      on_exit(fn -> Application.delete_env(:trailblazer, :backstop_search_ms) end)

      opts = opts ++ [embed: HangingEmbed, vectors: NoVectors, probe: self()]

      assert [%{node: %{qualified: "Mini.Web.handle/0"}, via: :exact} | _] =
               Query.search(dir, "handle", 10, opts)

      # the hanging embedder was killed with its backstop, and nothing is left armed
      assert_receive {:embed_hanging, pid}
      refute Process.alive?(pid)
      assert Backstop.armed() == 0
    end

    test "an embedder that crashes under its backstop answers by name and text", %{
      dir: dir,
      opts: opts
    } do
      opts = opts ++ [embed: DeadEmbed, vectors: NoVectors]

      assert [%{node: %{qualified: "Mini.Web.handle/0"}, via: :exact} | _] =
               Query.search(dir, "handle", 10, opts)

      assert Backstop.armed() == 0
    end
  end

  # The plan's Task 9 Step 1, on the shared fixture with real parsers and the
  # real resolver (Task 6).
  describe "on the mini fixture, resolved" do
    setup do
      root = Path.expand("../fixtures/mini", __DIR__)
      dir = Path.join(System.tmp_dir!(), "trailblazer-mini-#{System.unique_integer([:positive])}")
      File.cp_r!(root, dir)
      {:ok, repo_id} = Store.add_repo(dir)

      for file <- Trailblazer.Files.list(dir) do
        source = File.read!(Path.join(dir, file.path))

        {:ok, parsed} =
          case file.lang do
            :elixir -> ElixirParser.parse(file.path, source)
            :markdown -> Trailblazer.Parse.Markdown.parse(file.path, source)
            lang -> Trailblazer.Parse.TreeSitter.parse(file.path, lang, source)
          end

        refs = parsed.refs ++ Trailblazer.Parse.Citations.scan(file.path, source, parsed.nodes)

        :ok =
          Store.replace_file(repo_id, file.path, %{
            hash: file.path,
            nodes: parsed.nodes,
            refs: refs
          })
      end

      :ok = Store.put_edges(repo_id, Trailblazer.Graph.Resolve.edges(repo_id))
      on_exit(fn -> File.rm_rf!(dir) end)
      %{mini: dir}
    end

    test "the plan's checks", %{mini: mini, opts: opts} do
      opts = opts ++ [embed: FakeEmbed, vectors: __MODULE__.NoVectors]

      assert [_, _] = Query.where_declared(mini, "put", opts)

      [store_put] =
        mini
        |> Query.where_declared("Mini.Store.put/2", opts)
        |> Enum.filter(&(&1.path == "lib/store.ex"))

      assert [%{node: %{qualified: "Mini.App.run/1"}, uncertain: true}] =
               Query.who_uses(mini, store_put.id, opts)

      [save] = Query.where_declared(mini, "saveHikes", opts)

      assert [%{node: %{qualified: "renderList"}, distance: 1} | _] =
               Query.impact_of(mini, save.id, 3, opts)

      assert {:error, :outside_repo} = Query.read_range(mini, "../escape", 1, 2, opts)

      assert [%{node: %{qualified: "saveHikes"}, via: :exact} | _] =
               Query.search(mini, "saveHikes", 10, opts)
    end
  end

  test "a repository that is not registered is not watched", %{opts: opts} do
    assert {:error, :not_watched} = Query.where_declared("/nonexistent/repo", "put", opts)
  end
end
