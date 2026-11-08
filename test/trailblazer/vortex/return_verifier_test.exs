defmodule Trailblazer.Vortex.ReturnVerifierTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Loop.{CaseRecord, Lifecycle, Workspace}
  alias Trailblazer.Vortex.{Bridge, Protocol, ReturnVerifier, Store}

  setup do
    Trailblazer.CaseStore.transaction(fn conn ->
      for table <- ~w(vortex_outbox vortex_request) do
        Exqlite.query!(conn, "DELETE FROM #{table}", [], timeout: :infinity)
      end
    end)

    dir = Path.join(System.tmp_dir!(), "return-verifier-#{System.unique_integer([:positive])}")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "a.txt"), "one\n")
    File.write!(Path.join(repo, "b.txt"), "two\n")
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-qm", "base"])
    on_exit(fn -> File.rm_rf!(dir) end)

    %{
      dir: dir,
      repo: repo,
      base: git(repo, ["rev-parse", "HEAD"]),
      marker: Path.join(dir, "marker")
    }
  end

  defp git(dir, args) do
    {out, 0} =
      System.cmd("git", ["-c", "core.hooksPath=/dev/null" | args],
        cd: dir,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  # A commit on top of base with the given {path, content} changes; main is
  # left checked out.
  defp commit_change(repo, base, changes) do
    git(repo, ["checkout", "-q", "--detach", base])
    for {path, content} <- changes, do: File.write!(Path.join(repo, path), content)
    git(repo, ["add", "-A"])
    git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "fix"])
    sha = git(repo, ["rev-parse", "HEAD"])
    git(repo, ["checkout", "-q", "main"])
    sha
  end

  # A case the way the bridge leaves one: opened on the repo's HEAD, closed
  # failed, handed to the frontier, claimed by it.
  defp open_case(ctx, opts) do
    files = Keyword.get(opts, :files, ["a.txt"])
    check = Keyword.get(opts, :check, "true")
    task = %{repo: ctx.repo, request: "fix", check: check, files: files, design: []}

    {:ok, id, _} =
      Store.admit("caller", "room", "req-#{System.unique_integer([:positive])}", task)

    {:ok, ws} = Workspace.open(ctx.repo, id)

    {:ok, _} =
      Lifecycle.admit(
        id,
        %{repo: ctx.repo, primary: "main", check: check, from: "vortex:caller", files: files},
        ws
      )

    on_exit(fn ->
      if File.dir?(ctx.repo),
        do: System.cmd("git", ["worktree", "remove", "--force", ws.path], cd: ctx.repo)
    end)

    :ok = CaseRecord.close(id, %{status: :failed, attempts: 3})
    :ok = Store.finish(id, {"frontier", "frontier-room"})
    :ok = Store.claim("frontier", id)
    id
  end

  defp return_fix(id, base, commit) do
    fix = %{"case" => id, "base" => base, "commit" => commit}
    :ok = Store.returned_fix("frontier", id, fix)
    fix
  end

  defp returns(id) do
    for message <- Store.outbox(),
        message.case_id == id,
        message.type == "report",
        {:ok, wire} <- [Protocol.decode(message.body)],
        Map.has_key?(wire["payload"], "returned_fix"),
        do: wire["payload"]
  end

  defp eventually(fun, n \\ 100) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && eventually(fun, n - 1)
    end
  end

  describe "gates" do
    test "a return on another base is rejected and no check runs", ctx do
      id = open_case(ctx, check: "touch #{ctx.marker}")
      commit = commit_change(ctx.repo, ctx.base, [{"a.txt", "changed\n"}])
      return_fix(id, String.duplicate("b", 40), commit)

      assert {:rejected, "returned fix is on base " <> _} = ReturnVerifier.verify(id)
      refute File.exists?(ctx.marker)
    end

    test "the case's own base is not a fix and is rejected", ctx do
      id = open_case(ctx, check: "touch #{ctx.marker}")
      return_fix(id, ctx.base, ctx.base)

      assert {:rejected, "returned commit is the case base " <> _} = ReturnVerifier.verify(id)
      refute File.exists?(ctx.marker)
    end

    test "a path outside the case's files is rejected and no check runs", ctx do
      id = open_case(ctx, check: "touch #{ctx.marker}", files: ["a.txt"])
      commit = commit_change(ctx.repo, ctx.base, [{"a.txt", "changed\n"}, {"b.txt", "x\n"}])
      return_fix(id, ctx.base, commit)

      assert {:rejected, "out of scope: b.txt"} = ReturnVerifier.verify(id)
      refute File.exists?(ctx.marker)
    end

    test "a passing check verifies the exact returned commit", ctx do
      id = open_case(ctx, check: "test -f a.txt && grep -q changed a.txt")
      commit = commit_change(ctx.repo, ctx.base, [{"a.txt", "changed\n"}])
      return_fix(id, ctx.base, commit)

      assert {:verified, summary} = ReturnVerifier.verify(id)
      assert summary =~ "Independent verification passed"
      assert summary =~ commit
    end

    test "a failing check fails the return with its evidence", ctx do
      id = open_case(ctx, check: "false")
      commit = commit_change(ctx.repo, ctx.base, [{"a.txt", "changed\n"}])
      return_fix(id, ctx.base, commit)

      assert {:failed, summary} = ReturnVerifier.verify(id)
      assert summary =~ "Independent verification failed"
    end
  end

  describe "verdict" do
    test "the verdict moves the return once and reports it to the primary", ctx do
      id = open_case(ctx, check: "test -f a.txt")
      commit = commit_change(ctx.repo, ctx.base, [{"a.txt", "changed\n"}])
      fix = return_fix(id, ctx.base, commit)

      assert :ok = Store.return_outcome(id, "verified", "passed")
      assert Store.get(id).state == "return_verified"
      assert {:error, :not_waiting} = Store.return_outcome(id, "failed", "late")
      assert {:error, :not_assigned} = Store.returned_fix("frontier", id, fix)

      assert [%{"returned_fix" => "verified", "commit" => ^commit, "summary" => "passed"}] =
               returns(id)
    end

    test "a return that is not waiting for verification takes no verdict", ctx do
      id = open_case(ctx, check: "true")
      assert {:error, :not_waiting} = Store.return_outcome(id, "verified", "too early")
      assert returns(id) == []
    end
  end

  test "a return still waiting at bridge start is verified once", ctx do
    id = open_case(ctx, check: "test -f a.txt")
    commit = commit_change(ctx.repo, ctx.base, [{"a.txt", "changed\n"}])
    return_fix(id, ctx.base, commit)
    parent = self()

    transport = fn op, args ->
      if op == "send", do: send(parent, {:sent, args})
      if op == "read", do: {:ok, %{events: [], cursor: 0}}, else: {:ok, %{"sent" => true}}
    end

    peers = %{
      "caller" => %{room: "room", role: :caller, repos: %{ctx.repo => ["true"]}},
      "frontier" => %{room: "frontier-room", role: :frontier, repos: %{}}
    }

    _bridge = start_supervised!({Bridge, name: nil, peers: peers, transport: transport})
    eventually(fn -> Store.get(id).state == "return_verified" end)
    stop_supervised!(Bridge)

    again = start_supervised!({Bridge, name: nil, peers: peers, transport: transport}, id: :again)
    assert %{} = Bridge.status(again)
    assert Store.get(id).state == "return_verified"
    assert [%{"returned_fix" => "verified"}] = returns(id)
  end
end
