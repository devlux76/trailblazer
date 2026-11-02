defmodule Trailblazer.Loop.CoordinatorIntegrationTest do
  # Task 2 acceptance in disposable Git fixtures (design review, "Task 2 —
  # integration and cleanup"): a checked accepted commit reaches the admitted
  # primary; failed and unchecked cases do not; archived evidence survives
  # cleanup; cleanup errors stay visible and retryable; nothing managed is left
  # after success.
  use ExUnit.Case, async: false
  alias Trailblazer.Loop.{CaseRecord, Coordinator, Lifecycle, Workspace}

  setup do
    root = Path.join(System.tmp_dir!(), "integ-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    git(root, ["init", "-q", "-b", "main"])
    git(root, ["config", "user.name", "Test"])
    git(root, ["config", "user.email", "test@example.invalid"])
    File.write!(Path.join(root, "file.txt"), "base\n")
    File.write!(Path.join(root, "other.txt"), "other\n")
    git(root, ["add", "."])
    git(root, ["commit", "-qm", "base"])
    {:ok, root} = Trailblazer.Files.canonical_path(root)

    on_exit(fn -> File.rm_rf!(root) end)
    %{repo: root}
  end

  defp open_case(c, check \\ "true") do
    {:ok, id} = CaseRecord.open(%{repo: c.repo, request: "fix", primary: "main", check: check})
    {:ok, ws} = Workspace.open(c.repo, id)

    on_exit(fn ->
      System.cmd("git", ["worktree", "remove", "--force", ws.path],
        cd: c.repo,
        stderr_to_stdout: true
      )
    end)

    {:ok, _} =
      Lifecycle.admit(
        id,
        %{repo: c.repo, primary: "main", check: check, from: "test", files: ["file.txt"]},
        ws
      )

    {id, ws}
  end

  defp candidate(c, check \\ "true", content \\ "candidate\n") do
    {id, ws} = open_case(c, check)
    File.write!(Path.join(ws.path, "file.txt"), content)
    tree = Lifecycle.tree(ws, ["file.txt"])

    {:ok, _} =
      Lifecycle.prepare_commit(id, tree, %{status: :pass, command: "true", tree: tree})

    {:ok, sha} = Workspace.commit(ws, "repair file", ["file.txt"])
    {:ok, %{"stage" => "candidate_ready"}} = Lifecycle.reconcile(id)
    {id, ws, sha}
  end

  defp advance_main(c, file, content) do
    git(c.repo, ["checkout", "-q", "main"])
    File.write!(Path.join(c.repo, file), content)
    git(c.repo, ["commit", "-qam", "primary moves"])
    git(c.repo, ["rev-parse", "main"])
  end

  defp git(repo, args) do
    {out, 0} =
      System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
        cd: repo,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp branch?(c, branch),
    do:
      match?(
        {_, 0},
        System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/" <> branch],
          cd: c.repo
        )
      )

  defp assert_cleaned(c, ws, r) do
    refute File.exists?(ws.path)
    refute branch?(c, ws.branch)
    refute git(c.repo, ["worktree", "list"]) =~ ws.path
    assert Lifecycle.archive_intact?(r["archive"])
  end

  test "an unmoved checked-out primary fast-forwards to the candidate, then everything managed is removed",
       c do
    {id, ws, sha} = candidate(c)

    assert {:ok, r} = Coordinator.accept(id)
    assert r["stage"] == "cleanup_complete"
    assert r["result"] == sha
    assert git(c.repo, ["rev-parse", "main"]) == sha
    # the checkout was moved with its ref, not behind its back
    assert File.read!(Path.join(c.repo, "file.txt")) == "candidate\n"
    assert git(c.repo, ["status", "--porcelain"]) == ""
    assert_cleaned(c, ws, r)
    assert File.read!(Path.join(r["archive"]["path"], "changes.patch")) =~ "+candidate"

    # idempotent
    assert {:ok, %{"stage" => "cleanup_complete"}} = Coordinator.accept(id)
  end

  test "a moved primary checked out nowhere gets a tested merge result by compare-and-swap", c do
    {id, ws, sha} = candidate(c)
    moved = advance_main(c, "other.txt", "moved\n")
    git(c.repo, ["checkout", "-qb", "feature"])

    assert {:ok, r} = Coordinator.accept(id)
    result = git(c.repo, ["rev-parse", "main"])
    assert r["result"] == result
    assert git(c.repo, ["show", "-s", "--format=%P", result]) == "#{moved} #{sha}"
    assert git(c.repo, ["show", "main:file.txt"]) == "candidate"
    assert git(c.repo, ["show", "main:other.txt"]) == "moved"
    assert r["integration_check"]["sha"] == result
    assert r["integration_check"]["source"] == "merge"
    # never moves the current feature branch
    assert git(c.repo, ["branch", "--show-current"]) == "feature"
    assert_cleaned(c, ws, r)
    refute File.exists?(Path.join([Trailblazer.Config.get(:state_dir), "integration", id]))
  end

  test "a merge result that fails the trusted check is not integrated and the candidate is retained",
       c do
    {id, ws, sha} = candidate(c, "test ! -e other.txt || ! grep -q moved other.txt")
    moved = advance_main(c, "other.txt", "moved\n")

    assert {:error, {:integration_check_failed, :fail, _}} = Coordinator.accept(id)
    assert git(c.repo, ["rev-parse", "main"]) == moved
    assert git(c.repo, ["rev-parse", ws.branch]) == sha
    r = Lifecycle.get(id)
    assert r["stage"] == "candidate_ready"
    assert r["last_error"] =~ "integration_check_failed"
  end

  test "a conflicting primary returns for review with the candidate preserved", c do
    {id, ws, sha} = candidate(c)
    moved = advance_main(c, "file.txt", "conflict\n")

    assert {:error, :merge_conflict} = Coordinator.accept(id)
    assert git(c.repo, ["rev-parse", "main"]) == moved
    assert git(c.repo, ["rev-parse", ws.branch]) == sha
    assert File.exists?(ws.path)
  end

  test "a dirty checked-out primary blocks visibly and the same call succeeds once it is clean",
       c do
    {id, ws, sha} = candidate(c)
    File.write!(Path.join(c.repo, "other.txt"), "operator edit\n")

    assert {:error, :dirty_primary} = Coordinator.accept(id)
    assert Lifecycle.get(id)["last_error"] =~ "dirty_primary"
    # caller edits are never reset or stashed
    assert File.read!(Path.join(c.repo, "other.txt")) == "operator edit\n"
    assert git(c.repo, ["rev-parse", ws.branch]) == sha

    git(c.repo, ["checkout", "--", "other.txt"])
    assert {:ok, %{"stage" => "cleanup_complete"}} = Coordinator.accept(id)
    assert git(c.repo, ["rev-parse", "main"]) == sha
  end

  test "a compare-and-swap that lost to a moved primary is recomputed and retested", c do
    {id, ws, sha} = candidate(c)
    old = git(c.repo, ["rev-parse", "main"])
    {:ok, _} = Lifecycle.prepare_integration(id, old, sha, %{status: :pass, sha: sha})
    # the primary moves between the recorded intent and the CAS
    git(c.repo, ["checkout", "-qb", "feature"])
    moved = advance_main(c, "other.txt", "moved\n")
    git(c.repo, ["checkout", "-q", "feature"])

    assert {:ok, r} = Coordinator.accept(id)
    result = git(c.repo, ["rev-parse", "main"])
    assert git(c.repo, ["show", "-s", "--format=%P", result]) == "#{moved} #{sha}"
    assert Enum.any?(r["history"], &(&1["event"] == "integration_reopened"))
    assert_cleaned(c, ws, r)
  end

  test "a crash after the compare-and-swap is observed once and cleanup completes", c do
    {id, ws, sha} = candidate(c)
    old = git(c.repo, ["rev-parse", "main"])
    git(c.repo, ["checkout", "-qb", "feature"])
    {:ok, _} = Lifecycle.prepare_integration(id, old, sha, %{status: :pass, sha: sha})
    git(c.repo, ["update-ref", "refs/heads/main", sha, old])

    assert {:ok, r} = Coordinator.accept(id)
    assert r["result"] == sha
    assert Enum.count(r["history"], &(&1["event"] == "integrated")) == 1
    assert_cleaned(c, ws, r)
  end

  test "an unchecked case is refused and an unverified one is archived, then removed", c do
    {id, ws} = open_case(c)
    File.write!(Path.join(ws.path, "file.txt"), "unverified change\n")
    File.write!(Path.join(ws.path, "new.txt"), "new file\n")
    main = git(c.repo, ["rev-parse", "main"])

    assert {:error, {:not_acceptable, "opened"}} = Coordinator.accept(id)

    assert {:ok, r} = Coordinator.retire(id)
    assert r["stage"] == "discarded"
    assert git(c.repo, ["rev-parse", "main"]) == main
    patch = File.read!(Path.join(r["archive"]["path"], "changes.patch"))
    assert patch =~ "+unverified change"
    assert patch =~ "+new file"
    assert File.read!(Path.join(r["archive"]["path"], "journal.json")) =~ id
    assert_cleaned(c, ws, r)
    assert {:ok, %{"stage" => "discarded"}} = Coordinator.retire(id)
  end

  test "a failed candidate's committed work is archived from its branch after the checkout is gone",
       c do
    {id, ws, _sha} = candidate(c)
    git(c.repo, ["worktree", "remove", "--force", ws.path])

    assert {:ok, r} = Coordinator.retire(id)
    assert File.read!(Path.join(r["archive"]["path"], "changes.patch")) =~ "+candidate"
    assert git(c.repo, ["rev-parse", "main"]) != r["archive"]["branch_sha"]
    assert_cleaned(c, ws, r)
  end

  test "a damaged archive blocks removal and keeps the checkout", c do
    {id, ws} = open_case(c)
    File.write!(Path.join(ws.path, "file.txt"), "work\n")
    dir = Path.join(System.tmp_dir!(), "archive-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "changes.patch"), "x")

    archive = %{
      "path" => dir,
      "branch_sha" => git(c.repo, ["rev-parse", ws.branch]),
      "files" => %{"changes.patch" => Lifecycle.sha256("x")}
    }

    {:ok, _} = Lifecycle.prepare_discard(id, archive)
    File.write!(Path.join(dir, "changes.patch"), "tampered")

    assert {:error, :archive_missing} = Coordinator.retire(id)
    assert File.read!(Path.join(ws.path, "file.txt")) == "work\n"
    assert branch?(c, ws.branch)
  end

  test "(peer review) successful integration cannot erase unarchived untracked evidence", c do
    {id, ws, _sha} = candidate(c)
    note = Path.join(ws.path, "review-evidence.txt")
    File.write!(note, "unique untracked evidence\n")

    case Coordinator.accept(id) do
      {:ok, r} ->
        patch = File.read!(Path.join(r["archive"]["path"], "changes.patch"))
        assert patch =~ "unique untracked evidence"

      {:error, _} ->
        assert File.read!(note) == "unique untracked evidence\n"
        assert branch?(c, ws.branch)
    end
  end

  test "(peer review) integrated cleanup revalidates its archive after a crash", c do
    {id, ws, sha} = candidate(c)
    old = git(c.repo, ["rev-parse", "main"])
    git(c.repo, ["checkout", "-qb", "review-feature"])
    {:ok, _} = Lifecycle.prepare_integration(id, old, sha, %{status: :pass, sha: sha})
    git(c.repo, ["update-ref", "refs/heads/main", sha, old])
    {:ok, %{"stage" => "integrated"}} = Lifecycle.reconcile(id)
    dir = Path.join(System.tmp_dir!(), "review-archive-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    patch = Path.join(dir, "changes.patch")
    File.write!(patch, "intact")

    archive = %{
      "path" => dir,
      "branch_sha" => sha,
      "files" => %{"changes.patch" => Lifecycle.sha256("intact")}
    }

    {:ok, _} = Lifecycle.prepare_removal(id, archive)
    File.write!(patch, "tampered")
    assert {:error, _} = Coordinator.accept(id)
    assert File.exists?(ws.path)
    assert branch?(c, ws.branch)
  end

  test "(peer review) failed worktree discovery cannot move a checked-out primary", c do
    {id, _ws, _sha} = candidate(c)
    old = git(c.repo, ["rev-parse", "main"])
    dir = Path.join(System.tmp_dir!(), "review-git-bin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    wrapper = Path.join(dir, "git")

    File.write!(
      wrapper,
      "#!/bin/sh\ncase \"$*\" in *\"worktree list --porcelain\"*) exit 1;; esac\nexec /usr/bin/git \"$@\"\n"
    )

    File.chmod!(wrapper, 0o755)
    path = System.get_env("PATH")

    try do
      System.put_env("PATH", dir <> ":" <> path)
      Coordinator.accept(id)
    after
      System.put_env("PATH", path)
    end

    assert git(c.repo, ["rev-parse", "main"]) == old
    assert File.read!(Path.join(c.repo, "file.txt")) == "base\n"
  end

  test "(peer review) cleanup retry cannot erase changes made after its archive", c do
    {id, ws, sha} = candidate(c)
    old = git(c.repo, ["rev-parse", "main"])
    git(c.repo, ["checkout", "-qb", "review-recovery"])
    {:ok, _} = Lifecycle.prepare_integration(id, old, sha, %{status: :pass, sha: sha})
    git(c.repo, ["update-ref", "refs/heads/main", sha, old])
    {:ok, %{"stage" => "integrated"}} = Lifecycle.reconcile(id)

    dir =
      Path.join(System.tmp_dir!(), "review-stale-archive-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    {patch, 0} = System.cmd("git", ["diff", "--binary", old, sha], cd: c.repo)
    File.write!(Path.join(dir, "changes.patch"), patch)

    archive = %{
      "path" => dir,
      "branch_sha" => sha,
      "files" => %{"changes.patch" => Lifecycle.sha256(patch)}
    }

    {:ok, _} = Lifecycle.prepare_removal(id, archive)
    note = Path.join(ws.path, "after-archive.txt")
    File.write!(note, "new evidence after interrupted cleanup\n")

    case Coordinator.accept(id) do
      {:ok, r} ->
        saved = File.read!(Path.join(r["archive"]["path"], "changes.patch"))
        assert saved =~ "new evidence after interrupted cleanup"

      {:error, _} ->
        assert File.read!(note) == "new evidence after interrupted cleanup\n"
        assert branch?(c, ws.branch)
    end
  end

  test "(peer review) equal-patch refresh cannot overwrite the journal's current archive", c do
    {id, ws} = open_case(c)
    File.write!(Path.join(ws.path, "file.txt"), "same patch before and after commit\n")
    git(ws.path, ["add", "file.txt"])
    r = Lifecycle.get(id)
    {patch, 0} = System.cmd("git", ["diff", "--cached", "--binary", r["base"]], cd: ws.path)

    dir =
      Path.join([
        Trailblazer.Config.get(:state_dir),
        "archive",
        id,
        String.slice(Lifecycle.sha256(patch), 0, 16)
      ])

    File.mkdir_p!(dir)
    journal = Jason.encode!(r, pretty: true)
    File.write!(Path.join(dir, "journal.json"), journal)
    File.write!(Path.join(dir, "changes.patch"), patch)

    archive = %{
      "path" => dir,
      "branch_sha" => git(c.repo, ["rev-parse", ws.branch]),
      "files" => %{
        "journal.json" => Lifecycle.sha256(journal),
        "changes.patch" => Lifecycle.sha256(patch)
      }
    }

    {:ok, _} = Lifecycle.prepare_discard(id, archive)
    git(ws.path, ["commit", "-qm", "same patch, new branch SHA"])
    assert {:ok, r} = Coordinator.retire(id)
    assert Lifecycle.archive_intact?(archive)
    assert r["archive"]["path"] != dir
    assert r["archive"]["branch_sha"] != archive["branch_sha"]
    assert Lifecycle.archive_intact?(r["archive"])
  end

  test "a stale but intact archive is replaced by a journalled snapshot and the old one is kept",
       c do
    {id, ws, sha} = candidate(c)
    old = git(c.repo, ["rev-parse", "main"])
    git(c.repo, ["checkout", "-qb", "feature"])
    {:ok, _} = Lifecycle.prepare_integration(id, old, sha, %{status: :pass, sha: sha})
    git(c.repo, ["update-ref", "refs/heads/main", sha, old])
    {:ok, %{"stage" => "integrated"}} = Lifecycle.reconcile(id)
    dir = Path.join(System.tmp_dir!(), "stale-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {patch, 0} = System.cmd("git", ["diff", "--binary", old, sha], cd: c.repo)
    File.write!(Path.join(dir, "changes.patch"), patch)

    stale = %{
      "path" => dir,
      "branch_sha" => sha,
      "files" => %{"changes.patch" => Lifecycle.sha256(patch)}
    }

    {:ok, _} = Lifecycle.prepare_removal(id, stale)
    File.write!(Path.join(ws.path, "file.txt"), "edited after archive\n")

    assert {:ok, r} = Coordinator.accept(id)
    assert r["archive"]["path"] != dir
    assert File.read!(Path.join(r["archive"]["path"], "changes.patch")) =~ "+edited after archive"
    assert Enum.any?(r["history"], &(&1["event"] == "archive_refreshed"))
    assert Lifecycle.archive_intact?(stale)
    assert_cleaned(c, ws, r)
  end
end
