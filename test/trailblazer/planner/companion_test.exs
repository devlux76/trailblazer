defmodule Trailblazer.Planner.CompanionTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Loop.CaseRecord
  alias Trailblazer.Planner.Companion
  alias Trailblazer.Vortex.{Protocol, Store}

  setup do
    Trailblazer.CaseStore.transaction(fn conn ->
      Exqlite.query!(
        conn,
        "CREATE TABLE IF NOT EXISTS planner_assignment (case_id TEXT PRIMARY KEY, ref TEXT NOT NULL, state TEXT NOT NULL, deadline_at INTEGER NOT NULL, note TEXT NOT NULL)",
        [],
        timeout: :infinity
      )

      for table <- ~w(planner_assignment vortex_outbox vortex_request),
          do: Exqlite.query!(conn, "DELETE FROM #{table}", [], timeout: :infinity)
    end)

    dir = Path.join(System.tmp_dir!(), "planner-companion-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # A fake planner CLI: appends its arguments to calls.log; exits 1 while `fail` exists.
    cli = Path.join(dir, "planner")

    File.write!(cli, """
    #!/bin/sh
    [ -e #{dir}/fail ] && exit 1
    printf '%s\\n' "$*" >> #{dir}/calls.log
    """)

    File.chmod!(cli, 0o755)
    start_supervised!({Task.Supervisor, name: :planner_test_tasks})
    %{dir: dir, cli: cli}
  end

  defp repo(dir) do
    repo = Path.join(dir, "vortex")
    File.mkdir_p!(repo)
    git = fn args -> {_, 0} = System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args, cd: repo) end
    git.(["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git.(["add", "."])
    git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base"])
    {repo, git}
  end

  defp admit(repo, planner) do
    task = %{repo: repo, request: "fix bug:abcdef1", check: "test -f a.txt", files: [], design: [], from: "vortex:caller"}
    {:ok, id, :new} = Store.admit("caller", "room", "req-#{System.unique_integer([:positive])}", task, planner)
    id
  end

  defp start(ctx, extra \\ []) do
    opts = [name: nil, planner: {ctx.cli, []}, tasks: :planner_test_tasks] ++ extra
    start_supervised!(%{id: make_ref(), start: {GenServer, :start_link, [Companion, opts]}})
  end

  defp calls(dir), do: dir |> Path.join("calls.log") |> File.read() |> elem(1) |> to_string()

  defp eventually(fun, n \\ 100) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && eventually(fun, n - 1)
    end
  end

  defp row(id), do: Enum.find(Companion.list(), &(&1.case_id == id))

  test "admission stores the card with the case in the same transaction", ctx do
    {repo, _} = repo(ctx.dir)
    id = admit(repo, %{ref: "vortex:abcdef1", deadline_ms: nil})
    assert %{ref: "vortex:abcdef1", state: "open"} = row(id)
    assert [%{type: "accepted"}] = Enum.filter(Store.outbox(), &(&1.case_id == id))
  end

  test "a failed case blocks the card with its summary", ctx do
    {repo, _} = repo(ctx.dir)
    id = admit(repo, %{ref: "vortex:abcdef1", deadline_ms: nil})
    start(ctx)
    CaseRecord.close(id, %{case: id, status: :failed, summary: "check failed twice"})
    Trailblazer.Events.publish({:case, id}, %{closed: true})
    eventually(fn -> row(id).state == "block" end)
    assert calls(ctx.dir) =~ "--actor trailblazer block vortex:abcdef1"
    assert calls(ctx.dir) =~ "check failed twice"
  end

  test "a fixed candidate is verified independently in a fresh worktree, then marked done", ctx do
    {repo, git} = repo(ctx.dir)
    id = admit(repo, %{ref: "vortex:abcdef1", deadline_ms: nil})
    git.(["branch", "trailblazer/" <> id])
    {sha, 0} = System.cmd("git", ["rev-parse", "trailblazer/" <> id], cd: repo)
    start(ctx)
    CaseRecord.close(id, %{case: id, status: :fixed, commit: String.trim(sha), summary: "ok"})
    Trailblazer.Events.publish({:case, id}, %{closed: true})
    eventually(fn -> row(id).state == "done" end)
    assert calls(ctx.dir) =~ "--actor trailblazer done vortex:abcdef1 --evidence Independent verification passed (exit 0): test -f a.txt"
    assert calls(ctx.dir) =~ "not merged"
    {list, 0} = System.cmd("git", ["worktree", "list"], cd: repo)
    assert length(String.split(list, "\n", trim: true)) == 1
  end

  test "the deadline blocks an open case without retrying or cancelling it", ctx do
    {repo, _} = repo(ctx.dir)
    id = admit(repo, %{ref: "vortex:abcdef1", deadline_ms: 100})
    start(ctx)
    eventually(fn -> row(id).state == "block" end)
    assert calls(ctx.dir) =~ "No result by the deadline"
    assert CaseRecord.get(id, inline: false).status == "open"
  end

  test "a restart resumes an interrupted verification and an unsent mirror", ctx do
    {repo, git} = repo(ctx.dir)
    id = admit(repo, %{ref: "vortex:abcdef1", deadline_ms: nil})
    git.(["branch", "trailblazer/" <> id])
    {sha, 0} = System.cmd("git", ["rev-parse", "trailblazer/" <> id], cd: repo)
    CaseRecord.close(id, %{case: id, status: :fixed, commit: String.trim(sha), summary: "ok"})

    # the planner is unreachable while the first companion finishes, then it dies
    File.write!(Path.join(ctx.dir, "fail"), "")
    pid = start(ctx)
    Trailblazer.Events.publish({:case, id}, %{closed: true})
    eventually(fn -> row(id).state == "mirror_done" end)
    Process.exit(pid, :kill)
    File.rm!(Path.join(ctx.dir, "fail"))

    start(ctx)
    eventually(fn -> row(id).state == "done" end)
    assert calls(ctx.dir) =~ "done vortex:abcdef1"
  end

  test "a row left verifying by a killed companion is verified again on start", ctx do
    {repo, git} = repo(ctx.dir)
    id = admit(repo, %{ref: "vortex:abcdef1", deadline_ms: nil})
    git.(["branch", "trailblazer/" <> id])
    {sha, 0} = System.cmd("git", ["rev-parse", "trailblazer/" <> id], cd: repo)
    CaseRecord.close(id, %{case: id, status: :fixed, commit: String.trim(sha), summary: "ok"})

    Trailblazer.CaseStore.transaction(fn conn ->
      Exqlite.query!(conn, "UPDATE planner_assignment SET state = 'verifying' WHERE case_id = ?", [id],
        timeout: :infinity
      )
    end)

    start(ctx)
    eventually(fn -> row(id).state == "done" end)
  end

  test "the protocol admits only a same-repository, non-shared card" do
    policy = %{role: :collaborator, repos: %{"/tmp" => ["true"]}}

    msg = fn planner ->
      %{"type" => "task", "payload" => %{"repo" => "/tmp", "request" => "r", "check" => "true", "planner" => planner}}
    end

    assert {:ok, %{planner: %{ref: "tmp:abcdef1"}}} = Protocol.task(msg.(%{"ref" => "tmp:abcdef1"}), policy, "p")
    assert {:error, _} = Protocol.task(msg.(%{"ref" => "vortex:abcdef1"}), policy, "p")
    assert {:error, _} = Protocol.task(msg.(%{"ref" => "shared:abcdef1"}), policy, "p")
    assert {:error, _} = Protocol.task(msg.(%{"ref" => "tmp:abcdef1", "exec" => "/bin/sh"}), policy, "p")
    assert {:ok, task} = Protocol.task(Map.update!(msg.(nil), "payload", &Map.delete(&1, "planner")), policy, "p")
    refute Map.has_key?(task, :planner)
  end
end
