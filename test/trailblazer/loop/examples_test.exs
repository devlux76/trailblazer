defmodule Trailblazer.Loop.ExamplesTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Loop.{Examples, Prompts, Tools}

  @tmp Path.join(System.tmp_dir!(), "examples_test_#{System.unique_integer([:positive])}")

  # A real `git diff` of old -> new, as History stores it (file header + hunks).
  defp diff(old, new, context \\ 3) do
    File.mkdir_p!(@tmp)
    a = Path.join(@tmp, "a#{System.unique_integer([:positive])}")
    b = a <> "b"
    File.write!(a, old)
    File.write!(b, new)

    {out, 1} =
      System.cmd("git", ["diff", "--no-index", "--no-color", "-U#{context}", a, b])

    [_, hunks] = String.split(out, ~r/^(?=@@ )/m, parts: 2)
    "--- a/lib/x.ex\n+++ b/lib/x.ex\n" <> hunks
  end

  # Applies parsed range blocks to `old` the way their contract says.
  defp apply_blocks(old, blocks) do
    lines = String.split(old, "\n") |> Enum.drop(-1)

    blocks
    |> Enum.sort_by(& &1.start, :desc)
    |> Enum.reduce(lines, fn b, lines ->
      if b.end >= b.start do
        assert Enum.at(lines, b.start - 1) == b.first
        assert Enum.at(lines, b.end - 1) == b.last
      end

      new = b.replace |> String.split("\n") |> Enum.drop(-1)
      Enum.take(lines, b.start - 1) ++ new ++ Enum.drop(lines, b.end)
    end)
    |> Enum.map_join(&(&1 <> "\n"))
  end

  defp round_trip(old, new, context \\ 3) do
    {:ok, text} = Examples.blocks(diff(old, new, context), "lib/x.ex")
    {:ok, blocks} = Tools.text_edit_blocks(text, mode: :text)
    assert Enum.all?(blocks, &(&1.type == :range and &1.path == "lib/x.ex"))
    assert apply_blocks(old, blocks) == new
    {text, blocks}
  end

  defp file(n), do: Enum.map_join(1..n, &"line #{&1}\n")

  describe "blocks/2: diff hunks as the coder's edit blocks against the old file" do
    test "a replacement, a deletion and an insertion round-trip through the parser" do
      old = file(30)

      new =
        old
        |> String.replace("line 5\n", "line five\nline 5b\n")
        |> String.replace("line 15\nline 16\n", "")
        |> String.replace("line 25\n", "line 25\ninserted\n")

      {_text, blocks} = round_trip(old, new)
      assert length(blocks) == 3
    end

    test "two runs inside one hunk are two blocks, each only where something changes" do
      old = file(10)
      new = old |> String.replace("line 4\n", "four\n") |> String.replace("line 6\n", "six\n")
      {_text, blocks} = round_trip(old, new)
      assert Enum.map(blocks, &{&1.start, &1.end}) == [{4, 4}, {6, 6}]
    end

    test "insertion at the top of the file has an empty last and end 0" do
      old = file(5)
      {_text, [b]} = round_trip(old, "header\n" <> old)
      assert {b.start, b.end, b.first, b.last} == {1, 0, "line 1", ""}
    end

    test "an insertion whose neighbours are outside the hunk cannot be rendered" do
      # -U0: no context lines, so the line after the insertion is unknown
      patch = diff(file(5), String.replace(file(5), "line 3\n", "line 3\nnew\n"), 0)
      assert Examples.blocks(patch, "lib/x.ex") == :error
    end

    test "a new file is a create; a later chunk of a split new file is refused" do
      patch = "--- /dev/null\n+++ b/lib/n.ex\n@@ -0,0 +1,2 @@\n+one\n+two\n"
      assert {:ok, text} = Examples.blocks(patch, "lib/n.ex")

      assert {:ok, [%{path: "lib/n.ex", search: "", replace: "one\ntwo\n"}]} =
               Tools.text_edit_blocks(text, mode: :text)

      # +153 starts with "+1" (a live vortex entry rendered as a partial create)
      for start <- ["40", "153", "10"] do
        later = "--- /dev/null\n+++ b/lib/n.ex\n@@ -0,0 +#{start},2 @@\n+mid\n+file\n"
        assert Examples.blocks(later, "lib/n.ex") == :error
      end

      assert {:ok, _} =
               Examples.blocks("--- /dev/null\n+++ b/lib/n.ex\n@@ -0,0 +1 @@\n+one\n", "lib/n.ex")
    end
  end

  defp entry(id, attrs) do
    Map.merge(
      %{
        "id" => id,
        "repo" => "trailblazer",
        "path" => "lib/x.ex",
        "commit" => "c" <> id,
        "bug" => nil,
        "at" => 1_000,
        "date" => "2026-11-01T00:00:00Z",
        "label" => "succeeded",
        "request" => "Change #{id}",
        "patch" => diff(file(8), String.replace(file(8), "line 4\n", "changed #{id}\n"))
      },
      attrs
    )
  end

  defp similar(entries), do: fn _q, _k, _o -> {:ok, Enum.map(entries, &{0.7, &1})} end

  describe "exclude/3" do
    test "the request's own bugs (either id a prefix) and anything at or after the base go" do
      hits =
        for e <- [
              entry("a", %{"bug" => "abc1234"}),
              entry("b", %{"bug" => "abc1234ffff"}),
              entry("c", %{"bug" => "def5678"}),
              entry("d", %{"at" => 2_000}),
              entry("e", %{"at" => 1_999})
            ],
            do: {0.7, e}

      kept = Examples.exclude(hits, %{request: "Fix it bug:abc1234ff"}, 2_000)
      assert Enum.map(kept, &elem(&1, 1)["id"]) == ["c", "e"]
    end
  end

  describe "pick/1" do
    test "up to three positives (succeeded or open) and one caution, cautions last" do
      es = [
        entry("1", %{"label" => "fixed_up"}),
        entry("2", %{"label" => "open"}),
        entry("3", %{"label" => "reverted"}),
        entry("4", %{}),
        entry("5", %{}),
        entry("6", %{})
      ]

      assert Enum.map(Examples.pick(es), & &1["id"]) == ["2", "4", "5", "1"]
    end
  end

  describe "recall/2" do
    test "the reranker's order is kept, one per card, ids are returned" do
      entries = [
        entry("1", %{"bug" => "aaaaaaa"}),
        entry("2", %{"bug" => "aaaaaaa"}),
        entry("3", %{"bug" => "bbbbbbb"}),
        entry("4", %{})
      ]

      me = self()

      chat = fn [_sys, %{content: user}], _o ->
        send(me, {:listing, user})
        {:ok, %{content: "3, 1"}}
      end

      {:ok, r} =
        Examples.recall(%{request: "Change something", edit_mode: :text},
          similar: similar(entries),
          rerank_chat: chat,
          before: 5_000,
          budget: 100_000
        )

      assert_received {:listing, listing}
      # entry 2 shares card aaaaaaa with entry 1 and is collapsed away
      refute listing =~ "Change 2"
      # listing numbers: 1 -> entry 1, 2 -> entry 3, 3 -> entry 4
      assert r.ids == ["4", "1"]
      assert r.how == :rerank and r.considered == 3
      assert r.text =~ "### trailblazer lib/x.ex (succeeded, 2026-11-01)"
      assert r.text =~ ~s(<edit path="lib/x.ex" start="4" end="4">)
    end

    test "the reranker may say none fits: no section" do
      chat = fn _m, _o -> {:ok, %{content: "0"}} end

      assert {:ok, %{text: nil, ids: [], how: :rerank}} =
               Examples.recall(%{request: "x"},
                 similar: similar([entry("1", %{})]),
                 rerank_chat: chat
               )
    end

    test "a failed rerank leaves the vector order and says why" do
      chat = fn _m, _o -> {:error, :econnrefused} end

      {:ok, r} =
        Examples.recall(%{request: "x", edit_mode: :tool},
          similar: similar([entry("1", %{}), entry("2", %{})]),
          rerank_chat: chat,
          budget: 100_000
        )

      assert r.ids == ["1", "2"] and r.how == :similarity and r.rerank_error == :econnrefused
      assert r.text =~ "```diff"
    end

    test "examples over the budget are left out; nothing eligible means no section" do
      chat = fn _m, _o -> {:ok, %{content: "1"}} end

      assert {:ok, %{text: nil, ids: []}} =
               Examples.recall(%{request: "x"},
                 similar: similar([entry("1", %{})]),
                 rerank_chat: chat,
                 budget: 50
               )

      assert {:ok, %{text: nil, how: :empty, considered: 0}} =
               Examples.recall(%{request: "bug:abc1234"},
                 similar: similar([entry("1", %{"bug" => "abc1234"})]),
                 rerank_chat: chat
               )
    end

    test "a change to code that starts with edit tags is not shown" do
      patch =
        "--- a/p.md\n+++ b/p.md\n@@ -1,2 +1,2 @@\n a\n-<edit path=\"x\">\n+<edit path=\"y\">\n"

      assert Examples.render(entry("1", %{"patch" => patch}), :text) == :error
    end
  end

  test "the coder prompt carries the examples after the design" do
    [_system, user] =
      Prompts.coder(%{request: "r", design: "d"}, "trail", [], nil, %{examples: "EXAMPLES"})

    assert user.content =~ ~r/## Design\n\nd\n\n## Similar past changes\n\nEXAMPLES\n\n## Trail/
    [_system, plain] = Prompts.coder(%{request: "r"}, "t", [])
    refute plain.content =~ "Similar past"
  end
end
