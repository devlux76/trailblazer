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

    block = %{
      path: "a.txt",
      sha256: digest,
      start: 3,
      end: 3,
      first: "same",
      last: "same",
      replace: "last\r\n"
    }

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

    block = %{
      path: "empty",
      sha256: digest,
      start: 1,
      end: 0,
      first: "",
      last: "",
      replace: "new"
    }

    assert {:ok, blocks} = Tools.edit_blocks(Jason.encode!(%{blocks: [block]}))
    assert {:ok, _} = Edits.apply(dir, blocks)
    assert File.read!(Path.join(dir, "empty")) == "new"
  end

  test "strict range decoding refuses mixed modes and malformed fields" do
    valid = %{
      path: "a",
      sha256: String.duplicate("a", 64),
      start: 1,
      end: 0,
      first: "",
      last: "",
      replace: "✓\n"
    }

    assert {:ok, [%{first: "", last: ""}]} = Tools.edit_blocks(Jason.encode!(%{blocks: [valid]}))

    for invalid <- [
          Map.delete(valid, :first),
          Map.delete(valid, :last),
          %{valid | last: nil},
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

  # Replays qual2 turn 3: openContact began at line 20, the model sent start 12
  # and silently deleted encodeContact (lines 12-19). The quoted first line
  # sits uniquely at 20, but 12-22 to 20-22 is too large a change to relocate,
  # so it is refused naming line 20; an ambiguous quote is refused too.
  test "a large miscount is refused naming the real line; ambiguity refuses", %{
    dir: dir
  } do
    text =
      Enum.map_join(1..11, "", &"// header #{&1}\n") <>
        "export function encodeContact (addrs: string[]): Uint8Array {\n" <>
        "  return Contact.encode({ addrs })\n}\n\n/**\n * doc\n * more\n */\n" <>
        "export function openContact (contact: Uint8Array, peer: string) {\n  return 1\n}\n"

    File.write!(Path.join(dir, "contact.ts"), text)
    sha = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

    block = %{
      path: "contact.ts",
      sha256: sha,
      start: 12,
      end: 22,
      first: "export function openContact (contact: Uint8Array, peer: string) {",
      last: "}",
      replace: "export function openContact () {\n  return 2\n}\n"
    }

    # Ambiguous: the quoted first line "}" fits lines 14 and 22.
    ambiguous = %{block | first: "}", last: "}"}
    assert {:ok, blocks} = Tools.edit_blocks(Jason.encode!(%{blocks: [ambiguous]}))
    assert {:error, [failure]} = Edits.apply(dir, blocks)
    assert failure.reason == :anchor_mismatch
    feedback = Edits.feedback([failure])
    assert feedback =~ "line 12 is \"export function encodeContact"
    assert feedback =~ "it fits first = line 14, 22"
    refute feedback =~ "Each SEARCH"
    refute feedback =~ "return 2"
    assert File.read!(Path.join(dir, "contact.ts")) == text

    # Unique quote but an 8-line miscount: too far to relocate, refused with
    # the line where it fits; the recount applies and encodeContact survives.
    assert {:ok, blocks} = Tools.edit_blocks(Jason.encode!(%{blocks: [block]}))
    assert {:error, [failure]} = Edits.apply(dir, blocks)
    assert Edits.feedback([failure]) =~ "it fits first = line 20"
    assert {:ok, blocks} = Tools.edit_blocks(Jason.encode!(%{blocks: [%{block | start: 20}]}))
    assert {:ok, ["contact.ts"]} = Edits.apply(dir, blocks)
    assert File.read!(Path.join(dir, "contact.ts")) =~ "export function encodeContact"
    assert File.read!(Path.join(dir, "contact.ts")) =~ "return 2"
    refute File.read!(Path.join(dir, "contact.ts")) =~ "return 1"
  end

  # Replays qual3 turn 1: the model quoted the whole old range as first and
  # its last two lines as last. Correct multi-line quotes apply; a quote that
  # is one line off is refused and located.
  test "multi-line quotes are checked line by line from start and up to end", %{dir: dir} do
    text = "a\n/**\n * doc\n */\nfn x {\n  return addrs\n}\nz\n"
    File.write!(Path.join(dir, "m.txt"), text)
    sha = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

    block = fn start, last_line, first, last ->
      %{
        path: "m.txt",
        sha256: sha,
        start: start,
        end: last_line,
        first: first,
        last: last,
        replace: "R\n"
      }
    end

    whole = "/**\n * doc\n */\nfn x {\n  return addrs\n}\n"

    assert {:ok, blocks} =
             Tools.edit_blocks(Jason.encode!(%{blocks: [block.(2, 7, whole, "return addrs\n}")]}))

    assert {:ok, ["m.txt"]} = Edits.apply(dir, blocks, dry_run: true)

    assert {:ok, blocks} = Tools.edit_blocks(Jason.encode!(%{blocks: [block.(1, 7, whole, "}")]}))
    # Miscounted start / end with unique quotes: relocated to 2-7, not refused,
    # and reported to the caller.
    me = self()
    on = fn r -> send(me, {:relocated, r}) end
    assert {:ok, ["m.txt"]} = Edits.apply(dir, blocks, dry_run: true, on_relocate: on)
    assert_received {:relocated, %{path: "m.txt", from: {1, 7}, to: {2, 7}} = r}
    assert Edits.relocation_notice(r) =~ "range 1-7 in m.txt was applied as lines 2-7"

    assert {:ok, blocks} =
             Tools.edit_blocks(Jason.encode!(%{blocks: [block.(2, 8, "/**", "return addrs\n}")]}))

    assert {:ok, ["m.txt"]} = Edits.apply(dir, blocks, dry_run: true)

    # Reviewer cases for relocation: a unique far quote cannot stretch the
    # range over unrelated code, nor can a generic line at the stated position.
    far = "x\ndef f1 do\n  a\nend\ndef f2 do\n  keep\nend\ndef f3 do\n  target\nend\n"
    File.write!(Path.join(dir, "far.ex"), far)
    fsha = :crypto.hash(:sha256, far) |> Base.encode16(case: :lower)

    for {first, last} <- [{"def f1 do", "  target"}, {"end", "  keep"}] do
      b = %{
        path: "far.ex",
        sha256: fsha,
        start: 2,
        end: 4,
        first: first,
        last: last,
        replace: "R\n"
      }

      assert {:ok, blocks} = Tools.edit_blocks(Jason.encode!(%{blocks: [b]}))
      assert {:error, [%{reason: :anchor_mismatch}]} = Edits.apply(dir, blocks)
    end

    assert File.read!(Path.join(dir, "far.ex")) == far

    # Reviewer cases: a quote longer than the range exposes a miscounted end
    # (overrun) or start (underrun) even when the other quote matches.
    assert {:ok, blocks} =
             Tools.edit_blocks(Jason.encode!(%{blocks: [block.(2, 5, whole, " */")]}))

    assert {:error, [failure]} = Edits.apply(dir, blocks)
    assert Edits.feedback([failure]) =~ "has 6 lines but the range 2-5 has 4"

    assert {:ok, blocks} =
             Tools.edit_blocks(Jason.encode!(%{blocks: [block.(3, 7, " * doc", whole)]}))

    assert {:error, [_]} = Edits.apply(dir, blocks)

    # An insertion's quotes are context in a fixed direction and may span lines.
    insert = %{block.(5, 4, "fn x {\n  return addrs", "/**\n * doc\n */") | replace: "I\n"}
    assert {:ok, blocks} = Tools.edit_blocks(Jason.encode!(%{blocks: [insert]}))
    assert {:ok, _} = Edits.apply(dir, blocks, dry_run: true)

    assert {:ok, blocks} =
             Tools.edit_blocks(Jason.encode!(%{blocks: [block.(2, 7, "/**\n * nope", "}")]}))

    assert {:error, [failure]} = Edits.apply(dir, blocks)
    assert Edits.feedback([failure]) =~ "do not appear consecutively"
    assert File.read!(Path.join(dir, "m.txt")) == text
  end

  test "insertion quotes the neighbouring lines; past either end quotes empty", %{dir: dir} do
    File.write!(Path.join(dir, "b.txt"), "one\ntwo\n")
    sha = :crypto.hash(:sha256, "one\ntwo\n") |> Base.encode16(case: :lower)

    insert = fn start, first, last ->
      %{
        path: "b.txt",
        sha256: sha,
        start: start,
        end: start - 1,
        first: first,
        last: last,
        replace: "X\n"
      }
    end

    for {start, first, last} <- [{1, "one", ""}, {2, "two", "one"}, {3, "", "two"}] do
      assert {:ok, blocks} =
               Tools.edit_blocks(Jason.encode!(%{blocks: [insert.(start, first, last)]}))

      assert {:ok, _} = Edits.apply(dir, blocks, dry_run: true)
    end

    assert {:ok, blocks} = Tools.edit_blocks(Jason.encode!(%{blocks: [insert.(2, "one", "two")]}))
    assert {:error, [%{reason: :anchor_mismatch}]} = Edits.apply(dir, blocks)
    assert File.read!(Path.join(dir, "b.txt")) == "one\ntwo\n"
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

  test "empty SEARCH on an existing file refuses append and supplies full-range guidance", %{
    dir: dir
  } do
    original = "one\ntwo\n"
    File.write!(Path.join(dir, "a.txt"), original)
    hash = :crypto.hash(:sha256, original) |> Base.encode16(case: :lower)
    assert {:error, failures} = Edits.apply(dir, [%{path: "a.txt", search: "", replace: "new\n"}])
    assert File.read!(Path.join(dir, "a.txt")) == original
    feedback = Edits.feedback(failures)
    assert feedback =~ "file_exists"
    assert feedback =~ "sha256: #{hash}"
    assert feedback =~ "start: 1, end: 2"
  end
end
