defmodule Trailblazer.Loop.PermissionCheckpointTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias Trailblazer.Loop.{CaseRecord, Permission, PermissionCheckpoint, Workspace}

  setup do
    root = Path.join(System.tmp_dir!(), "permission-files-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo with space")
    File.mkdir_p!(repo)

    for args <- [
          ["init", "-q"],
          ["config", "user.name", "Test"],
          ["config", "user.email", "test@example.invalid"]
        ] do
      {_, 0} = System.cmd("git", args, cd: repo)
    end

    File.write!(Path.join(repo, "tracked"), "base\n")
    File.write!(Path.join(repo, ".gitignore"), "ignored\n")

    for args <- [["add", "."], ["commit", "-qm", "base"]] do
      {_, 0} = System.cmd("git", args, cd: repo)
    end

    {:ok, id} = CaseRecord.open(%{repo: repo, from: "test", request: "preserve"})
    {:ok, ws} = Workspace.open(repo, id)
    File.mkdir_p!(CaseRecord.dir(id))

    on_exit(fn ->
      if File.dir?(ws.path), do: Workspace.close(ws)
      File.rm_rf!(CaseRecord.dir(id))
      File.rm_rf!(root)
    end)

    %{root: root, repo: repo, case_id: id, ws: ws}
  end

  test "round trip retains edited, ignored, binary, modes and partial output without touching source",
       c do
    File.write!(Path.join(c.ws.path, "tracked"), "incomplete edit\n")
    File.write!(Path.join(c.ws.path, "ignored"), <<0, 255, 17>>)
    File.mkdir_p!(Path.join(c.ws.path, "empty"))
    File.chmod!(Path.join(c.ws.path, "empty"), 0o770)
    File.chmod!(Path.join(c.ws.path, "tracked"), 0o640)
    File.write!(Path.join(CaseRecord.dir(c.case_id), "reply.partial"), <<"still thinking", 255>>)
    :ok = CaseRecord.event(c.case_id, :reply, %{text: String.duplicate("partial ", 1000)})
    payload = %{"stage" => "artifact_observed", "evidence" => String.duplicate("detail", 2000)}

    assert {:ok, ref} = PermissionCheckpoint.capture(c.case_id, c.ws, payload)
    assert byte_size(Jason.encode!(ref)) < 200
    assert {:ok, saved} = PermissionCheckpoint.verify(c.case_id, ref)
    assert saved["payload"] == payload
    assert saved["journal"]["events"] |> hd() |> Map.get("kind") == "reply"
    destination = Path.join(c.root, "restored")
    assert {:ok, ^saved} = PermissionCheckpoint.restore(c.case_id, ref, destination)
    assert File.read!(Path.join(destination, "worktree/tracked")) == "incomplete edit\n"
    assert File.read!(Path.join(destination, "worktree/ignored")) == <<0, 255, 17>>
    assert (File.stat!(Path.join(destination, "worktree/tracked")).mode &&& 0o7777) == 0o640
    assert (File.stat!(Path.join(destination, "worktree/empty")).mode &&& 0o7777) == 0o770
    assert File.read!(Path.join(destination, "case/reply.partial")) == <<"still thinking", 255>>
    refute File.exists?(Path.join(destination, "worktree/.git"))
    assert File.read!(Path.join(c.ws.path, "tracked")) == "incomplete edit\n"
    assert CaseRecord.get(c.case_id).status == "open"

    assert {:error, :destination_exists} =
             PermissionCheckpoint.restore(c.case_id, ref, destination)
  end

  test "symlinks are preserved as links, never traversed", c do
    outside = Path.join(c.root, "outside")
    File.write!(outside, "do not copy or alter")
    File.ln_s!(outside, Path.join(c.ws.path, "external"))
    assert {:ok, ref} = PermissionCheckpoint.capture(c.case_id, c.ws, %{})
    destination = Path.join(c.root, "restored")
    assert {:ok, _} = PermissionCheckpoint.restore(c.case_id, ref, destination)
    assert File.read_link!(Path.join(destination, "worktree/external")) == outside
    assert File.read!(outside) == "do not copy or alter"
  end

  test "corrupt saved bytes refuse verification before any restoration", c do
    File.write!(Path.join(c.ws.path, "untracked"), "unique bytes")
    assert {:ok, ref} = PermissionCheckpoint.capture(c.case_id, c.ws, %{})
    hash = :crypto.hash(:sha256, "unique bytes") |> Base.encode16(case: :lower)

    blob =
      Path.join([
        CaseRecord.dir(c.case_id),
        "permission-checkpoints",
        ref["sha256"],
        "blobs",
        hash
      ])

    File.write!(blob, "damaged")
    assert {:error, :invalid_checkpoint} = PermissionCheckpoint.verify(c.case_id, ref)
    destination = Path.join(c.root, "restored")

    assert {:error, :invalid_checkpoint} =
             PermissionCheckpoint.restore(c.case_id, ref, destination)

    refute File.exists?(destination)
    assert File.read!(Path.join(c.ws.path, "untracked")) == "unique bytes"
  end

  test "manifest tampering, forged references and symlink destinations are refused", c do
    assert {:ok, ref} = PermissionCheckpoint.capture(c.case_id, c.ws, %{})

    assert {:error, :invalid_checkpoint} =
             PermissionCheckpoint.verify(c.case_id, %{"sha256" => "../escape"})

    outside = Path.join(c.root, "outside")
    File.mkdir!(outside)
    File.ln_s!(outside, Path.join(c.root, "linked"))

    assert {:error, :unsafe_path} =
             PermissionCheckpoint.restore(c.case_id, ref, Path.join(c.root, "linked/new"))

    refute File.exists?(Path.join(outside, "new"))

    manifest =
      Path.join([
        CaseRecord.dir(c.case_id),
        "permission-checkpoints",
        ref["sha256"],
        "manifest.json"
      ])

    File.write!(manifest, "{}")
    assert {:error, :invalid_checkpoint} = PermissionCheckpoint.verify(c.case_id, ref)
  end

  test "special files and foreign workspaces refuse preservation and retain the originals", c do
    assert {:error, :workspace_mismatch} =
             PermissionCheckpoint.capture(c.case_id, %{c.ws | path: c.repo}, %{})

    fifo = Path.join(c.ws.path, "pipe")
    {_, 0} = System.cmd("mkfifo", [fifo])
    assert {:error, :unsupported_file} = PermissionCheckpoint.capture(c.case_id, c.ws, %{})
    assert File.lstat!(fifo).type == :other
    assert CaseRecord.get(c.case_id).status == "open"
  end

  test "a claimed base must be the actual owned checkout HEAD", c do
    assert {:error, :workspace_mismatch} =
             PermissionCheckpoint.capture(
               c.case_id,
               %{c.ws | base: String.duplicate("f", 40)},
               %{}
             )
  end

  test "changes during capture issue no usable reference and never discard the new work", c do
    assert {:error, :source_changed} =
             PermissionCheckpoint.capture(c.case_id, c.ws, %{},
               after_capture: fn -> File.write!(Path.join(c.ws.path, "tracked"), "new work\n") end
             )

    assert File.read!(Path.join(c.ws.path, "tracked")) == "new work\n"

    assert {:error, :source_changed} =
             PermissionCheckpoint.capture(c.case_id, c.ws, %{},
               after_capture: fn ->
                 CaseRecord.event(c.case_id, :reply, %{text: "late partial"})
               end
             )

    assert CaseRecord.get(c.case_id).status == "open"
  end

  test "a digest alone does not permit malformed or incomplete manifest entries", c do
    {:ok, ref} = PermissionCheckpoint.capture(c.case_id, c.ws, %{})
    {:ok, saved} = PermissionCheckpoint.verify(c.case_id, ref)
    original = Path.join([CaseRecord.dir(c.case_id), "permission-checkpoints", ref["sha256"]])

    for entries <- [
          [123],
          [],
          [%{"area" => "worktree", "path" => "../escape", "type" => "directory", "mode" => 0o700}]
        ] do
      bytes = Jason.encode!(put_in(saved["manifest"]["entries"], entries)["manifest"])
      sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      altered = Path.join([CaseRecord.dir(c.case_id), "permission-checkpoints", sha])
      File.cp_r!(original, altered)
      File.write!(Path.join(altered, "manifest.json"), bytes)

      assert {:error, :invalid_checkpoint} =
               PermissionCheckpoint.verify(c.case_id, %{"version" => 1, "sha256" => sha})
    end
  end

  test "request expiry preserves a snapshot restorable after explicit checkout retirement", c do
    File.write!(Path.join(c.ws.path, "unfinished"), <<"partial", 0, 255>>)
    {:ok, ref} = PermissionCheckpoint.capture(c.case_id, c.ws, %{"stage" => "artifact_observed"})

    evidence = %{
      "base" => c.ws.base,
      "policy_hash" => String.duplicate("a", 64),
      "source_hash" => String.duplicate("b", 64),
      "exception_hash" => String.duplicate("c", 64),
      "exceptions" => [%{"id" => "directory-mode"}]
    }

    checkpoint = %{"repo" => c.repo, "base" => c.ws.base, "snapshot" => ref}

    {:ok, request} =
      Permission.open(c.case_id, "artifact_scope", evidence, checkpoint,
        frontiers: ["frontier"],
        now_ms: 1,
        timeout_ms: 10
      )

    assert {:ok, %{"state" => "expired"}} = Permission.expire(request, 11)
    assert File.read!(Path.join(c.ws.path, "unfinished")) == <<"partial", 0, 255>>
    # Fixture simulates separately authorized maintenance, not request expiry.
    assert :ok = Workspace.close(c.ws)
    assert {:ok, _} = PermissionCheckpoint.restore(c.case_id, ref, Path.join(c.root, "restored"))
    assert File.read!(Path.join(c.root, "restored/worktree/unfinished")) == <<"partial", 0, 255>>
    assert CaseRecord.get(c.case_id).status == "open"
    assert Permission.get(request)["checkpoint"]["snapshot"] == ref
  end

  test "index mutation during capture is detected without changing source content", c do
    assert {:error, :source_changed} =
             PermissionCheckpoint.capture(c.case_id, c.ws, %{},
               after_capture: fn ->
                 File.write!(Path.join(c.ws.path, "staged"), "retain this too")
                 {_, 0} = System.cmd("git", ["add", "staged"], cd: c.ws.path)
                 File.rm!(Path.join(c.ws.path, "staged"))
               end
             )

    {index, 0} = System.cmd("git", ["show", ":staged"], cd: c.ws.path)
    assert index == "retain this too"
  end

  test "a duplicate verified capture leaves no redundant staging copy", c do
    {:ok, ref} = PermissionCheckpoint.capture(c.case_id, c.ws, %{})
    assert {:ok, ^ref} = PermissionCheckpoint.capture(c.case_id, c.ws, %{})

    assert File.ls!(Path.join(CaseRecord.dir(c.case_id), "permission-checkpoints")) == [
             ref["sha256"]
           ]

    assert {:ok, _} = PermissionCheckpoint.verify(c.case_id, ref)
  end
end
