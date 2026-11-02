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

  test "shared checkout provisioning refuses the original checkout and unrelated repositories",
       ctx do
    assert {:error, :same_checkout} = Workspace.provision_checkout(ctx.repo, ctx.repo)
    other = Path.join(Path.dirname(ctx.repo), "unrelated")
    File.mkdir_p!(other)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: other)
    assert {:error, :different_repo} = Workspace.provision_checkout(other, ctx.repo)
  end

  test "monorepo dependency links resolve candidate workspace code and survive reset", ctx do
    for package <- ["app", "lib"] do
      File.mkdir_p!(Path.join([ctx.repo, "packages", package]))
      File.write!(Path.join([ctx.repo, "packages", package, "package.json"]), "{}")
    end

    File.write!(
      Path.join(ctx.repo, "package.json"),
      ~s({"workspaces":{"packages":["packages/*"]}})
    )

    File.write!(Path.join(ctx.repo, "packages/lib/package.json"), ~s({"name":"@demo/lib"}))
    File.write!(Path.join([ctx.repo, "packages/lib/value.js"]), "base")
    ctx.git.(["add", "packages", "package.json"])
    ctx.git.(["commit", "-qm", "workspace fixture"])
    File.write!(Path.join(ctx.repo, ".git/info/exclude"), "node_modules/\n")
    File.mkdir_p!(Path.join(ctx.repo, "node_modules/external"))
    File.write!(Path.join(ctx.repo, "node_modules/external/index.js"), "external")
    File.mkdir_p!(Path.join(ctx.repo, "node_modules/@demo"))
    File.ln_s!(Path.join(ctx.repo, "packages/lib"), Path.join(ctx.repo, "node_modules/@demo/lib"))
    File.mkdir_p!(Path.join(ctx.repo, "packages/app/node_modules"))

    File.ln_s!(
      "../../../node_modules/external",
      Path.join(ctx.repo, "packages/app/node_modules/external")
    )

    File.ln_s!("../../lib", Path.join(ctx.repo, "packages/app/node_modules/local"))

    cache = Path.join(Path.dirname(ctx.repo), "dependency cache")
    File.rename!(Path.join(ctx.repo, "node_modules"), cache)
    File.ln_s!(cache, Path.join(ctx.repo, "node_modules"))
    {:ok, ws} = Workspace.open(ctx.repo, ctx.case_id)
    assert :ok = Workspace.provision(ws, ctx.repo)
    File.write!(Path.join(ws.path, "packages/lib/value.js"), "candidate")

    assert File.read!(Path.join(ws.path, "packages/app/node_modules/local/value.js")) ==
             "candidate"

    assert File.read!(Path.join(ws.path, "node_modules/@demo/lib/value.js")) == "candidate"
    assert File.read!(Path.join(ctx.repo, "packages/lib/value.js")) == "base"
    assert File.read!(Path.join(ctx.repo, "node_modules/@demo/lib/value.js")) == "base"

    assert File.read!(Path.join(ws.path, "packages/app/node_modules/external/index.js")) ==
             "external"

    assert :ok = Workspace.reset(ws)
    assert File.read!(Path.join(ws.path, "packages/app/node_modules/local/value.js")) == "base"

    assert File.read!(Path.join(ws.path, "packages/app/node_modules/external/index.js")) ==
             "external"
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

    assert {:ok, %{type: :directory}} = File.lstat(Path.join(ws.path, "node_modules"))
    assert {:ok, _} = File.read_link(Path.join(ws.path, "deps"))

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
end
