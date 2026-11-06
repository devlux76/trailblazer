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

      # a missing <last> is no longer refused: Edits fills it from the file
      assert {:ok, [%{first: "a", last: nil}]} =
               text(
                 ~s(<edit path="a" start="1" end="1"><first>a</first><replace>\n</replace></edit>)
               )
    end

    test "live LFM2.5 reply: two lines in <first>, no <last>; the range is replaced", %{dir: dir} do
      write(
        dir,
        "lib/c.ts",
        "// head\nimport a from 'a'\nimport b from 'b'\n\nexport const x = 1\n"
      )

      reply = """
      <edit path="lib/c.ts" start="2" end="4">
      <first>import a from 'a'
      import b from 'b'
      </first>
      <replace>
      import a from 'a'
      import b from 'b'
      import { m } from 'm'
      </replace>
      </edit>
      """

      assert {:ok, [block]} = text(reply)
      assert block.first == "import a from 'a'\nimport b from 'b'"
      assert block.last == nil
      assert {:ok, ["lib/c.ts"]} = Edits.apply(dir, [block])

      assert read(dir, "lib/c.ts") ==
               "// head\nimport a from 'a'\nimport b from 'b'\nimport { m } from 'm'\nexport const x = 1\n"
    end

    test "a quoted <first> that is wrong still refuses, even with <last> missing", %{dir: dir} do
      write(dir, "lib/a.ex", "one\ntwo\nthree\n")

      {:ok, blocks} =
        text(
          ~s(<edit path="lib/a.ex" start="2" end="2"><first>zwei</first><replace>\nTWO\n</replace></edit>)
        )

      assert {:error, [%{reason: :anchor_mismatch}]} = Edits.apply(dir, blocks)
      assert read(dir, "lib/a.ex") == "one\ntwo\nthree\n"
    end

    test "live LFM2.5 native call: edit(...) in <|tool_call_start|> is a range block", %{dir: dir} do
      write(
        dir,
        "lib/c.ts",
        "import type { P } from '../t.ts'\nimport { C } from './d.ts'\n\nexport {}\n"
      )

      reply =
        ~S"""
        <|tool_call_start|>[edit(path='lib/c.ts', start='1', end='3', replace='import type { P } from \'../t.ts\'\nimport { C } from \'./d.ts\'\nimport { multiaddr } from \'@multiformats/multiaddr\'')]<|tool_call_end|>
        """

      assert {:ok, [block]} = text(reply)
      assert {block.start, block.end, block.first, block.last} == {1, 3, nil, nil}
      assert {:ok, ["lib/c.ts"]} = Edits.apply(dir, [block])

      assert read(dir, "lib/c.ts") ==
               "import type { P } from '../t.ts'\nimport { C } from './d.ts'\nimport { multiaddr } from '@multiformats/multiaddr'\nexport {}\n"
    end

    test "native calls: several in one list, double quotes, bare numbers, junk refused" do
      reply =
        ~S"""
        <|tool_call_start|>[edit(path="a", start=2, end=2, replace="x \"q\"\n"), edit(path='b', start='1', end='0', replace='y')]<|tool_call_end|>
        """

      assert {:ok, [a, b]} = text(reply)
      assert {a.path, a.start, a.end, a.replace} == {"a", 2, 2, ~S(x "q") <> "\n"}
      assert {b.path, b.start, b.end, b.replace} == {"b", 1, 0, "y\n"}

      assert {:error, _} =
               text(~S"""
               <|tool_call_start|>[read(path='a')]<|tool_call_end|>
               """)

      assert {:error, _} =
               text(~S"""
               <|tool_call_start|>[edit(path='a', start='x', end='1', replace='')]<|tool_call_end|>
               """)

      # JSON mode is untouched by the native form
      refute match?(
               {:ok, [_ | _]},
               Tools.text_edit_blocks(~S"""
               <|tool_call_start|>[edit(path='a', start=1, end=1, replace='z')]<|tool_call_end|>
               """)
             )
    end

    test "native edit calls lifted into tool_calls read as range blocks" do
      assert {:ok, [a, b]} =
               Tools.native_call_blocks([
                 ~s({"path": "lib/c.ts", "start": 7, "end": 9, "replace": "x\\ny"}),
                 %{"path" => "lib/d.ts", "start" => "2", "end" => "1", "replace" => "z\n"}
               ])

      assert {a.path, a.start, a.end, a.replace, a.first} == {"lib/c.ts", 7, 9, "x\ny\n", nil}
      assert {b.start, b.end, b.replace} == {2, 1, "z\n"}
      # the live second attempt: no replace
      assert {:error, msg} =
               Tools.native_call_blocks([~s({"path": "a", "start": "7", "end": "9"})])

      assert msg =~ "replace"
      assert {:error, _} = Tools.native_call_blocks(["not json"])
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

  describe "tags inside the code (review of 0cc6e53)" do
    test "a replacement holding </replace>, </edit> or <edit> keeps all of it" do
      reply = """
      <edit path="lib/p.ex" start="1" end="1">
      <first>old</first>
      <last>old</last>
      <replace>
      @re ~r/<edit>(.*?)</edit>/ </edit> x
        s = "<replace>foo</replace>"
      </replace>
      </edit>
      """

      assert {:ok, [b]} = text(reply)

      assert b.replace ==
               "@re ~r/<edit>(.*?)</edit>/ </edit> x\n  s = \"<replace>foo</replace>\"\n"
    end

    test "new text with lines that start like tags is refused, never guessed" do
      example = fn path ->
        "<edit path=\"#{path}\" start=\"1\" end=\"1\">\n<first>x</first>\n<last>x</last>\n<replace>\nother\n</replace>\n</edit>\n"
      end

      # one example and two examples (the second once parsed as an invented edit)
      for examples <- [example.("lib/a.ex"), example.("lib/a.ex") <> example.("lib/b.ex")] do
        reply =
          "<edit path=\"priv/p.md\" start=\"3\" end=\"4\">\n<first>old</first>\n<last>old2</last>\n<replace>\nThe format:\n\n" <>
            examples <> "\nEnd of prompt.\n</replace>\n</edit>\n"

        assert {:error, msg} = text(reply)
        assert msg =~ "lines that start with edit tags"
      end

      assert {:error, _} = text("<create path=\"p.md\">\n<edit path=\"a\">\n</create>\n")
    end

    test "comment lines ending in closing tags stay inside the replacement" do
      reply =
        "<edit path=\"lib/t.ex\" start=\"1\" end=\"2\">\n<first>a</first>\n<last>b</last>\n<replace>\n  #     </replace>\n  #     </edit>\n  real_code()\n</replace>\n</edit>\n"

      assert {:ok, [b]} = text(reply)
      assert b.replace == "  #     </replace>\n  #     </edit>\n  real_code()\n"
    end

    test "two blocks stay two blocks" do
      block = fn n ->
        "<edit path=\"a\" start=\"#{n}\" end=\"#{n}\">\n<first>l#{n}</first>\n<last>l#{n}</last>\n<replace>\nL#{n}\n</replace>\n</edit>\n"
      end

      assert {:ok, [a, b]} = text(block.(1) <> "\n" <> block.(5))
      assert {a.start, a.replace, b.start, b.replace} == {1, "L1\n", 5, "L5\n"}
    end

    test "a <replace> left open runs to the end of its block (seen live)" do
      reply =
        "<edit path=\"lib/s.ex\" start=\"14\" end=\"16\">\n<first>  @doc \"x\"</first>\n<last>end</last>\n<replace>\n  @doc \"x\"\n  def peek(s), do: s\nend\n</edit>\n"

      assert {:ok, [b]} = text(reply)
      assert b.replace == "  @doc \"x\"\n  def peek(s), do: s\nend\n"
    end

    test "an edit holding only bare code is refused with what it lacks" do
      reply = "<edit path=\"lib/s.ex\" start=\"14\" end=\"16\">\ndef peek(s), do: s\n</edit>\n"
      assert {:error, msg} = text(reply)
      assert msg =~ "lib/s.ex lines 14-16: the <edit> holds only code"
      assert msg =~ "<first> (exact text of line 14)"
    end

    test "a new file holding </create> mid-line keeps all of it" do
      reply = "<create path=\"t.md\">\nsee </create> tag\nend\n</create>\n"
      assert {:ok, [b]} = text(reply)
      assert b.replace == "see </create> tag\nend\n"
    end

    test "an indented closing tag adds no whitespace line" do
      reply =
        "<edit path=\"a\" start=\"1\" end=\"1\">\n  <first>x</first>\n  <last>x</last>\n  <replace>\n  y\n  </replace>\n</edit>\n"

      assert {:ok, [b]} = text(reply)
      assert b.replace == "  y\n"
    end

    test "CRLF replies: quotes carry no line break, replacement keeps its CRs" do
      reply =
        "<edit path=\"a\" start=\"1\" end=\"1\">\r\n<first>foo</first>\r\n<last>foo</last>\r\n<replace>\r\nbar\r\n</replace>\r\n</edit>\r\n"

      assert {:ok, [b]} = text(reply)
      assert {b.first, b.last, b.replace} == {"foo", "foo", "bar\r\n"}
    end

    test "a tag mentioned in prose does not hide the JSON that follows" do
      json = ~s([{"path":"a","start":1,"end":1,"first":"a","last":"a","replace":"b\\n"}])
      reply = "I'll use <edit> tags next time.\n\n```json\n#{json}\n```\n"
      assert {:ok, [%{type: :range, replace: "b\n"}]} = text(reply)
    end

    test "stripping trailing whitespace from one line is not a no-op" do
      edit = fn n ->
        ~s(<edit path="a" start="#{n}" end="#{n}">\n<first>foo  </first>\n<last>foo  </last>\n<replace>\nfoo\n</replace>\n</edit>\n)
      end

      refute Loop.looping_blocks?(Enum.map_join(1..3, &edit.(&1)))
    end
  end

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
