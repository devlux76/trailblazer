defmodule Trailblazer.Loop.TextRangeEditsTest do
  @moduledoc """
  Text mode's edit dialect (raw-code <edit>/<create> tags, digest optional)
  and the patch-based write path every edit goes through.
  """
  use ExUnit.Case, async: true

  alias Trailblazer.Loop
  alias Trailblazer.Loop.{Edits, Tools}

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

  describe "tag dialect" do
    test "code goes raw: quotes, backslashes and newlines need no escaping" do
      reply = """
      One sentence first.

      <edit path="lib/a.ex" start="2" end="3">
      <first>2|   x = "a\\b"</first>
      <last>  y = 1</last>
      <replace>
        x = "a\\\\b" <> "\\"q\\""
        y = 2
      </replace>
      </edit>
      """

      assert {:ok, [block]} = text(reply)
      assert block.type == :range
      assert block.digest == nil
      assert {block.start, block.end} == {2, 3}
      # a copied "2| " number prefix is not part of the quote
      assert block.first == ~S(  x = "a\b")
      assert block.last == "  y = 1"
      assert block.replace == ~S(  x = "a\\b" <> "\"q\"") <> "\n  y = 2\n"
    end

    test "an empty replace deletes; create makes a file; blocks keep their order" do
      reply = """
      <create path="lib/new.ex">
      defmodule New do
      end
      </create>
      <edit path="lib/a.ex" start="1" end="1">
      <first>old</first>
      <last>old</last>
      <replace></replace>
      </edit>
      """

      assert {:ok, [create, delete]} = text(reply)
      assert create == %{path: "lib/new.ex", search: "", replace: "defmodule New do\nend\n"}
      assert delete.replace == ""
    end

    test "malformed tags are refused with the exact problem" do
      assert {:error, msg} = text(~s(<edit path="a" start="1" end="1">\n<first>x</first>))
      assert msg =~ "not closed"

      assert {:error, msg} =
               text(
                 ~s(<edit path="a" start="x" end="1"><first>a</first><last>a</last><replace>\n</replace></edit>)
               )

      assert msg =~ ~s(start="N")

      assert {:error, msg} =
               text(
                 ~s(<edit path="a" start="1" end="1"><first>a</first><replace>\n</replace></edit>)
               )

      assert msg =~ "<last>"
    end

    test "tags are text mode only; JSON stays accepted there without a digest" do
      reply =
        ~s(<edit path="a" start="1" end="1"><first>a</first><last>a</last><replace>b\n</replace></edit>)

      assert Tools.text_edit_blocks(reply) == :none

      json =
        ~s(```json\n[{"path":"a","start":1,"end":1,"first":"a","last":"a","replace":"b\\n"}]\n```)

      assert {:ok, [%{digest: nil, type: :range}]} = text("Sentence.\n\n" <> json)
      assert {:error, _} = Tools.text_edit_blocks(json)
    end

    test "text mode refuses a SEARCH block that edits an existing file" do
      json = ~s([{"path":"a","search":"x","replace":"y"}])
      assert {:error, msg} = text(json)
      assert msg =~ "only creates a new file"
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
