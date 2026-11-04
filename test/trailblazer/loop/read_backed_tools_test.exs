defmodule Trailblazer.Loop.ReadBackedToolsTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Loop.{Edits, Tools}

  setup do
    dir = Path.join(System.tmp_dir!(), "read-backed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a read digest binds original CRLF and Unicode bytes to a range edit", %{dir: dir} do
    text = "same\r\n✓\r\nsame\r\n"
    File.write!(Path.join(dir, "a.txt"), text)
    digest = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
    read = Tools.call(dir, "read", ~s({"path":"a.txt"}))
    assert read =~ "sha256: #{digest}"
    assert read =~ "lines: 3"
    assert read =~ "3| same"

    block = %{path: "a.txt", sha256: digest, start: 3, end: 3, replace: "last\r\n"}
    assert {:ok, blocks} = Tools.edit_blocks(Jason.encode!(%{blocks: [block]}))
    assert {:ok, ["a.txt"]} = Edits.apply(dir, blocks, dry_run: true)
    assert File.read!(Path.join(dir, "a.txt")) == text
    assert {:ok, ["a.txt"]} = Edits.apply(dir, blocks)
    assert File.read!(Path.join(dir, "a.txt")) == "same\r\n✓\r\nlast\r\n"
  end

  test "empty files expose a digest and permit insertion", %{dir: dir} do
    File.write!(Path.join(dir, "empty"), "")
    digest = :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)
    assert Tools.call(dir, "read", ~s({"path":"empty"})) =~ "sha256: #{digest}\nlines: 0"
    block = %{path: "empty", sha256: digest, start: 1, end: 0, replace: "new"}
    assert {:ok, blocks} = Tools.edit_blocks(Jason.encode!(%{blocks: [block]}))
    assert {:ok, _} = Edits.apply(dir, blocks)
    assert File.read!(Path.join(dir, "empty")) == "new"
  end

  test "strict range decoding refuses mixed modes and malformed fields" do
    valid = %{path: "a", sha256: String.duplicate("a", 64), start: 1, end: 0, replace: "✓\n"}

    for invalid <- [
          Map.put(valid, :search, ""),
          Map.put(valid, :extra, true),
          %{valid | sha256: String.duplicate("A", 64)},
          %{valid | start: true},
          %{valid | start: 0},
          %{valid | end: -1},
          %{valid | end: "0"}
        ] do
      assert {:error, _} = Tools.edit_blocks(Jason.encode!(%{blocks: [invalid]}))
    end
  end

  test "stale digest feedback is bounded and never repeats replacement code", %{dir: dir} do
    File.write!(Path.join(dir, "a.txt"), "actual\n")

    block = %{
      path: "a.txt",
      type: :range,
      digest: String.duplicate("0", 64),
      start: 1,
      end: 1,
      replace: String.duplicate("REPLACEMENT_SENTINEL", 1000)
    }

    assert {:error, failures} = Edits.apply(dir, [block])
    feedback = Edits.feedback(failures)
    assert feedback =~ "stale_digest"
    assert feedback =~ "current sha256:"
    assert feedback =~ "1| actual"
    refute feedback =~ "REPLACEMENT_SENTINEL"
    assert byte_size(feedback) < 2000
  end

  test "feedback bounds large source diagnostics without repeating replacement" do
    failure = %{
      block: %{path: "a", search: "x", replace: "PRIVATE_REPLACEMENT"},
      reason: :no_match,
      closest: String.duplicate("actual source ", 3000)
    }

    feedback = Edits.feedback([failure])
    assert String.length(feedback) <= 12_200
    assert feedback =~ "truncated"
    refute feedback =~ "PRIVATE_REPLACEMENT"
  end

  test "preview does not create directories for a new legacy file", %{dir: dir} do
    assert {:ok, ["deep/new.txt"]} =
             Edits.apply(dir, [%{path: "deep/new.txt", search: "", replace: "new"}],
               dry_run: true
             )

    refute File.exists?(Path.join(dir, "deep"))
  end

  test "ambiguous legacy SEARCH never silently chooses the first occurrence", %{dir: dir} do
    original = "before\nsame\nmiddle\nsame\nafter\n"
    File.write!(Path.join(dir, "a.txt"), original)

    assert {:error, _} =
             Edits.apply(dir, [%{path: "a.txt", search: "same\n", replace: "changed\n"}])

    assert File.read!(Path.join(dir, "a.txt")) == original
  end

  test "in-repository symlink aliases share one range target", %{dir: dir} do
    original = "one\ntwo\n"
    File.write!(Path.join(dir, "a.txt"), original)
    File.ln_s!("a.txt", Path.join(dir, "alias.txt"))
    hash = :crypto.hash(:sha256, original) |> Base.encode16(case: :lower)

    blocks = [
      %{path: "alias.txt", type: :range, digest: hash, start: 1, end: 1, replace: "ONE\n"},
      %{path: "a.txt", type: :range, digest: hash, start: 2, end: 2, replace: "TWO\n"}
    ]

    assert {:ok, ["a.txt"]} = Edits.apply(dir, blocks)
    assert File.read!(Path.join(dir, "a.txt")) == "ONE\nTWO\n"
    assert File.read_link!(Path.join(dir, "alias.txt")) == "a.txt"
  end
end
