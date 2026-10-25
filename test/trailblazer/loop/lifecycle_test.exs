defmodule Trailblazer.Loop.LifecycleTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Loop.{CaseRecord, Lifecycle, Workspace}

  setup do
    root = Path.join(System.tmp_dir!(), "lifecycle-#{System.unique_integer([:positive])}")
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
      System.cmd("git", ["worktree", "remove", "--force", ws.path],
        cd: root,
        stderr_to_stdout: true
      )

      File.rm_rf!(root)
    end)

    {:ok, _} =
      Lifecycle.admit(
        id,
        %{repo: root, primary: "main", check: "true", from: "test", files: ["file.txt"]},
        ws
      )

    %{repo: root, ws: ws, id: id}
  end

  test "commit crash gap recovers once, preserving exact check evidence and caller edits", c do
    File.write!(Path.join(c.repo, "file.txt"), "operator edits\n")
    File.write!(Path.join(c.ws.path, "file.txt"), "candidate\n")
    tree = Lifecycle.tree(c.ws, ["file.txt"])
    evidence = %{status: :pass, exit: 0, output_tail: "proof", tree: tree, command: "true"}
    {:ok, intent} = Lifecycle.prepare_commit(c.id, tree, evidence)

    crash_after(fn ->
      {:ok, sha} = Workspace.commit(c.ws, "repair", ["file.txt"])
      sha
    end)

    {:ok, recovered} = new_worker(fn -> Lifecycle.reconcile(c.id) end)
    assert recovered["candidate"] == git(c.repo, ["rev-parse", c.ws.branch])
    assert recovered["check"]["output_tail"] == "proof"
    assert recovered["base"] == c.ws.base
    assert recovered["version"] > intent["version"]
    assert {:ok, ^recovered} = Lifecycle.reconcile(c.id)
    assert git(c.ws.path, ["rev-list", "--count", c.ws.base <> "..HEAD"]) == "1"
    assert File.read!(Path.join(c.repo, "file.txt")) == "operator edits\n"
  end

  test "integration and removal crash gaps reconcile without modifying a caller checkout", c do
    File.write!(Path.join(c.ws.path, "file.txt"), "candidate\n")
    tree = Lifecycle.tree(c.ws, ["file.txt"])
    {:ok, _} = Lifecycle.prepare_commit(c.id, tree, %{status: :pass, command: "true", tree: tree})
    {:ok, sha} = Workspace.commit(c.ws, "repair", ["file.txt"])
    {:ok, _} = Lifecycle.reconcile(c.id)
    git(c.repo, ["checkout", "-qb", "operator"])
    File.write!(Path.join(c.repo, "file.txt"), "operator edits\n")
    {:ok, _} = Lifecycle.prepare_integration(c.id, c.ws.base, sha, %{status: :pass, sha: sha})
    crash_after(fn -> git(c.repo, ["update-ref", "refs/heads/main", sha, c.ws.base]) end)
    {:ok, integrated} = new_worker(fn -> Lifecycle.reconcile(c.id) end)
    assert integrated["result"] == sha
    assert integrated["stage"] == "integrated"
    {:ok, _} = Lifecycle.prepare_removal(c.id)
    crash_after(fn -> Workspace.close(c.ws) end)
    assert {:ok, %{"cleanup" => "pending"}} = Lifecycle.reconcile(c.id)
    crash_after(fn -> git(c.repo, ["branch", "-D", c.ws.branch]) end)
    {:ok, cleaned} = new_worker(fn -> Lifecycle.reconcile(c.id) end)
    assert cleaned["cleanup"] == "complete"
    assert cleaned["result"] == sha
    assert {:ok, ^cleaned} = Lifecycle.reconcile(c.id)
    assert File.read!(Path.join(c.repo, "file.txt")) == "operator edits\n"
    assert git(c.repo, ["branch", "--show-current"]) == "operator"
  end

  test "unintegrated removal and conflicting commit intents are refused", c do
    assert {:error, :not_integrated} = Lifecycle.prepare_removal(c.id)
    tree = Lifecycle.tree(c.ws, ["file.txt"])

    assert {:ok, _} =
             Lifecycle.prepare_commit(c.id, tree, %{status: :pass, tree: tree, command: "true"})

    assert {:error, :conflicting_intent} =
             Lifecycle.prepare_commit(c.id, String.duplicate("0", 40), %{status: :pass})

    assert {:error, :conflict} = Trailblazer.CaseStore.lifecycle_cas(c.id, 0, %{})
  end

  test "candidate workspace removal recovers without claiming integration or deleting its branch",
       c do
    File.write!(Path.join(c.ws.path, "file.txt"), "candidate\n")
    tree = Lifecycle.tree(c.ws, ["file.txt"])
    {:ok, _} = Lifecycle.prepare_commit(c.id, tree, %{status: :pass, command: "true", tree: tree})
    {:ok, sha} = Workspace.commit(c.ws, "repair", ["file.txt"])
    {:ok, _} = Lifecycle.reconcile(c.id)
    {:ok, _} = Lifecycle.prepare_candidate_removal(c.id)
    crash_after(fn -> Workspace.close(c.ws) end)
    {:ok, recovered} = new_worker(fn -> Lifecycle.reconcile(c.id) end)
    assert recovered["stage"] == "candidate_ready"
    assert recovered["cleanup"] == "candidate_workspace_removed"
    assert recovered["result"] == nil
    assert git(c.repo, ["rev-parse", c.ws.branch]) == sha
    assert {:ok, ^recovered} = Lifecycle.reconcile(c.id)
  end

  test "the journal survives CaseStore restart and rejects concurrent stale writes", c do
    saved = Lifecycle.get(c.id)
    version = saved["version"]

    outcomes =
      for _ <- 1..2 do
        Task.async(fn -> Trailblazer.CaseStore.lifecycle_cas(c.id, version, saved) end)
      end
      |> Enum.map(&Task.await/1)

    assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 1
    assert Enum.count(outcomes, &(&1 == {:error, :conflict})) == 1
    expected = Lifecycle.get(c.id)
    :ok = Supervisor.terminate_child(Trailblazer.Supervisor, Trailblazer.CaseStore)
    {:ok, _} = Supervisor.restart_child(Trailblazer.Supervisor, Trailblazer.CaseStore)
    assert Lifecycle.get(c.id) == expected
  end

  test "a changed primary is a durable recovery blocker without overwriting intent", c do
    File.write!(Path.join(c.ws.path, "file.txt"), "candidate\n")
    tree = Lifecycle.tree(c.ws, ["file.txt"])
    {:ok, _} = Lifecycle.prepare_commit(c.id, tree, %{status: :pass, command: "true", tree: tree})
    {:ok, sha} = Workspace.commit(c.ws, "repair", ["file.txt"])
    {:ok, _} = Lifecycle.reconcile(c.id)
    {:ok, _} = Lifecycle.prepare_integration(c.id, c.ws.base, sha, %{status: :pass, sha: sha})
    git(c.repo, ["commit", "--allow-empty", "-qm", "operator commit"])
    assert {:error, :primary_moved} = Lifecycle.reconcile(c.id)
    journal = Lifecycle.get(c.id)
    assert journal["last_error"] == ":primary_moved"
    assert journal["intent"]["result"] == sha
    assert journal["candidate"] == sha
    assert {:error, :primary_moved} = Lifecycle.reconcile(c.id)
    assert Lifecycle.get(c.id) == journal
  end

  test "case reports expose their lifecycle after closure", c do
    :ok = CaseRecord.close(c.id, %{status: :unverified})
    assert CaseRecord.get(c.id).lifecycle == Lifecycle.get(c.id)
  end

  test "a tested result that omits the candidate cannot be recorded as integration", c do
    File.write!(Path.join(c.ws.path, "file.txt"), "candidate\n")
    tree = Lifecycle.tree(c.ws, ["file.txt"])
    {:ok, _} = Lifecycle.prepare_commit(c.id, tree, %{status: :pass, command: "true", tree: tree})
    {:ok, _} = Workspace.commit(c.ws, "repair", ["file.txt"])
    {:ok, _} = Lifecycle.reconcile(c.id)
    git(c.repo, ["commit", "--allow-empty", "-qm", "unrelated result"])
    unrelated = git(c.repo, ["rev-parse", "HEAD"])

    assert {:error, :candidate_not_in_result} =
             Lifecycle.prepare_integration(c.id, c.ws.base, unrelated, %{
               status: :pass,
               sha: unrelated
             })
  end

  test "readmission cannot replace recorded ownership", c do
    task = %{repo: c.repo, primary: "main", check: "true", from: "test", files: ["file.txt"]}
    assert {:ok, _} = Lifecycle.admit(c.id, task, c.ws)

    assert {:error, :ownership_changed} =
             Lifecycle.admit(c.id, task, %{c.ws | base: String.duplicate("0", 40)})
  end

  defp crash_after(effect) do
    owner = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result = effect.()
        send(owner, {:effect, self(), result})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:effect, ^pid, _}
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp new_worker(fun) do
    t = Task.async(fun)
    Task.await(t)
  end

  defp git(repo, args) do
    {out, 0} =
      System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
        cd: repo,
        stderr_to_stdout: true
      )

    String.trim(out)
  end
end
