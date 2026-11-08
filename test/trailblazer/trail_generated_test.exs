defmodule Trailblazer.TrailGeneratedTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Trailblazer.{Store, Trail}
  alias Trailblazer.Trail.Generated

  defmodule NoFresh do
    def ensure_fresh(_repo, _files), do: :ok
  end

  defmodule FakeEmbed do
    def query(_text, _opts), do: {:ok, [0.1]}
  end

  defmodule FakeVectors do
    def nearest(_repo, _vector, _limit, _opts), do: {:ok, []}
    def scores(_repo, _vector, _ids, _opts), do: {:ok, %{}}
  end

  @bundle "export function saveHikes(hikes: string[]): number {\n  return hikes.length;\n}\n"

  describe "glob matcher" do
    test "globs match as the pre-commit hook does: a star crosses slashes, a question mark is one character",
         %{tmp_dir: dir} do
      File.write!(Path.join(dir, ".linelimit-ignore"), "v6/plugins/*/dist/*.js\n")
      matches? = Generated.matcher(dir)

      assert matches?.("v6/plugins/codex/dist/vx.js")
      refute matches?.("v6/hub/store.ts")
      assert matches?.("v6/plugins/codex/src/dist/vx.js")

      File.write!(Path.join(dir, ".linelimit-ignore"), "build/**/out.js\nlib/?.ex\n")
      matches? = Generated.matcher(dir)
      refute matches?.("build/out.js")
      assert matches?.("build/a/b/out.js")
      assert matches?.("lib/a.ex")
      refute matches?.("lib/ab.ex")
      refute matches?.("lib/x/a.ex")
      File.write!(Path.join(dir, ".linelimit-ignore"), "dist/*\n")
      assert Generated.matcher(dir).("dist/a/b/c.js")
    end

    test "blank and comment lines are ignored", %{tmp_dir: dir} do
      File.write!(
        Path.join(dir, ".linelimit-ignore"),
        "# generated bundles\n\n   \n# v6/hub/*\nv6/plugins/*/dist/*.js\n"
      )

      matches? = Generated.matcher(dir)
      refute matches?.("v6/hub/store.ts")
      assert matches?.("v6/plugins/codex/dist/vx.js")
      assert Generated.parse_globs("# c\n\n  x/*.js \n") == ["x/*.js"]
    end

    test "a missing ignore file and no git marks nothing generated", %{tmp_dir: dir} do
      matches? = Generated.matcher(dir)
      refute matches?.("v6/plugins/codex/dist/vx.js")
      refute matches?.("anything.ts")
    end
  end

  describe "linguist-generated" do
    test "a file marked by .gitattributes is generated; other files are not", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "gen"))
      File.write!(Path.join(dir, "gen/out.ts"), "x")
      File.write!(Path.join(dir, "src.ts"), "y")
      File.write!(Path.join(dir, ".gitattributes"), "gen/* linguist-generated=true\n")
      git!(dir, ["init", "-q"])
      git!(dir, ["add", "-A"])

      matches? = Generated.matcher(dir)
      assert matches?.("gen/out.ts")
      refute matches?.("src.ts")
    end

    test "no git repository and no ignore file marks nothing generated", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "gen.ts"), "x")
      refute Generated.matcher(dir).("gen.ts")
    end
  end

  describe "Trail.build" do
    setup do
      root = Path.expand("../fixtures/mini", __DIR__)

      dir =
        Path.join(System.tmp_dir!(), "trailblazer-build-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.cp_r!(root, dir)

      {:ok, _pid} =
        Trailblazer.Indexer.watch(dir,
          embed: FakeEmbed,
          vectors: FakeVectors,
          filesystem: false,
          embedding: :paused
        )

      {:ok, _repo_id} = Store.add_repo(dir)

      on_exit(fn ->
        if pid = Trailblazer.Indexer.whereis(dir), do: GenServer.stop(pid)
        File.rm_rf!(dir)
      end)

      # The same definition in a generated bundle and in the real source.
      File.mkdir_p!(Path.join(dir, "dist"))
      File.write!(Path.join(dir, "dist/bundle.ts"), @bundle)
      File.write!(Path.join(dir, ".linelimit-ignore"), "# bundles\ndist/*.ts\n")
      {:ok, _stats} = Trailblazer.Indexer.sync(dir)

      %{dir: dir, opts: [indexer: NoFresh, embed: FakeEmbed, vectors: FakeVectors]}
    end

    test "a generated file's definition is dropped; the source's is kept", ctx do
      trail = Trail.build(ctx.dir, "saveHikes fails", ctx.opts)

      assert Enum.any?(trail.items, &(&1.node.path == "web/save.ts"))
      refute Enum.any?(trail.items, &(&1.node.path == "dist/bundle.ts"))
      assert Enum.any?(trail.notes, &(&1 == "skipped 1 generated file"))
    end

    test "a generated file the request names stays", ctx do
      trail =
        Trail.build(
          ctx.dir,
          "saveHikes fails",
          Keyword.put(ctx.opts, :files, ["dist/bundle.ts"])
        )

      assert Enum.any?(trail.items, &(&1.node.path == "dist/bundle.ts"))
    end
  end

  defp git!(dir, args) do
    {_out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
  end
end
