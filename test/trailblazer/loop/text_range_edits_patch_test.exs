defmodule Trailblazer.Loop.TextRangeEditsTest.Patch do
  use ExUnit.Case, async: true

  alias Trailblazer.Loop
  alias Trailblazer.Loop.Edits
  alias Trailblazer.Loop.Tools

  setup do
    dir =
      Path.join(System.tmp_dir!(), "trailblazer-text-edits-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, "lib"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write(dir, path, text), do: File.write!(Path.join(dir, path), text)

  defp read(dir, path), do: File.read!(Path.join(dir, path))

  defp text(reply), do: Tools.text_edit_blocks(reply, mode: :text)

  describe "the patch check ignores the worktree's git settings" do
    defp git!(dir, args), do: {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

    test "autocrlf and eol=crlf attributes do not change the bytes written", %{dir: dir} do
      git!(dir, ["init", "-q"])
      git!(dir, ["config", "core.autocrlf", "true"])
      write(dir, ".gitattributes", "* text=auto eol=crlf\n")
      write(dir, "lib/a.ex", "a\nb\n")
      blocks = [%{path: "lib/a.ex", search: "b\n", replace: "B\n"}]
      assert {:ok, ["lib/a.ex"]} = Edits.apply(dir, blocks)
      assert read(dir, "lib/a.ex") == "a\nB\n"
    end

    test "files reached through a symlinked directory or a symlink are edited", %{dir: dir} do
      git!(dir, ["init", "-q"])
      File.mkdir_p!(Path.join(dir, "real"))
      write(dir, "real/f.txt", "one\n")
      write(dir, "real/g.txt", "two\n")
      File.ln_s!("real", Path.join(dir, "link"))
      File.ln_s!("g.txt", Path.join(dir, "real/h.txt"))

      blocks = [
        %{path: "link/f.txt", search: "one\n", replace: "ONE\n"},
        %{path: "real/h.txt", search: "two\n", replace: "TWO\n"}
      ]

      assert {:ok, _} = Edits.apply(dir, blocks)
      assert read(dir, "real/f.txt") == "ONE\n"
      assert read(dir, "real/g.txt") == "TWO\n"
    end
  end

  describe "applying digest-less ranges through the patch" do
    test "the quotes bind the range; the file gets exactly the spliced bytes", %{dir: dir} do
      write(dir, "lib/a.ex", "one\ntwo\nthree\n")

      {:ok, blocks} =
        text(
          ~s(<edit path="lib/a.ex" start="2" end="2"><first>two</first><last>two</last><replace>\nTWO\n</replace></edit>)
        )

      assert {:ok, ["lib/a.ex"]} = Edits.apply(dir, blocks)
      assert read(dir, "lib/a.ex") == "one\nTWO\nthree\n"
    end

    test "quotes that match nowhere are refused and nothing is written", %{dir: dir} do
      write(dir, "lib/a.ex", "one\ntwo\nthree\n")

      {:ok, blocks} =
        text(
          ~s(<edit path="lib/a.ex" start="2" end="2"><first>zwei</first><last>zwei</last><replace>\nTWO\n</replace></edit>)
        )

      assert {:error, [%{reason: :anchor_mismatch}]} = Edits.apply(dir, blocks)
      assert read(dir, "lib/a.ex") == "one\ntwo\nthree\n"
    end

    test "CRLF and a missing final newline survive byte for byte", %{dir: dir} do
      write(dir, "lib/cr.ex", "a\r\nb\r\nc")

      {:ok, blocks} =
        text(
          ~s(<edit path="lib/cr.ex" start="1" end="1"><first>a</first><last>a</last><replace>\nA\r\n</replace></edit>)
        )

      assert {:ok, ["lib/cr.ex"]} = Edits.apply(dir, blocks)
      assert read(dir, "lib/cr.ex") == "A\r\nb\r\nc"
    end

    test "a new file in a new directory and an empty new file are created", %{dir: dir} do
      blocks = [
        %{path: "lib/deep/new.ex", search: "", replace: "x\n"},
        %{path: "lib/empty.ex", search: "", replace: ""}
      ]

      assert {:ok, ["lib/deep/new.ex", "lib/empty.ex"]} = Edits.apply(dir, blocks)
      assert read(dir, "lib/deep/new.ex") == "x\n"
      assert read(dir, "lib/empty.ex") == ""
    end

    test "a batch that changes no byte reports no changed path", %{dir: dir} do
      write(dir, "lib/a.ex", "one\n")

      {:ok, blocks} =
        text(
          ~s(<edit path="lib/a.ex" start="1" end="1"><first>one</first><last>one</last><replace>\none\n</replace></edit>)
        )

      assert {:ok, []} = Edits.apply(dir, blocks)
    end

    test "a patch git cannot apply leaves every file as it was", %{dir: dir} do
      write(dir, "lib/a.ex", "one\n")
      write(dir, "lib/b.ex", "two\n")
      # a directory where the new file must go makes git apply refuse the batch
      File.mkdir_p!(Path.join(dir, "lib/c.ex/inner"))

      blocks = [
        %{path: "lib/a.ex", search: "one\n", replace: "ONE\n"},
        %{path: "lib/c.ex/inner", search: "", replace: "x\n"}
      ]

      assert {:error, _} = Edits.apply(dir, blocks)
      assert read(dir, "lib/a.ex") == "one\n"
    end
  end

  describe "looping" do
    @block ~s(<edit path="a" start="3" end="4"><first>a</first><last>b</last><replace>\nc\n</replace></edit>\n)
    @noop ~s(<edit path="a" start="N" end="N">\n<first>  same</first>\n<last>  same</last>\n<replace>\n  same\n</replace>\n</edit>\n)

    test "the same tag block written a third time is looping" do
      refute Loop.looping_blocks?(@block <> @block)
      assert Loop.looping_blocks?(@block <> @block <> @block)
    end

    test "a third one-line edit that changes nothing is looping" do
      noops = for n <- 1..3, do: String.replace(@noop, "N", "#{n}")
      refute Loop.looping_blocks?(Enum.take(noops, 2) |> Enum.join())
      assert Loop.looping_blocks?(Enum.join(noops))
    end
  end
end
