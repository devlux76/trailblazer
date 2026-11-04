defmodule Trailblazer.Loop.RangeEditsTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Loop.Edits

  setup do
    dir =
      Path.join(System.tmp_dir!(), "trailblazer-rangeedits-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, "lib"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp digest(dir, path) do
    :crypto.hash(:sha256, File.read!(Path.join(dir, path))) |> Base.encode16(case: :lower)
  end

  defp write(dir, path, text), do: File.write!(Path.join(dir, path), text)
  defp read(dir, path), do: File.read!(Path.join(dir, path))

  @dup_blocks """
  defmodule Dup do
    def alpha, do: "same"
    def beta, do: "same"

    def alpha, do: "same"
    def beta, do: "same"
  end
  """

  describe "read-backed range edits" do
    test "a range targets the SECOND of two byte-identical blocks", %{dir: dir} do
      write(dir, "lib/dup.ex", @dup_blocks)
      digest = digest(dir, "lib/dup.ex")

      # lines (1-based): 1 defmodule / 2 alpha / 3 beta / 4 blank / 5 alpha / 6 beta / 7 end
      assert {:ok, ["lib/dup.ex"]} =
               Edits.apply(dir, [
                 %{path: "lib/dup.ex", type: :range, digest: digest, start: 5, end: 6,
                   replace: "  def alpha, do: \"changed\"\n  def beta, do: \"changed\"\n"}
               ])

      assert read(dir, "lib/dup.ex") == """
      defmodule Dup do
        def alpha, do: "same"
        def beta, do: "same"

        def alpha, do: "changed"
        def beta, do: "changed"
      end
      """
    end

    test "a stale digest is refused and nothing is written", %{dir: dir} do
      write(dir, "lib/a.ex", "one\ntwo\n")

      assert {:error, failures} =
               Edits.apply(dir, [
                 %{path: "lib/a.ex", type: :range, digest: String.duplicate("0", 64), start: 1,
                   end: 1, replace: "una\n"}
               ])

      assert [%{reason: :stale_digest}] = failures
      assert read(dir, "lib/a.ex") == "one\ntwo\n"
    end

    test "overlapping ranges are refused; nothing is written", %{dir: dir} do
      write(dir, "lib/a.ex", "a\nb\nc\nd\n")
      digest = digest(dir, "lib/a.ex")

      assert {:error, failures} =
               Edits.apply(dir, [
                 %{path: "lib/a.ex", type: :range, digest: digest, start: 1, end: 2,
                   replace: "AB\n"},
                 %{path: "lib/a.ex", type: :range, digest: digest, start: 2, end: 3,
                   replace: "BC\n"}
               ])

      assert [%{reason: :overlapping_ranges}] = failures
      assert read(dir, "lib/a.ex") == "a\nb\nc\nd\n"
    end

    test "an insertion strictly inside another replacement is refused", %{dir: dir} do
      write(dir, "lib/a.ex", "a\nb\nc\n")
      digest = digest(dir, "lib/a.ex")

      assert {:error, _failures} =
               Edits.apply(dir, [
                 %{path: "lib/a.ex", type: :range, digest: digest, start: 1, end: 2,
                   replace: "AB\n"},
                 %{path: "lib/a.ex", type: :range, digest: digest, start: 2, end: 1,
                   replace: "x\n"}
               ])

      assert read(dir, "lib/a.ex") == "a\nb\nc\n"
    end

    test "two insertions at the same position are refused", %{dir: dir} do
      write(dir, "lib/a.ex", "a\nb\n")
      digest = digest(dir, "lib/a.ex")

      assert {:error, failures} =
               Edits.apply(dir, [
                 %{path: "lib/a.ex", type: :range, digest: digest, start: 1, end: 0,
                   replace: "x\n"},
                 %{path: "lib/a.ex", type: :range, digest: digest, start: 1, end: 0,
                   replace: "y\n"}
               ])

      assert [%{reason: :duplicate_insertion}] = failures
      assert read(dir, "lib/a.ex") == "a\nb\n"
    end

    test "adjacent disjoint ranges are both applied, descending", %{dir: dir} do
      write(dir, "lib/a.ex", "a\nb\nc\n")
      digest = digest(dir, "lib/a.ex")

      assert {:ok, ["lib/a.ex"]} =
               Edits.apply(dir, [
                 %{path: "lib/a.ex", type: :range, digest: digest, start: 1, end: 1,
                   replace: "A\n"},
                 %{path: "lib/a.ex", type: :range, digest: digest, start: 3, end: 3,
                   replace: "C\n"}
               ])

      assert read(dir, "lib/a.ex") == "A\nb\nC\n"
    end

    test "an insertion at EOF and an insertion in an empty file both work", %{dir: dir} do
      write(dir, "lib/empty.ex", "")
      write(dir, "lib/tail.ex", "x\n")
      empty_digest = digest(dir, "lib/empty.ex")
      tail_digest = digest(dir, "lib/tail.ex")

      assert {:ok, ["lib/empty.ex"]} =
               Edits.apply(dir, [
                 %{path: "lib/empty.ex", type: :range, digest: empty_digest, start: 1,
                   end: 0, replace: "first\n"}
               ])

      assert read(dir, "lib/empty.ex") == "first\n"

      assert {:ok, ["lib/tail.ex"]} =
               Edits.apply(dir, [
                 %{path: "lib/tail.ex", type: :range, digest: tail_digest, start: 2,
                   end: 1, replace: "second\n"}
               ])

      assert read(dir, "lib/tail.ex") == "x\nsecond\n"
    end

    test "CRLF and Unicode bytes outside the ranges stay byte-identical", %{dir: dir} do
      original = "α\r\nβ\r\nγΔ\r\n"
      write(dir, "lib/cr.ex", original)
      digest = digest(dir, "lib/cr.ex")

      assert {:ok, ["lib/cr.ex"]} =
               Edits.apply(dir, [
                 %{path: "lib/cr.ex", type: :range, digest: digest, start: 2, end: 2,
                   replace: "BETA\r\n"}
               ])

      assert read(dir, "lib/cr.ex") == "α\r\nBETA\r\nγΔ\r\n"
    end

    test "legacy and range blocks on one file are refused; nothing written", %{dir: dir} do
      write(dir, "lib/a.ex", "one\ntwo\n")
      digest = digest(dir, "lib/a.ex")

      assert {:error, _failures} =
               Edits.apply(dir, [
                 %{path: "lib/a.ex", type: :search, search: "one\n", replace: "ONE\n"},
                 %{path: "lib/a.ex", type: :range, digest: digest, start: 2, end: 2,
                   replace: "TWO\n"}
               ])

      assert read(dir, "lib/a.ex") == "one\ntwo\n"
    end

    test "a multi-file batch writes nothing when one file misses", %{dir: dir} do
      write(dir, "lib/good.ex", "x\n")
      write(dir, "lib/bad.ex", "y\n")
      digest = digest(dir, "lib/good.ex")

      assert {:error, _failures} =
               Edits.apply(dir, [
                 %{path: "lib/good.ex", type: :range, digest: digest, start: 1, end: 1,
                   replace: "X\n"},
                 %{path: "lib/bad.ex", type: :range, digest: String.duplicate("f", 64),
                   start: 1, end: 1, replace: "Y\n"}
               ])

      assert read(dir, "lib/good.ex") == "x\n"
      assert read(dir, "lib/bad.ex") == "y\n"
    end

    test "a malformed range block is refused and writes nothing", %{dir: dir} do
      write(dir, "lib/a.ex", "a\n")
      digest = digest(dir, "lib/a.ex")

      bad = [
        %{path: "lib/a.ex", type: :range, digest: "ABCDEF", start: 1, end: 1,
          replace: "A\n"},
        %{path: "lib/a.ex", type: :range, digest: String.duplicate("a", 64),
          start: "1", end: 1, replace: "A\n"},
        %{path: "lib/a.ex", type: :range, digest: digest, start: 0, end: 1,
          replace: "A\n"},
        %{path: "lib/a.ex", type: :range, digest: digest, start: 3, end: 4,
          replace: "A\n"},
        %{path: "lib/a.ex", type: "range", digest: digest, start: 1, end: 1,
          replace: "A\n"}
      ]

      for block <- bad do
        assert {:error, _} = Edits.apply(dir, [block])
        assert read(dir, "lib/a.ex") == "a\n"
      end
    end

    test "a range block never creates a missing file", %{dir: dir} do
      assert {:error, [%{reason: :no_such_file}]} =
               Edits.apply(dir, [
                 %{path: "lib/missing.ex", type: :range, digest: String.duplicate("a", 64),
                   start: 1, end: 0, replace: "x\n"}
               ])

      refute File.exists?(Path.join(dir, "lib/missing.ex"))
    end

    test "a symlink escape is refused for range blocks", %{dir: dir} do
      File.write!(Path.join(dir, "secret.txt"), "password\n")

      outside =
        Path.join(System.tmp_dir!(), "trailblazer-outside-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(outside) end)
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "escape.txt"), "password\n")
      File.ln_s!(Path.join(outside, "escape.txt"), Path.join(dir, "lib/link.ex"))

      digest =
        :crypto.hash(:sha256, File.read!(Path.join(outside, "escape.txt")))
        |> Base.encode16(case: :lower)

      assert {:error, [%{reason: :outside_worktree}]} =
               Edits.apply(dir, [
                 %{path: "lib/link.ex", type: :range, digest: digest, start: 1, end: 1,
                   replace: "x\n"}
               ])

      assert File.read!(Path.join(dir, "secret.txt")) == "password\n"
    end

    test "unequal-length replacements at both ends of the file splice exactly", %{dir: dir} do
      write(dir, "lib/unequal.ex", "a\nbb\nccc\n")

      digest = digest(dir, "lib/unequal.ex")

      assert {:ok, ["lib/unequal.ex"]} =
               Edits.apply(dir, [
                 %{path: "lib/unequal.ex", type: :range, digest: digest, start: 1, end: 1,
                   replace: "LONGA\\nLONGB\\n"},
                 %{path: "lib/unequal.ex", type: :range, digest: digest, start: 3, end: 3,
                   replace: "Z"}
               ])

      assert read(dir, "lib/unequal.ex") == "LONGA\nLONGB\nbb\nZ"
    end

    test "an out-of-range replacement is refused; insertion at EOF is accepted", %{dir: dir} do
      write(dir, "lib/three.ex", "a\nb\nc\n")
      digest = digest(dir, "lib/three.ex")

      assert {:error, failures} =
               Edits.apply(dir, [
                 %{path: "lib/three.ex", type: :range, digest: digest, start: 4, end: 4,
                   replace: "nope\n"}
               ])

      assert [%{reason: :invalid_range}] = failures
      assert read(dir, "lib/three.ex") == "a\nb\nc\n"

      assert {:ok, ["lib/three.ex"]} =
               Edits.apply(dir, [
                 %{path: "lib/three.ex", type: :range, digest: digest, start: 4, end: 3,
                   replace: "d\n"}
               ])

      assert read(dir, "lib/three.ex") == "a\nb\nc\nd\n"
    end

    test "replacement at line 1 plus insertion at line 1 both apply", %{dir: dir} do
      write(dir, "lib/first.ex", "a\nb\n")
      digest = digest(dir, "lib/first.ex")

      assert {:ok, ["lib/first.ex"]} =
               Edits.apply(dir, [
                 %{path: "lib/first.ex", type: :range, digest: digest, start: 1, end: 1,
                   replace: "REPLACED\n"},
                 %{path: "lib/first.ex", type: :range, digest: digest, start: 1, end: 0,
                   replace: "INSERTED\n"}
               ])

      assert read(dir, "lib/first.ex") == "INSERTED\nREPLACED\nb\n"
    end

    test "a directory as the target file yields structured failures, nothing written", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib/adir"))

      assert {:error, failures} =
               Edits.apply(dir, [
                 %{path: "lib/adir", type: :range, digest: String.duplicate("a", 64),
                   start: 1, end: 1, replace: "x\n"}
               ])

      assert [%{reason: :unreadable}] = failures
    end
  end
end
