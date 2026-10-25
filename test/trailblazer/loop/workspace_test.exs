defmodule Trailblazer.Loop.WorkspaceTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Loop.Workspace
  alias Trailblazer.Config

  setup do
    root = Path.join(System.tmp_dir!(), "trailblazer-ws-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo with space")
    File.mkdir_p!(repo)

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: repo)
      String.trim(out)
    end

    git.(["init", "-q"])
    git.(["config", "user.name", "Test"])
    git.(["config", "user.email", "test@example.invalid"])
    File.write!(Path.join(repo, "tracked.txt"), "base\n")
    git.(["add", "."])
    git.(["commit", "-qm", "base"])
    case_id = "case-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      for dir <- Path.wildcard(Path.join([Config.get(:state_dir), "worktrees", case_id <> "*"])) do
        System.cmd("git", ["worktree", "remove", "--force", dir],
          cd: repo,
          stderr_to_stdout: true
        )
      end

      File.rm_rf!(root)
    end)

    %{repo: repo, git: git, case_id: case_id}
  end

  test "open isolates HEAD and preserves dirty checkout; diff includes new files; commit keeps branch",
       ctx do
    File.write!(Path.join(ctx.repo, "tracked.txt"), "operator dirty\n")
    assert {:ok, ws} = Workspace.open(ctx.repo, ctx.case_id)
    assert ws.branch == "trailblazer/" <> ctx.case_id
    assert File.read!(Path.join(ws.path, "tracked.txt")) == "base\n"
    File.write!(Path.join(ws.path, "tracked.txt"), "changed\n")
    File.write!(Path.join(ws.path, "new.txt"), "new\n")
    assert Workspace.diff(ws) =~ "+changed"
    assert Workspace.diff(ws) =~ "new.txt"
    assert {:ok, sha} = Workspace.commit(ws, "case fix")
    assert sha != ws.base
    assert :ok = Workspace.close(ws)
    refute File.exists?(ws.path)
    assert ctx.git.(["rev-parse", ws.branch]) == sha
    assert File.read!(Path.join(ctx.repo, "tracked.txt")) == "operator dirty\n"
    assert ctx.git.(["rev-parse", "HEAD"]) == ws.base
  end

  test "reset clears tracked, untracked and ignored attempt output only in its worktree", ctx do
    {:ok, ws} = Workspace.open(ctx.repo, ctx.case_id)
    File.write!(Path.join(ws.path, "tracked.txt"), "changed\n")
    File.write!(Path.join(ws.path, ".gitignore"), "output/\n")
    File.mkdir_p!(Path.join(ws.path, "output"))
    File.write!(Path.join(ws.path, "output/generated.txt"), "junk")
    assert :ok = Workspace.reset(ws)
    assert File.read!(Path.join(ws.path, "tracked.txt")) == "base\n"
    refute File.exists?(Path.join(ws.path, "output"))
  end

  test "opening a worktree does not run checkout hooks in the caller repo", ctx do
    hook = Path.join(ctx.repo, ".git/hooks/post-checkout")
    File.write!(hook, "#!/bin/sh\nprintf touched > '#{ctx.repo}/hook-ran'\n")
    File.chmod!(hook, 0o755)
    assert {:ok, _} = Workspace.open(ctx.repo, ctx.case_id)
    refute File.exists?(Path.join(ctx.repo, "hook-ran"))
  end

  test "case collisions, unsafe ids and own repository are refused", ctx do
    {:ok, ws} = Workspace.open(ctx.repo, ctx.case_id)
    assert {:error, _} = Workspace.open(ctx.repo, ctx.case_id)
    assert {:error, _} = Workspace.open(ctx.repo, "../escape")
    assert {:error, _} = Workspace.open(ctx.repo, "bad; touch x")
    assert {:error, :own_repo} = Workspace.open(File.cwd!(), ctx.case_id <> "own")
    assert {:error, _} = Workspace.reset(%{ws | path: ctx.repo})
  end

  test "provisioned dependencies survive resets and build outputs are isolated copies", ctx do
    for name <- ~w(node_modules deps _build target) do
      File.mkdir_p!(Path.join(ctx.repo, name))
      File.write!(Path.join([ctx.repo, name, "probe"]), "original")
    end

    File.write!(
      Path.join(ctx.repo, ".git/info/exclude"),
      "node_modules/\ndeps/\n_build/\ntarget/\n"
    )

    {:ok, ws} = Workspace.open(ctx.repo, ctx.case_id)
    assert :ok = Workspace.provision(ws, ctx.repo)

    for name <- ~w(node_modules deps),
        do: assert(match?({:ok, _}, File.read_link(Path.join(ws.path, name))))

    File.write!(Path.join([ws.path, "_build", "probe"]), "changed")
    assert File.read!(Path.join([ctx.repo, "_build", "probe"])) == "original"
    assert :ok = Workspace.reset(ws)
    assert File.read!(Path.join([ws.path, "node_modules", "probe"])) == "original"
    assert File.read!(Path.join([ws.path, "deps", "probe"])) == "original"
    assert File.read!(Path.join([ws.path, "target", "probe"])) == "original"
  end

  test "an independent clone of Trailblazer is refused", ctx do
    clone = Path.join(Path.dirname(ctx.repo), "separate-clone")

    assert {_, 0} =
             System.cmd("git", ["clone", "--quiet", "--no-hardlinks", File.cwd!(), clone],
               stderr_to_stdout: true
             )

    result = Workspace.open(clone, ctx.case_id)

    case result do
      {:ok, ws} -> Workspace.close(ws)
      _ -> :ok
    end

    assert {:error, :own_repo} = result
  end

  test "prune removes only this repo's old managed worktrees and preserves branches", ctx do
    {:ok, old} = Workspace.open(ctx.repo, ctx.case_id <> "-old")
    {:ok, fresh} = Workspace.open(ctx.repo, ctx.case_id <> "-fresh")
    File.touch!(old.path, 1_600_000_000)
    assert :ok = Workspace.prune(ctx.repo, 1_600_000_001)
    refute File.exists?(old.path)
    assert File.exists?(fresh.path)
    assert ctx.git.(["rev-parse", old.branch]) == old.base
  end
end
