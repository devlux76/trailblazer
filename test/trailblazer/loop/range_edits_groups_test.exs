defmodule Trailblazer.Loop.RangeEditsTest.Groups do
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

  test "aliases of one file form one atomic range group", %{dir: dir} do
    write(dir, "lib/a.ex", "a\nb\n")
    sha = digest(dir, "lib/a.ex")

    blocks = [
      %{path: "lib/a.ex", type: :range, digest: sha, start: 1, end: 1, replace: "A\n"},
      %{path: "./lib/a.ex", type: :range, digest: sha, start: 2, end: 2, replace: "B\n"}
    ]

    assert {:ok, ["lib/a.ex"]} = Edits.apply(dir, blocks)
    assert read(dir, "lib/a.ex") == "A\nB\n"
  end

  test "a legacy alias cannot bypass the mixed-mode guard", %{dir: dir} do
    write(dir, "lib/a.ex", "a\nb\n")
    sha = digest(dir, "lib/a.ex")

    blocks = [
      %{path: "lib/a.ex", type: :range, digest: sha, start: 1, end: 1, replace: "A\n"},
      %{path: "./lib/a.ex", search: "b\n", replace: "B\n"}
    ]

    assert {:error, [%{reason: :mixed_edits}]} = Edits.apply(dir, blocks)
    assert read(dir, "lib/a.ex") == "a\nb\n"
  end

  test "whole-line replacements never join an untouched next statement", %{dir: dir} do
    for {original, replacement, expected} <- [
          {"old\nnext\n", "new", "new\nnext\n"},
          {"old\r\nnext\r\n", "new", "new\r\nnext\r\n"},
          {"old\nnext\n", "new\n", "new\nnext\n"},
          {"old\nnext\n", "", "next\n"},
          {"old\n", "new", "new"},
          {"old", "new", "new"}
        ] do
      write(dir, "lib/boundary.ex", original)

      block = %{
        path: "lib/boundary.ex",
        type: :range,
        digest: digest(dir, "lib/boundary.ex"),
        start: 1,
        end: 1,
        replace: replacement
      }

      assert {:ok, _} = Edits.apply(dir, [block])
      assert read(dir, "lib/boundary.ex") == expected
    end
  end

  test "separate import and fixture edits retain original line boundaries", %{dir: dir} do
    write(dir, "lib/boundary.ex", "import old\n\nconst peer = 'fake'\nconst addr = peer\n")
    hash = digest(dir, "lib/boundary.ex")

    blocks = [
      %{
        path: "lib/boundary.ex",
        type: :range,
        digest: hash,
        start: 1,
        end: 1,
        replace: "import old\nimport key"
      },
      %{
        path: "lib/boundary.ex",
        type: :range,
        digest: hash,
        start: 3,
        end: 3,
        replace: "const peer = key()"
      }
    ]

    assert {:ok, _} = Edits.apply(dir, blocks)

    assert read(dir, "lib/boundary.ex") ==
             "import old\nimport key\n\nconst peer = key()\nconst addr = peer\n"
  end
end
