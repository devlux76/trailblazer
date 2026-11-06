defmodule Trailblazer.Loop.ToolsTest do
  use ExUnit.Case, async: false

  alias Trailblazer.Loop.Tools
  alias Trailblazer.Parse.Elixir, as: ElixirParser
  alias Trailblazer.Store

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
    end
    """
  }

  defmodule Fresh do
    def ensure_fresh(_repo, _files), do: :ok
  end

  defmodule DownEmbed do
    def query(_text, _opts), do: {:error, :embedder_down}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "trailblazer-tools-#{System.unique_integer([:positive])}")

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

    :ok =
      Store.put_edges(repo_id, [
        %{
          from_id: node.("lib/app.ex", "Mini.App.run/0"),
          to_id: node.("lib/store.ex", "Mini.Store.put/2"),
          kind: "calls",
          uncertain: false,
          line: 5
        },
        %{
          from_id: node.("lib/web.ex", "Mini.Web.handle/0"),
          to_id: node.("lib/app.ex", "Mini.App.run/0"),
          kind: "calls",
          uncertain: false,
          line: 2
        }
      ])

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, opts: [indexer: Fresh, embed: DownEmbed]}
  end

  test "native edits validate complete strings without interpreting code or losing newlines" do
    blocks = [%{path: "lib/new.ex", search: "", replace: "def x(), do: \"a,b<c>\"\n"}]
    assert {:ok, ^blocks} = Tools.edit_blocks(Jason.encode!(%{blocks: blocks}))

    for invalid <- [
          %{blocks: []},
          %{blocks: [%{path: "x", search: nil, replace: "x"}]},
          %{blocks: blocks, command: "untrusted"},
          %{blocks: [42]}
        ] do
      assert {:error, _} = Tools.edit_blocks(Jason.encode!(invalid))
    end
  end

  test "five tools, each an OpenAI function with a JSON schema" do
    defs = Tools.definitions()
    assert Enum.map(defs, & &1.function.name) == ~w(where uses impact read search)

    for d <- defs do
      assert d.type == "function"
      assert d.function.parameters.type == "object"
      assert is_binary(d.function.description)
      assert d.function.parameters.required != []
    end
  end

  test "structured replies accept only whole schema-valid JSON without changing code bytes" do
    blocks = [%{path: "new.ts", search: "", replace: "const x = \\\"literal\\\\n\\\"\n"}]
    array = Jason.encode!(blocks)

    for text <- [array, Jason.encode!(%{blocks: blocks}), "```json\n#{array}\n```"] do
      assert {:ok, ^blocks} = Tools.text_edit_blocks(text)
    end

    for text <- [
          "Here are edits:\n```json\n#{array}\n```",
          array <> " trailing",
          Jason.encode!(%{blocks: blocks, command: "untrusted"}),
          "[]",
          ~s([{"path":"x","search":null,"replace":"x"}])
        ] do
      refute match?({:ok, _}, Tools.text_edit_blocks(text))
    end
  end

  test "where: one compact line per definition, with its place", %{dir: dir, opts: opts} do
    text = Tools.call(dir, "where", ~s({"name": "put"}), opts)
    assert text =~ "Mini.Store.put/2"
    assert text =~ "lib/store.ex:2"
  end

  test "uses and impact name the callers and their distance", %{dir: dir, opts: opts} do
    uses = Tools.call(dir, "uses", ~s({"name": "Mini.Store.put/2"}), opts)
    assert uses =~ "lib/app.ex:5"
    assert uses =~ "Mini.App.run/0"

    impact = Tools.call(dir, "impact", %{"name" => "Mini.Store.put/2", "depth" => 2}, opts)
    assert impact =~ "Mini.App.run/0"
    assert impact =~ "Mini.Web.handle/0"
    assert impact =~ ~r/2 .*Mini\.Web\.handle/
  end

  test "read gives numbered lines, from the worktree when there is one", %{dir: dir, opts: opts} do
    text = Tools.call(dir, "read", ~s({"path": "lib/app.ex", "start": 4, "end": 5}), opts)
    assert text =~ "4| " and text =~ "5|     Store.put(1, 2)"
    refute text =~ "defmodule"

    worktree = dir <> "-wt"
    File.mkdir_p!(Path.join(worktree, "lib"))
    File.write!(Path.join(worktree, "lib/app.ex"), "edited\n")
    on_exit(fn -> File.rm_rf!(worktree) end)

    assert Tools.call(%{repo: dir, worktree: worktree}, "read", ~s({"path": "lib/app.ex"}), opts) =~
             "1| edited"
  end

  test "search answers from names when the embedder is down", %{dir: dir, opts: opts} do
    assert Tools.call(dir, "search", ~s({"query": "put"}), opts) =~ "Mini.Store.put/2"
  end

  test "D4: bad calls are error text, never exceptions", %{dir: dir, opts: opts} do
    assert Tools.call(dir, "rm", "{}", opts) =~ ~r/^error: no tool named "rm"/
    assert Tools.call(dir, "where", "{not json", opts) =~ ~r/^error: .*JSON/
    assert Tools.call(dir, "where", ~s({"name": 3}), opts) =~ ~r/^error: where needs "name"/
    assert Tools.call(dir, "read", ~s({"path": "../../etc/passwd"}), opts) =~ ~r/^error: /
    assert Tools.call(dir, "read", ~s({"path": "lib/app.ex", "start": 0}), opts) =~ ~r/^error: /
    assert Tools.call(dir, "read", ~s({"path": "lib/nope.ex"}), opts) =~ ~r/^error: /

    assert Tools.call(
             "/tmp/not-watched-#{System.unique_integer()}",
             "where",
             ~s({"name": "x"}),
             opts
           ) =~
             ~r/^error: /
  end

  test "an empty answer says so, in words", %{dir: dir, opts: opts} do
    assert Tools.call(dir, "where", ~s({"name": "nothing_here"}), opts) =~ "no definition"
  end

  test "H1: answers are capped", %{dir: dir, opts: opts} do
    File.write!(Path.join(dir, "lib/big.ex"), String.duplicate("x = 1234567890\n", 5_000))
    text = Tools.call(dir, "read", ~s({"path": "lib/big.ex", "start": 1, "end": 5000}), opts)
    assert String.length(text) <= Tools.cap() + 200
    assert text =~ "cut at line 400 of 5000: read again from 401"

    # with no range, the read still says where it stopped
    assert Tools.call(dir, "read", ~s({"path": "lib/big.ex"}), opts) =~ "cut at line 400"

    # long lines reach the character cap before the line limit
    File.write!(
      Path.join(dir, "lib/wide.ex"),
      String.duplicate(String.duplicate("y", 100) <> "\n", 400)
    )

    wide = Tools.call(dir, "read", ~s({"path": "lib/wide.ex"}), opts)
    assert String.length(wide) <= Tools.cap() + 200
    assert wide =~ "cut here"
  end

  test "an invented absolute root on read reads the repository-relative file, with a note", %{
    dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "src/core"))
    File.write!(Path.join(dir, "src/core/contact.ts"), "x\n")

    text = Tools.call(dir, "read", ~s({"path": "/home/someone/workspace/src/core/contact.ts"}))
    assert text =~ "outside the repository; read src/core/contact.ts"
    assert text =~ "path: src/core/contact.ts"
    assert text =~ "1| x"

    text = Tools.call(dir, "read", ~s({"path": "/etc/passwd"}))
    assert text =~ "paths are repository-relative"
    refute text =~ "did you mean"
  end
end
