defmodule Trailblazer.GitTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Git

  setup do
    repo = Path.join(System.tmp_dir!(), "trailblazer-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "main"])
    on_exit(fn -> File.rm_rf!(repo) end)
    %{repo: repo}
  end

  test "an unborn HEAD, then a commit", %{repo: repo} do
    assert Git.head(repo) == {:ok, :unborn}
    File.write!(Path.join(repo, "a.txt"), "a")
    assert Git.status(repo) == {:ok, %{changed: [], removed: [], untracked: ["a.txt"]}}
    assert Git.changed(repo, "HEAD") == {:error, :unborn}
    commit(repo, "one")
    assert {:ok, oid} = Git.head(repo)
    assert oid =~ ~r/^[0-9a-f]{40,64}$/
  end

  test "which of some paths git ignores", %{repo: repo} do
    File.write!(Path.join(repo, ".gitignore"), "*.log\n")
    File.write!(Path.join(repo, ".git/info/exclude"), "private.md\n")
    assert Git.ignored(repo, ["a.log", "private.md", "a.ex", "-dash.ex"]) ==
             {:ok, ["a.log", "private.md"]}

    assert Git.ignored(repo, ["a.ex"]) == {:ok, []}
    assert Git.ignored(repo, []) == {:ok, []}
    assert Git.ignored(repo <> "-missing", ["a.log"]) == {:error, :not_a_work_tree}
  end

  test "not a work tree, or gone", %{repo: repo} do
    plain = repo <> "-plain"
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf!(plain) end)
    assert Git.head(plain) == {:error, :not_a_work_tree}
    assert Git.status(plain) == {:error, :not_a_work_tree}
    assert Git.head(repo <> "-missing") == {:error, :not_a_work_tree}
  end

  test "commits between two heads: added, modified, removed, renamed", %{repo: repo} do
    write(repo, %{"keep.txt" => "k", "edit.txt" => "1", "gone.txt" => "g", "old name.txt" => "o"})
    commit(repo, "one")
    {:ok, first} = Git.head(repo)

    write(repo, %{"edit.txt" => "2", "new\nline.txt" => "n", "sub/ü.ex" => "u"})
    File.rm!(Path.join(repo, "gone.txt"))
    git(repo, ["mv", "old name.txt", "new name.txt"])
    commit(repo, "two")

    assert {:ok, %{changed: changed, removed: removed}} = Git.changed(repo, first)
    assert Enum.sort(changed) == ["edit.txt", "new\nline.txt", "new name.txt", "sub/ü.ex"]
    assert Enum.sort(removed) == ["gone.txt", "old name.txt"]
    {:ok, head} = Git.head(repo)
    assert Git.changed(repo, head) == {:ok, %{changed: [], removed: []}}
  end

  test "a commit that no longer exists, or a bad id, is unknown (J24)", %{repo: repo} do
    write(repo, %{"a.txt" => "a"})
    commit(repo, "one")
    assert Git.changed(repo, String.duplicate("0", 40)) == {:error, :unknown_commit}
    assert Git.changed(repo, "--output=/tmp/x") == {:error, :unknown_commit}
    assert Git.changed(repo, "") == {:error, :unknown_commit}
  end

  test "the work tree against HEAD", %{repo: repo} do
    write(repo, %{"mod.txt" => "1", "staged.txt" => "1", "del.txt" => "d", "rm.txt" => "r"})
    commit(repo, "one")

    write(repo, %{
      "mod.txt" => "2",
      "staged.txt" => "2",
      "with space.txt" => "s",
      "dir/x.txt" => "x"
    })

    git(repo, ["add", "staged.txt"])
    File.rm!(Path.join(repo, "del.txt"))
    git(repo, ["rm", "-q", "rm.txt"])
    File.write!(Path.join(repo, ".gitignore"), "ignored/\n")
    write(repo, %{"ignored/i.txt" => "i"})

    assert {:ok, s} = Git.status(repo)
    assert Enum.sort(s.changed) == ["mod.txt", "staged.txt"]
    assert Enum.sort(s.removed) == ["del.txt", "rm.txt"]
    assert Enum.sort(s.untracked) == [".gitignore", "dir/x.txt", "with space.txt"]
  end

  test "an added file deleted again is removed; a staged rename is both", %{repo: repo} do
    write(repo, %{"a.txt" => "a"})
    commit(repo, "one")
    write(repo, %{"tmp.txt" => "t"})
    git(repo, ["add", "tmp.txt"])
    File.rm!(Path.join(repo, "tmp.txt"))
    git(repo, ["mv", "a.txt", "b.txt"])
    assert {:ok, s} = Git.status(repo)
    assert Enum.sort(s.removed) == ["a.txt", "tmp.txt"]
    assert s.changed == ["b.txt"]
  end

  test "paths are relative to the root even from a subdirectory's config", %{repo: repo} do
    git(repo, ["config", "status.relativePaths", "true"])
    write(repo, %{"top.txt" => "t", "sub/s.txt" => "s"})
    assert {:ok, %{untracked: untracked}} = Git.status(repo)
    assert Enum.sort(untracked) == ["sub/s.txt", "top.txt"]
  end

  test "status writes nothing under .git (J21)", %{repo: repo} do
    write(repo, %{"a.txt" => "a"})
    commit(repo, "one")
    # An index older than the file's mtime would make a plain status refresh it.
    File.touch!(Path.join(repo, "a.txt"), System.os_time(:second) + 5)
    before = snapshot(Path.join(repo, ".git"))
    assert {:ok, _} = Git.status(repo)
    assert {:ok, _} = Git.files(repo)
    assert snapshot(Path.join(repo, ".git")) == before
  end

  test "a repository's config cannot make these calls run a program", %{repo: repo} do
    marker = Path.join(repo, "ran")
    hook = Path.join(repo, "hook.sh")
    File.write!(hook, "#!/bin/sh\ntouch #{marker}\n")
    File.chmod!(hook, 0o755)
    write(repo, %{"a.txt" => "a"})
    commit(repo, "one")
    # Set after the commit: the test's own git honours it.
    git(repo, ["config", "core.fsmonitor", hook])
    assert {:ok, _} = Git.status(repo)
    assert {:ok, _} = Git.files(repo)
    refute File.exists?(marker)
  end

  test "files lists tracked and untracked, not ignored", %{repo: repo} do
    write(repo, %{"a.txt" => "a", ".gitignore" => "*.log\n"})
    commit(repo, "one")
    write(repo, %{"b.txt" => "b", "x.log" => "l"})
    assert {:ok, files} = Git.files(repo)
    assert Enum.sort(files) == [".gitignore", "a.txt", "b.txt"]
  end

  test "a linked worktree has its own git dir", %{repo: repo} do
    write(repo, %{"a.txt" => "a"})
    commit(repo, "one")
    linked = repo <> "-linked"
    git(repo, ["worktree", "add", "-q", "-b", "side", linked])
    on_exit(fn -> File.rm_rf!(linked) end)
    assert {:ok, main_dir} = Git.git_dir(repo)
    assert main_dir == Path.join(repo, ".git")
    assert {:ok, dir} = Git.git_dir(linked)
    assert dir == Path.join([repo, ".git", "worktrees", Path.basename(linked)])
  end

  defp snapshot(dir) do
    for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
        not String.contains?(path, "/objects/"),
        File.regular?(path),
        into: %{},
        do: {path, File.stat!(path, time: :posix) |> Map.take([:size, :mtime])}
  end

  defp write(repo, files) do
    for {name, text} <- files do
      path = Path.join(repo, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, text)
    end
  end

  defp commit(repo, message) do
    git(repo, ["add", "-A"])
    git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message])
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
