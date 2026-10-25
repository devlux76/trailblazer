defmodule Trailblazer.Loop.EditsTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Loop.Edits

  setup do
    dir = Path.join(System.tmp_dir!(), "trailblazer-edits-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write(dir, path, text), do: File.write!(Path.join(dir, path), text)
  defp read(dir, path), do: File.read!(Path.join(dir, path))

  describe "parse" do
    test "a block with its file name on the line before the fence" do
      text = """
      Here is the change.

      lib/store.ex
      ```elixir
      <<<<<<< SEARCH
        def put(a), do: a
      =======
        def put(a), do: {:ok, a}
      >>>>>>> REPLACE
      ```
      """

      assert {:ok,
              [
                %{
                  path: "lib/store.ex",
                  search: "  def put(a), do: a\n",
                  replace: "  def put(a), do: {:ok, a}\n"
                }
              ]} =
               Edits.parse(text)
    end

    test "a second block without a name edits the same file; an empty SEARCH is a new file" do
      text = """
      lib/a.ex
      ```
      <<<<<<< SEARCH
      one
      =======
      two
      >>>>>>> REPLACE
      ```
      ```
      <<<<<<< SEARCH
      three
      =======
      four
      >>>>>>> REPLACE
      ```

      lib/new.ex
      ```
      <<<<<<< SEARCH
      =======
      fresh
      >>>>>>> REPLACE
      ```
      """

      assert {:ok, [a, b, c]} = Edits.parse(text)
      assert {a.path, b.path, c.path} == {"lib/a.ex", "lib/a.ex", "lib/new.ex"}
      assert c.search == ""
    end

    test "the file name is found through Aider's stripping: `**name**`, `# name:`, backticks" do
      for line <- ["**lib/a.ex**", "# lib/a.ex:", "`lib/a.ex`", "```lib/a.ex"] do
        text = "#{line}\n```\n<<<<<<< SEARCH\nx\n=======\ny\n>>>>>>> REPLACE\n```\n"
        assert {:ok, [%{path: "lib/a.ex"}]} = Edits.parse(text), line
      end
    end

    test "D4: no blocks is an empty list; a half block is an error that says where" do
      assert {:ok, []} = Edits.parse("I think the change is fine as it is.")

      assert {:error, message} = Edits.parse("lib/a.ex\n```\n<<<<<<< SEARCH\nx\n```\n")
      assert message =~ "======="

      assert {:error, message} =
               Edits.parse("```\n<<<<<<< SEARCH\nx\n=======\ny\n>>>>>>> REPLACE\n```\n")

      assert message =~ "filename"
    end

    test "A6: CRLF replies parse like LF ones" do
      text =
        "lib/a.ex\r\n```\r\n<<<<<<< SEARCH\r\none\r\n=======\r\ntwo\r\n>>>>>>> REPLACE\r\n```\r\n"

      assert {:ok, [%{path: "lib/a.ex", search: "one\n", replace: "two\n"}]} = Edits.parse(text)
    end
  end

  describe "apply" do
    test "an exact match is replaced", %{dir: dir} do
      write(dir, "lib/a.ex", "defmodule A do\n  def f, do: 1\nend\n")
      blocks = [%{path: "lib/a.ex", search: "  def f, do: 1\n", replace: "  def f, do: 2\n"}]

      assert {:ok, ["lib/a.ex"]} = Edits.apply(dir, blocks)
      assert read(dir, "lib/a.ex") == "defmodule A do\n  def f, do: 2\nend\n"
    end

    test "leading whitespace the model got wrong, uniformly, still matches and is restored", %{
      dir: dir
    } do
      write(dir, "lib/a.ex", "defmodule A do\n    def f do\n      1\n    end\nend\n")

      blocks = [
        %{path: "lib/a.ex", search: "def f do\n  1\nend\n", replace: "def f do\n  2\nend\n"}
      ]

      assert {:ok, _} = Edits.apply(dir, blocks)
      assert read(dir, "lib/a.ex") == "defmodule A do\n    def f do\n      2\n    end\nend\n"
    end

    # Codex's review of L2: the plan promised trailing spaces too.
    test "trailing spaces the model dropped still match; untouched lines keep theirs", %{
      dir: dir
    } do
      write(dir, "lib/a.ex", "keep  \nalpha  \n  beta \nend\t\n")
      blocks = [%{path: "lib/a.ex", search: "alpha\n  beta\n", replace: "gamma\n"}]

      assert {:ok, _} = Edits.apply(dir, blocks)
      assert read(dir, "lib/a.ex") == "keep  \ngamma\nend\t\n"

      write(dir, "lib/b.ex", "  def f do  \n    1\n  end\n")
      blocks = [%{path: "lib/b.ex", search: "def f do\n  1\n", replace: "def f do\n  2\n"}]
      assert {:ok, _} = Edits.apply(dir, blocks)
      assert read(dir, "lib/b.ex") == "  def f do\n    2\n  end\n"
    end

    test "a spurious leading blank line in SEARCH is dropped", %{dir: dir} do
      write(dir, "lib/a.ex", "a\nb\nc\n")

      assert {:ok, _} =
               Edits.apply(dir, [%{path: "lib/a.ex", search: "\nb\nc\n", replace: "B\nC\n"}])

      assert read(dir, "lib/a.ex") == "a\nB\nC\n"
    end

    test "... elides unchanged lines, pieces matched uniquely", %{dir: dir} do
      write(dir, "lib/a.ex", "def f do\n  one()\n  two()\n  three()\nend\n")

      blocks = [
        %{
          path: "lib/a.ex",
          search: "def f do\n...\n  three()\n",
          replace: "def f do\n...\n  four()\n"
        }
      ]

      assert {:ok, _} = Edits.apply(dir, blocks)
      assert read(dir, "lib/a.ex") == "def f do\n  one()\n  two()\n  four()\nend\n"
    end

    test "several blocks on one file chain; an empty SEARCH creates a file and its directory", %{
      dir: dir
    } do
      write(dir, "lib/a.ex", "one\ntwo\n")

      blocks = [
        %{path: "lib/a.ex", search: "one\n", replace: "ONE\n"},
        %{path: "lib/a.ex", search: "two\n", replace: "TWO\n"},
        %{path: "lib/deep/new.ex", search: "", replace: "fresh\n"}
      ]

      assert {:ok, paths} = Edits.apply(dir, blocks)
      assert Enum.sort(paths) == ["lib/a.ex", "lib/deep/new.ex"]
      assert read(dir, "lib/a.ex") == "ONE\nTWO\n"
      assert read(dir, "lib/deep/new.ex") == "fresh\n"
    end

    test "all or nothing: one miss writes no file, and says what the closest lines were", %{
      dir: dir
    } do
      write(dir, "lib/a.ex", "defmodule A do\n  def f(x), do: x + 1\nend\n")
      write(dir, "lib/b.ex", "keep\n")

      blocks = [
        %{path: "lib/b.ex", search: "keep\n", replace: "changed\n"},
        %{path: "lib/a.ex", search: "  def f(y), do: y + 1\n", replace: "  def f(y), do: y + 2\n"}
      ]

      assert {:error, [failure]} = Edits.apply(dir, blocks)
      assert failure.block.path == "lib/a.ex"
      assert failure.closest =~ "def f(x), do: x + 1"
      assert read(dir, "lib/b.ex") == "keep\n"

      feedback = Edits.feedback([failure])
      assert feedback =~ "failed to match"
      assert feedback =~ "Did you mean"
      assert feedback =~ "def f(x), do: x + 1"
    end

    test "a block whose REPLACE is already in the file says so", %{dir: dir} do
      write(dir, "lib/a.ex", "new line\n")

      assert {:error, [failure]} =
               Edits.apply(dir, [%{path: "lib/a.ex", search: "old line\n", replace: "new line\n"}])

      assert Edits.feedback([failure]) =~ "already in lib/a.ex"
    end

    test "A9/A10/E3: paths that leave the worktree are refused, nothing written", %{dir: dir} do
      outside =
        Path.join(System.tmp_dir!(), "trailblazer-outside-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(dir, "link"))
      on_exit(fn -> File.rm_rf!(outside) end)

      for path <- ["../escape.ex", "/etc/passwd", "link/x.ex"] do
        assert {:error, [%{reason: :outside_worktree}]} =
                 Edits.apply(dir, [%{path: path, search: "", replace: "x\n"}]),
               path
      end

      refute File.exists?(Path.join(outside, "x.ex"))
    end

    # Codex's review of L2: a link to an outside path that does not exist yet
    # looked absent, so only its inside parent was checked, and the write
    # followed the link out.
    test "A9: a dangling symlink, to a file or a directory, is refused", %{dir: dir} do
      outside =
        Path.join(System.tmp_dir!(), "trailblazer-dangling-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(outside) end)
      File.ln_s!(Path.join(outside, "new.txt"), Path.join(dir, "new.txt"))
      File.ln_s!(Path.join(outside, "dir"), Path.join(dir, "gone"))

      for path <- ["new.txt", "gone/x.ex"] do
        assert {:error, [%{reason: :outside_worktree}]} =
                 Edits.apply(dir, [%{path: path, search: "", replace: "escaped\n"}]),
               path
      end

      refute File.exists?(outside)
    end

    # The first live trial: shown calc.py, the model wrote lib/calc.py (and
    # lib/greeting.ex, from the prompt's example) on all three attempts.
    test "a wrong directory is resolved to the one file of that name", %{dir: dir} do
      write(dir, "calc.py", "return a - b\n")
      blocks = [%{path: "lib/calc.py", search: "return a - b\n", replace: "return a + b\n"}]

      assert {:ok, ["calc.py"]} = Edits.apply(dir, blocks, files: ["calc.py", "lib/a.ex"])
      assert read(dir, "calc.py") == "return a + b\n"
      refute File.exists?(Path.join(dir, "lib/calc.py"))
    end

    test "a close misspelling is resolved; several files of one name are listed", %{dir: dir} do
      write(dir, "lib/store.ex", "one\n")
      blocks = [%{path: "lib/stores.ex", search: "one\n", replace: "two\n"}]
      assert {:ok, ["lib/store.ex"]} = Edits.apply(dir, blocks, files: ["lib/store.ex"])

      # both files of that name hold the SEARCH text, so neither name nor text settles it
      File.mkdir_p!(Path.join(dir, "test"))
      write(dir, "lib/store.ex", "one\n")
      write(dir, "test/store.ex", "one\n")
      blocks = [%{path: "src/store.ex", search: "one\n", replace: "two\n"}]
      files = ["lib/store.ex", "test/store.ex"]

      assert {:error, [failure]} = Edits.apply(dir, blocks, files: files)
      assert failure.reason == :no_such_file
      feedback = Edits.feedback([failure])
      assert feedback =~ "Files with that name:\nlib/store.ex\ntest/store.ex"
      refute feedback =~ "Did you mean to match"
    end

    # The second live trial: shown calc.py, the model named the prompt's
    # example file, which shares nothing with it but the SEARCH text.
    test "D20: a name that settles nothing goes to the one shown file the SEARCH matches", %{
      dir: dir
    } do
      write(dir, "calc.py", "def add(a, b):\n    return a - b\n")
      write(dir, "other.py", "x = 1\n")

      blocks = [
        %{path: "lib/greeting.ex", search: "    return a - b\n", replace: "    return a + b\n"}
      ]

      files = ["calc.py", "other.py"]

      assert {:ok, ["calc.py"]} = Edits.apply(dir, blocks, files: files, shown: files)
      assert read(dir, "calc.py") =~ "a + b"
      refute File.exists?(Path.join(dir, "lib/greeting.ex"))

      # two shown files that both match settle nothing
      write(dir, "calc.py", "    return a - b\n")
      write(dir, "other.py", "    return a - b\n")

      assert {:error, [%{reason: :no_such_file}]} =
               Edits.apply(dir, blocks, files: files, shown: files)

      # several files of that name: the one whose text matches
      File.mkdir_p!(Path.join(dir, "test"))
      write(dir, "lib/store.ex", "one\n")
      write(dir, "test/store.ex", "two\n")
      blocks = [%{path: "src/store.ex", search: "two\n", replace: "three\n"}]
      files = ["lib/store.ex", "test/store.ex"]
      assert {:ok, ["test/store.ex"]} = Edits.apply(dir, blocks, files: files)
    end

    # Codex's review of D17 (tmp/core/review-filename-path_test.exs): the
    # fuzzy match turned `../calc.py` into `calc.py` before containment.
    test "A9: a name that leaves the worktree is refused, never matched to a file inside", %{
      dir: dir
    } do
      write(dir, "calc.py", "return a - b\n")
      files = ["calc.py"]

      for path <- ["../calc.py", "lib/../../calc.py", "/tmp/calc.py"] do
        blocks = [%{path: path, search: "return a - b\n", replace: "return a + b\n"}]

        assert {:error, [%{reason: :outside_worktree}]} =
                 Edits.apply(dir, blocks, files: files, shown: files),
               path
      end

      assert read(dir, "calc.py") == "return a - b\n"
    end

    test "a block that creates a file keeps the name it was given", %{dir: dir} do
      write(dir, "calc.py", "x\n")
      blocks = [%{path: "lib/calc.py", search: "", replace: "new\n"}]
      assert {:ok, ["lib/calc.py"]} = Edits.apply(dir, blocks, files: ["calc.py"])
      assert read(dir, "calc.py") == "x\n"
    end

    test "a SEARCH on a file that does not exist is a miss, not a crash", %{dir: dir} do
      assert {:error, [%{reason: :no_such_file}]} =
               Edits.apply(dir, [%{path: "lib/missing.ex", search: "x\n", replace: "y\n"}])
    end

    test "an ambiguous ... piece (found twice) is a miss", %{dir: dir} do
      write(dir, "lib/a.ex", "x()\nx()\n")
      blocks = [%{path: "lib/a.ex", search: "...\nx()\n", replace: "...\ny()\n"}]
      assert {:error, [%{reason: :no_match}]} = Edits.apply(dir, blocks)
    end
  end
end
