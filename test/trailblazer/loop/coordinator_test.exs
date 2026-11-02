defmodule Trailblazer.Loop.CoordinatorTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Loop.{CaseRecord, Lifecycle, Workspace, Coordinator}

  setup do
    root = Path.join(System.tmp_dir!(), "coord-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    git(root, ["init", "-q", "-b", "main"])
    git(root, ["config", "user.name", "Test"])
    git(root, ["config", "user.email", "test@example.invalid"])
    File.write!(Path.join(root, "file.txt"), "base\n")
    git(root, ["add", "."])
    git(root, ["commit", "-qm", "base"])

    {:ok, id} = CaseRecord.open(%{repo: root, request: "fix", primary: "main", check: "true"})
    {:ok, ws} = Workspace.open(root, id)

    on_exit(fn ->
      try do
        System.cmd("git", ["worktree", "remove", "--force", ws.path], cd: root, stderr_to_stdout: true)
      rescue
        _ -> :ok
      end

      File.rm_rf!(root)
    end)

    %{repo: root, ws: ws, id: id}
  end

  defp admit(c, files \\ ["file.txt"]) do
    {:ok, _} =
      Lifecycle.admit(
        c.id,
        %{repo: c.repo, primary: "main", check: "true", from: "test", files: files},
        c.ws
      )

    :ok
  end

  defp make_candidate(c, content \\ "candidate\n", files \\ ["file.txt"]) do
    admit(c, files)
    File.write!(Path.join(c.ws.path, hd(files)), content)
    tree = Lifecycle.tree(c.ws, files)
    {:ok, _} = Lifecycle.prepare_commit(c.id, tree, %{status: :pass, command: "true", tree: tree})
    {:ok, sha} = Workspace.commit(c.ws, "repair", files)
    {:ok, _} = Lifecycle.reconcile(c.id)
    sha
  end

  defp git(repo, args) do
    {out, 0} =
      System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
        cd: repo,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  test "preflight accepts a candidate-ready case with a clean or absent primary checkout", c do
    sha = make_candidate(c)
    # primary checked out in repo, clean
    assert {:ok, preflight} = Coordinator.preflight(c.id)
    assert preflight["candidate"] == sha
    assert preflight["primary"] == "main"
    assert is_binary(preflight["primary_sha"])
    assert c.repo in preflight["primary_checkouts"]

    # primary checked out nowhere: move HEAD to a feature branch
    git(c.repo, ["checkout", "-qb", "feature"])
    assert {:ok, preflight2} = Coordinator.preflight(c.id)
    assert preflight2["primary_checkouts"] == []
    assert git(c.repo, ["branch", "--show-current"]) == "feature"
  end

  test "rejects missing primary branch", c do
    sha = make_candidate(c)
    # move HEAD off primary so the branch can be deleted
    git(c.repo, ["checkout", "-qb", "feature"])
    git(c.repo, ["branch", "-D", "main"])
    assert {:error, :missing_primary} = Coordinator.preflight(c.id)
    _ = sha
  end

  test "rejects nil primary", c do
    {:ok, id2} = CaseRecord.open(%{repo: c.repo, request: "fix", primary: nil, check: "true"})
    {:ok, ws2} = Workspace.open(c.repo, id2)
    on_exit(fn -> System.cmd("git", ["worktree", "remove", "--force", ws2.path], cd: c.repo, stderr_to_stdout: true) end)
    {:ok, _} = Lifecycle.admit(id2, %{repo: c.repo, primary: nil, check: "true", from: "test", files: ["file.txt"]}, ws2)
    assert {:error, :no_primary} = Coordinator.preflight(id2)
  end

  test "rejects a case without a candidate", c do
    admit(c)
    assert {:error, :no_candidate} = Coordinator.preflight(c.id)
  end

  test "rejects a candidate that has moved on its branch", c do
    make_candidate(c)
    # move branch away from candidate
    git(c.repo, ["update-ref", "refs/heads/" <> c.ws.branch, "HEAD"])
    assert {:error, :candidate_moved} = Coordinator.preflight(c.id)
  end

  test "rejects dirty or staged primary checkouts", c do
    make_candidate(c)
    # dirty tracked file in primary checkout
    File.write!(Path.join(c.repo, "file.txt"), "dirty\n")
    assert {:error, :dirty_primary} = Coordinator.preflight(c.id)
    # restore
    git(c.repo, ["checkout", "--", "file.txt"])

    # staged change
    File.write!(Path.join(c.repo, "file.txt"), "staged\n")
    git(c.repo, ["add", "file.txt"])
    assert {:error, :dirty_primary} = Coordinator.preflight(c.id)
    git(c.repo, ["reset", "-q", "HEAD"])
    git(c.repo, ["checkout", "--", "file.txt"])
  end

  test "rejects a dirty primary in another worktree", c do
    make_candidate(c)
    other = Path.join(System.tmp_dir!(), "wt-#{System.unique_integer([:positive])}")
    git(c.repo, ["worktree", "add", "--force", other, "main"])
    on_exit(fn -> System.cmd("git", ["worktree", "remove", "--force", other], cd: c.repo, stderr_to_stdout: true) end)
    File.write!(Path.join(other, "file.txt"), "dirty\n")
    assert {:error, :dirty_primary} = Coordinator.preflight(c.id)
  end

  test "distinguishes harmless from colliding untracked files", c do
    make_candidate(c, "candidate\n", ["added.txt"])

    # harmless untracked
    File.write!(Path.join(c.repo, "unrelated.txt"), "junk\n")
    assert {:ok, _} = Coordinator.preflight(c.id)
    File.rm!(Path.join(c.repo, "unrelated.txt"))

    # colliding untracked
    File.write!(Path.join(c.repo, "added.txt"), "collision\n")
    assert {:error, :colliding_untracked} = Coordinator.preflight(c.id)
    File.rm!(Path.join(c.repo, "added.txt"))
  end

  test "preserves candidate and caller edits on rejection", c do
    make_candidate(c)
    File.write!(Path.join(c.repo, "file.txt"), "operator edits\n")
    before_caller = File.read!(Path.join(c.repo, "file.txt"))
    before_candidate = git(c.repo, ["rev-parse", c.ws.branch])
    File.write!(Path.join(c.repo, "file.txt"), "dirty\n")
    assert {:error, :dirty_primary} = Coordinator.preflight(c.id)
    # caller file restored? We changed it to dirty; rejection must not modify it.
    assert File.read!(Path.join(c.repo, "file.txt")) == "dirty\n"
    assert git(c.repo, ["rev-parse", c.ws.branch]) == before_candidate
    # restore
    git(c.repo, ["checkout", "--", "file.txt"])
    assert File.read!(Path.join(c.repo, "file.txt")) == "base\n"
    _ = before_caller
  end

  test "serializes two cases for the same repo", c do
    make_candidate(c)
    {:ok, id2} = CaseRecord.open(%{repo: c.repo, request: "fix2", primary: "main", check: "true"})
    {:ok, ws2} = Workspace.open(c.repo, id2)
    on_exit(fn -> System.cmd("git", ["worktree", "remove", "--force", ws2.path], cd: c.repo, stderr_to_stdout: true) end)
    {:ok, _} = Lifecycle.admit(id2, %{repo: c.repo, primary: "main", check: "true", from: "test", files: ["file.txt"]}, ws2)
    File.write!(Path.join(ws2.path, "file.txt"), "candidate2\n")
    tree2 = Lifecycle.tree(ws2, ["file.txt"])
    {:ok, _} = Lifecycle.prepare_commit(id2, tree2, %{status: :pass, command: "true", tree: tree2})
    {:ok, _} = Workspace.commit(ws2, "repair2", ["file.txt"])
    {:ok, _} = Lifecycle.reconcile(id2)

    common = git(c.repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
    holder = Task.async(fn ->
      Coordinator.acquire_lock(common)
      receive do :release -> :ok end
      Coordinator.release_lock(common)
      :held
    end)
    Process.sleep(100)

    task = Task.async(fn -> Coordinator.preflight(id2) end)
    Process.sleep(200)
    assert Process.alive?(task.pid)
    send(holder.pid, :release)
    holder_res = Task.await(holder, 5000)
    task_res = Task.await(task, 5000)
    assert match?({:ok, _}, task_res)
  end

  test "independent repos do not serialize", c do
    # second repo
    root2 = Path.join(System.tmp_dir!(), "repo2-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root2)
    git(root2, ["init", "-q", "-b", "main"])
    git(root2, ["config", "user.name", "Test"])
    git(root2, ["config", "user.email", "test@example.invalid"])
    File.write!(Path.join(root2, "file.txt"), "base\n")
    git(root2, ["add", "."])
    git(root2, ["commit", "-qm", "base"])
    on_exit(fn -> File.rm_rf!(root2) end)

    {:ok, id2} = CaseRecord.open(%{repo: root2, request: "fix", primary: "main", check: "true"})
    {:ok, ws2} = Workspace.open(root2, id2)
    on_exit(fn -> System.cmd("git", ["worktree", "remove", "--force", ws2.path], cd: root2, stderr_to_stdout: true) end)
    {:ok, _} = Lifecycle.admit(id2, %{repo: root2, primary: "main", check: "true", from: "test", files: ["file.txt"]}, ws2)
    File.write!(Path.join(ws2.path, "file.txt"), "candidate\n")
    tree2 = Lifecycle.tree(ws2, ["file.txt"])
    {:ok, _} = Lifecycle.prepare_commit(id2, tree2, %{status: :pass, command: "true", tree: tree2})
    {:ok, _} = Workspace.commit(ws2, "repair", ["file.txt"])
    {:ok, _} = Lifecycle.reconcile(id2)

    # hold lock on first repo
    common1 = git(c.repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
    holder = Task.async(fn ->
      Coordinator.acquire_lock(common1)
      Process.sleep(300)
      Coordinator.release_lock(common1)
    end)
    Process.sleep(50)
    # accept on second repo should not wait for first repo's lock
    assert {:ok, _} = Coordinator.preflight(id2)
    Task.await(holder, 5000)
  end
end
