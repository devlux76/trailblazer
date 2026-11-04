defmodule Trailblazer.Loop.CompiledCheckpointTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Loop.{CompiledCheckpoint, Workspace}

  defmodule Index do
    def watch(_), do: {:ok, self()}

    def fresh(path) do
      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
      {:ok, %{head: String.trim(head), generation: 1}}
    end

    def status(_), do: %{pending_vectors: 0}
  end

  setup do
    repo = Path.join(System.tmp_dir!(), "compiled-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)

    git = fn args ->
      {out, 0} =
        System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
          cd: repo,
          stderr_to_stdout: true
        )

      String.trim(out)
    end

    git.(["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "a.txt"), "base\n")
    git.(["add", "."])
    git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base"])
    id = "compiled-test-#{System.unique_integer([:positive])}"
    {:ok, ws} = Workspace.open(repo, id)

    on_exit(fn ->
      for path <- [ws.path, ws.path <> "-compiled"],
          File.dir?(path),
          do: System.cmd("git", ["worktree", "remove", "--force", path], cd: repo)

      File.rm_rf!(repo)
    end)

    %{repo: repo, ws: ws, id: id, git: git}
  end

  test "compiling work gets a normal hooked commit before tests and review", ctx do
    File.mkdir_p!(Path.join(ctx.ws.path, "node_modules/pkg"))
    File.write!(Path.join(ctx.ws.path, "node_modules/pkg/ready"), "installed")
    File.write!(Path.join(ctx.repo, ".git/info/exclude"), "node_modules/\n")
    hook = Path.join(ctx.repo, ".git/hooks/pre-commit")
    File.write!(hook, "#!/bin/sh\ntest -f node_modules/pkg/ready\n")
    File.chmod!(hook, 0o700)
    File.write!(Path.join(ctx.ws.path, "a.txt"), "compiled but tests fail\n")
    {:ok, tree} = Workspace.tree(ctx.ws, ["a.txt"])

    {:ok, cp} =
      CompiledCheckpoint.publish(ctx.id, ctx.ws, tree, ["a.txt"], "Checkpoint bug:abcdef1", nil,
        indexer: Index
      )

    assert cp.tree == tree
    assert cp.index.head == cp.commit
    assert cp.index.pending_vectors == 0
    assert ctx.git.(["show", cp.commit <> ":a.txt"]) == "compiled but tests fail"
    assert ctx.git.(["rev-parse", "main"]) == ctx.ws.base

    assert String.trim(elem(System.cmd("git", ["rev-parse", "HEAD"], cd: ctx.ws.path), 0)) ==
             ctx.ws.base

    # Re-publishing identical code reuses the commit rather than creating duplicates.
    assert {:ok, again} =
             CompiledCheckpoint.publish(
               ctx.id,
               ctx.ws,
               tree,
               ["a.txt"],
               "Checkpoint bug:abcdef1",
               cp,
               indexer: Index
             )

    assert again.commit == cp.commit
    assert :ok = Workspace.reset(ctx.ws)
    assert ctx.git.(["show", cp.commit <> ":a.txt"]) == "compiled but tests fail"
  end

  test "compilation commands are selected only from admitted local policy" do
    assert {:ok, policy} =
             CompiledCheckpoint.policies(%{"/tmp" => %{"tests" => "compile"}}, %{
               "/tmp" => ["tests"]
             })

    assert CompiledCheckpoint.select(policy, "/tmp", "tests") == "compile"

    assert {:error, _} =
             CompiledCheckpoint.policies(%{"/tmp" => %{"other" => "compile"}}, %{
               "/tmp" => ["tests"]
             })

    assert {:error, _} =
             CompiledCheckpoint.policies(%{"/tmp" => %{"tests" => ""}}, %{"/tmp" => ["tests"]})

    assert {:ok, %{}} = CompiledCheckpoint.policies(nil, %{})
  end
end
