defmodule Trailblazer.FilesTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Files

  @fixture Path.expand("../fixtures/mini", __DIR__)
  @max_bytes 400_000

  setup do
    tmp =
      Path.join([System.tmp_dir!(), "trailblazer_files_#{System.os_time(:nanosecond)}"])

    on_exit(fn -> File.rm_rf!(tmp) end)

    repo = Path.join(tmp, "mini")
    File.mkdir_p!(tmp)
    File.cp_r!(@fixture, repo)

    # what must not be listed: ignored by git, empty, too big, and not a
    # language the core parses
    File.write!(Path.join(repo, ".gitignore"), "ignored.ex\n")
    File.write!(Path.join(repo, "ignored.ex"), "defmodule Ignored do end\n")
    File.write!(Path.join(repo, "empty.js"), "")
    File.write!(Path.join(repo, "huge.js"), String.duplicate("x", @max_bytes + 1))
    File.write!(Path.join(repo, "at_the_limit.js"), String.duplicate("x", @max_bytes))
    File.write!(Path.join(repo, "notes.txt"), "notes, not code\n")

    outside = Path.join(tmp, "outside.ex")
    File.write!(outside, "defmodule Outside do end\n")
    File.ln_s!(outside, Path.join(repo, "escape.ex"))

    %{repo: repo}
  end

  test "list names each file, its language, its size and the hash of its content", %{repo: repo} do
    file = find(repo, "lib/store.ex")

    assert file.mtime == File.stat!(Path.join(repo, "lib/store.ex"), time: :posix).mtime
    assert file.lang == :elixir
    assert file.size == byte_size(File.read!(Path.join(repo, "lib/store.ex")))
    assert file.hash == sha256(File.read!(Path.join(repo, "lib/store.ex")))
  end

  test "list gives every suffix the core parses its language", %{repo: repo} do
    languages = Map.new(Files.list(repo), &{&1.path, &1.lang})

    assert languages["lib/store.ex"] == :elixir
    assert languages["test/support/store.ex"] == :elixir
    assert languages["web/app.ts"] == :typescript
    assert languages["tools/util.py"] == :python
    assert languages["docs/design.md"] == :markdown
  end

  test "list leaves out what git ignores, what is empty, what is too big and what it cannot parse",
       %{repo: repo} do
    paths = Enum.map(Files.list(repo), & &1.path)

    assert "lib/store.ex" in paths
    assert "at_the_limit.js" in paths
    assert "ignored.ex" not in paths
    assert "empty.js" not in paths
    assert "huge.js" not in paths
    assert "notes.txt" not in paths
    assert ".gitignore" not in paths
  end

  test "list reads the whole fixture", %{repo: repo} do
    assert Enum.sort(Enum.map(Files.list(repo), & &1.path)) == [
             "at_the_limit.js",
             "docs/design.md",
             "lib/app.ex",
             "lib/store.ex",
             "test/support/store.ex",
             "tools/index.py",
             "tools/util.py",
             "web/app.ts",
             "web/save.ts"
           ]
  end

  test "list names a file whose name holds a newline" do
    repo =
      Path.join([System.tmp_dir!(), "trailblazer_newline_#{System.os_time(:nanosecond)}"])

    on_exit(fn -> File.rm_rf!(repo) end)
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "line\nbreak.ex"), "defmodule Broken do end\n")

    assert [%{path: "line\nbreak.ex", lang: :elixir}] = Files.list(repo)
  end

  test "list tells each of the other suffixes apart" do
    repo =
      Path.join([System.tmp_dir!(), "trailblazer_suffixes_#{System.os_time(:nanosecond)}"])

    on_exit(fn -> File.rm_rf!(repo) end)
    File.mkdir_p!(repo)

    for suffix <- ~w(ex exs js jsx mjs cjs ts tsx py md) do
      File.write!(Path.join(repo, "file.#{suffix}"), "content\n")
    end

    File.write!(Path.join(repo, "SHOUTING.TS"), "content\n")

    assert Map.new(Files.list(repo), &{&1.path, &1.lang}) == %{
             "SHOUTING.TS" => :typescript,
             "file.ex" => :elixir,
             "file.exs" => :elixir,
             "file.js" => :javascript,
             "file.jsx" => :javascript,
             "file.mjs" => :javascript,
             "file.cjs" => :javascript,
             "file.ts" => :typescript,
             "file.tsx" => :tsx,
             "file.py" => :python,
             "file.md" => :markdown
           }
  end

  test "list of a repo with nothing to list is empty" do
    repo =
      Path.join([System.tmp_dir!(), "trailblazer_empty_#{System.os_time(:nanosecond)}"])

    on_exit(fn -> File.rm_rf!(repo) end)
    File.mkdir_p!(repo)

    assert Files.list(repo) == []
  end

  test "read gives the content of a file inside the repo", %{repo: repo} do
    assert {:ok, content} = Files.read(repo, "lib/store.ex")
    assert content =~ "def put(hikes, opts)"
  end

  test "read says so when the file is not there", %{repo: repo} do
    assert Files.read(repo, "lib/nowhere.ex") == {:error, :enoent}
  end

  test "read refuses a path out of the repo", %{repo: repo} do
    assert Files.read(repo, "../x") == {:error, :outside_repo}
    assert Files.read(repo, "/etc/passwd") == {:error, :outside_repo}
    assert Files.read(repo, "lib/../../x") == {:error, :outside_repo}
    assert Files.read(repo, "/..") == {:error, :outside_repo}
    assert Files.read(repo, "/") == {:error, :outside_repo}
  end

  test "read refuses a symlink inside the repo that leads out of it", %{repo: repo} do
    assert Files.read(repo, "escape.ex") == {:error, :outside_repo}
  end

  test "read refuses a symlinked directory inside the repo that leads out of it", %{repo: repo} do
    outside = Path.join(Path.dirname(repo), "elsewhere")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secrets.ex"), "defmodule Secrets do end\n")
    File.ln_s!(outside, Path.join(repo, "out"))

    assert Files.read(repo, "out/secrets.ex") == {:error, :outside_repo}

    # `..` after a symlink means the directory the link points at, not the one
    # it sits in, so this leaves the repo
    assert Files.read(repo, "out/../lib/store.ex") == {:error, :outside_repo}
  end

  test "read refuses what the repository pointed at a moment ago", %{repo: repo} do
    inside = Path.join(repo, "inside")
    File.mkdir_p!(inside)
    File.write!(Path.join(inside, "kept.ex"), "defmodule Kept do end\n")

    outside = Path.join(Path.dirname(repo), "swapped")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "kept.ex"), "defmodule Outside do end\n")

    # the directory inside the repository is swapped for a symlink to one
    # outside it, between the read and the second check
    swap = fn ->
      File.rename!(inside, Path.join(repo, "moved"))
      File.ln_s!(outside, inside)
    end

    assert Files.read(repo, "inside/kept.ex", after_read: swap) == {:error, :outside_repo}
  end

  test "read refuses a file that was replaced by another file", %{repo: repo} do
    File.write!(Path.join(repo, "swapped.ex"), "defmodule First do end\n")

    replace = fn ->
      File.rm!(Path.join(repo, "swapped.ex"))
      File.write!(Path.join(repo, "swapped.ex"), "defmodule Second do end\n")
    end

    assert Files.read(repo, "swapped.ex", after_read: replace) == {:error, :outside_repo}
  end

  test "read follows a symlink that stays inside the repo", %{repo: repo} do
    File.ln_s!(Path.join(repo, "lib/store.ex"), Path.join(repo, "linked.ex"))

    assert {:ok, content} = Files.read(repo, "linked.ex")
    assert content =~ "def put(hikes, opts)"
  end

  test "vendored trees bypass ignores while node_modules and build output stay out", %{repo: repo} do
    File.write!(
      Path.join(repo, ".gitignore"),
      "deps/\nvendor/\nvendored/\nthird_party/\nnode_modules/\n_build/\ntarget/\n"
    )

    kept = ["deps/foo/lib/a.ex", "vendor/z/a.cpp", "nested/vendored/a.go", "third_party/x/a.c"]

    skipped = [
      "node_modules/x/b.js",
      "deps/foo/node_modules/x/b.js",
      "deps/foo/_build/b.ex",
      "vendor/z/target/b.c"
    ]

    for path <- kept ++ skipped do
      File.mkdir_p!(Path.dirname(Path.join(repo, path)))
      File.write!(Path.join(repo, path), "content\n")
    end

    paths = Enum.map(Files.list(repo), & &1.path)
    assert Enum.all?(kept, &(&1 in paths))
    assert Enum.all?(skipped, &(&1 not in paths))
  end

  test "C, C++, CUDA and Go suffixes use their grammar", %{repo: repo} do
    suffixes = ~w(c h hh hpp hxx cc cpp cxx cu cuh go)
    for suffix <- suffixes, do: File.write!(Path.join(repo, "new.#{suffix}"), "content\n")
    langs = Map.new(Files.list(repo), &{&1.path, &1.lang})
    assert langs["new.c"] == :c
    assert langs["new.go"] == :go
    for suffix <- suffixes -- ["c", "go"], do: assert(langs["new.#{suffix}"] == :cpp)
  end

  defp find(repo, path) do
    case Enum.find(Files.list(repo), &(&1.path == path)) do
      nil -> raise "#{path} is not listed"
      file -> file
    end
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
