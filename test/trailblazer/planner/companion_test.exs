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
    [ -e #{dir}/hang ] && sleep 30
    printf '%s\\n' "$*" >> #{dir}/calls.log
    """)

    File.chmod!(cli, 0o755)
    start_supervised!({Task.Supervisor, name: :planner_test_tasks})
    %{dir: dir, cli: cli}
  end

  defp repo(dir) do
    repo = Path.join(dir, "vortex")
    File.mkdir_p!(repo)

    git = fn args ->
      {_, 0} = System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args, cd: repo)
    end

    git.(["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git.(["add", "."])
    git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base"])
    {repo, git}
  end

  defp admit(repo, planner, check \\ "test -f a.txt") do
    task = %{
      repo: repo,
      request: "fix bug:abcdef1",
      check: check,
      files: [],
      design: [],
      from: "vortex:caller"
    }

    {:ok, id, :new} =
      Store.admit("caller", "room", "req-#{System.unique_integer([:positive])}", task, planner)

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

    assert calls(ctx.dir) =~
             "--actor trailblazer done vortex:abcdef1 --evidence Independent verification passed (exit 0): test -f a.txt"

    assert calls(ctx.dir) =~ "not merged"
    {list, 0} = System.cmd("git", ["worktree", "list"], cd: repo)
    assert length(String.split(list, "\n", trim: true)) == 1
  end

  test "independent verification provisions nested dependencies and candidate-local aliases",
       ctx do
    {repo, git} = repo(ctx.dir)
    File.mkdir_p!(Path.join(repo, "packages/app"))
    File.mkdir_p!(Path.join(repo, "packages/lib"))
    File.write!(Path.join(repo, "package.json"), ~s({"workspaces":["packages/*"]}))
    File.write!(Path.join(repo, "packages/app/package.json"), "{}")
    File.write!(Path.join(repo, "packages/lib/package.json"), ~s({"name":"@demo/lib"}))
    File.write!(Path.join(repo, "packages/lib/value.txt"), "base")
    git.(["add", "."])
    git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "workspace fixture"])
    File.write!(Path.join(repo, ".git/info/exclude"), "node_modules/\n")
    File.mkdir_p!(Path.join(repo, "node_modules/external"))
    File.write!(Path.join(repo, "node_modules/external/installed"), "dependency")
    File.mkdir_p!(Path.join(repo, "node_modules/@demo"))
    File.ln_s!(Path.join(repo, "packages/lib"), Path.join(repo, "node_modules/@demo/lib"))
    File.mkdir_p!(Path.join(repo, "packages/app/node_modules"))

    File.ln_s!(
      "../../../node_modules/external",
      Path.join(repo, "packages/app/node_modules/external")
    )

    check =
      ~s|test "$(cat packages/app/node_modules/external/installed)" = dependency && test "$(cat node_modules/@demo/lib/value.txt)" = candidate|

    id = admit(repo, %{ref: "vortex:abcdef1", deadline_ms: nil}, check)
    git.(["checkout", "-qb", "trailblazer/" <> id])
    File.write!(Path.join(repo, "packages/lib/value.txt"), "candidate")
    git.(["add", "."])
    git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "candidate"])
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)
    git.(["checkout", "-q", "main"])
    start(ctx)
    CaseRecord.close(id, %{case: id, status: :fixed, commit: String.trim(sha), summary: "ok"})
    eventually(fn -> row(id).state in ["done", "block"] end)
    assert row(id).state == "done", row(id).note
    assert File.read!(Path.join(repo, "node_modules/@demo/lib/value.txt")) == "base"
    {worktrees, 0} = System.cmd("git", ["worktree", "list"], cd: repo)
    assert length(String.split(worktrees, "\n", trim: true)) == 1
  end

  test "explicit reverify retries only verification of a fixed blocked candidate", ctx do
    {repo, git} = repo(ctx.dir)
    gate = Path.join(ctx.dir, "verification-ready")
    id = admit(repo, %{ref: "vortex:abcdef1", deadline_ms: nil}, "test -f " <> gate)
    git.(["branch", "trailblazer/" <> id])
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)
    pid = start(ctx)
    CaseRecord.close(id, %{case: id, status: :fixed, commit: String.trim(sha), summary: "ok"})
    eventually(fn -> row(id).state == "block" end)
    File.write!(gate, "ready")
    assert {:ok, :verifying} = Companion.reverify(id, pid)
    assert Companion.reverify(id, pid) in [{:ok, :verifying}, {:ok, :already_verified}]
    eventually(fn -> row(id).state == "done" end)
    assert {:ok, :already_verified} = Companion.reverify(id, pid)
    assert CaseRecord.get(id).report["commit"] == String.trim(sha)

    assert Enum.count(
             String.split(calls(ctx.dir), "\n"),
             &String.contains?(&1, "done vortex:abcdef1")
           ) == 1
  end

  test "reverify refuses unknown, open and failed cases", ctx do
    {repo, _} = repo(ctx.dir)
    id = admit(repo, %{ref: "vortex:abcdef1", deadline_ms: nil})
    pid = start(ctx)
    assert {:error, :no_assignment} = Companion.reverify("missing", pid)
    assert {:error, :no_fixed_candidate} = Companion.reverify(id, pid)
    CaseRecord.close(id, %{case: id, status: :failed, summary: "failed"})
    eventually(fn -> row(id).state == "block" end)
    assert {:error, :no_fixed_candidate} = Companion.reverify(id, pid)
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
      Exqlite.query!(
        conn,
        "UPDATE planner_assignment SET state = 'verifying' WHERE case_id = ?",
        [id],
        timeout: :infinity
      )
    end)

    start(ctx)
    eventually(fn -> row(id).state == "done" end)
  end

  test "the protocol admits only a same-repository, non-shared card" do
    policy = %{role: :collaborator, repos: %{"/tmp" => ["true"]}}

    msg = fn planner ->
      %{
        "type" => "task",
        "payload" => %{
          "repo" => "/tmp",
          "request" => "r",
          "check" => "true",
          "planner" => planner
        }
      }
    end

    assert {:ok, %{planner: %{ref: "tmp:abcdef1"}}} =
             Protocol.task(msg.(%{"ref" => "tmp:abcdef1"}), policy, "p")

    assert {:error, _} = Protocol.task(msg.(%{"ref" => "vortex:abcdef1"}), policy, "p")
    assert {:error, _} = Protocol.task(msg.(%{"ref" => "shared:abcdef1"}), policy, "p")

    assert {:error, _} =
             Protocol.task(msg.(%{"ref" => "tmp:abcdef1", "exec" => "/bin/sh"}), policy, "p")

    assert {:ok, task} =
             Protocol.task(
               Map.update!(msg.(nil), "payload", &Map.delete(&1, "planner")),
               policy,
               "p"
             )

    refute Map.has_key?(task, :planner)
  end

  test "a successful mirror publishes a planner wake event", ctx do
    {repo, _} = repo(ctx.dir)
    id = admit(repo, %{ref: "vortex:abcdef1", deadline_ms: nil})
    start(ctx)
    Trailblazer.Events.subscribe(:planner)
    CaseRecord.close(id, %{case: id, status: :failed, summary: "mirrored"})
    Trailblazer.Events.publish({:case, id}, %{closed: true})
    eventually(fn -> row(id).state == "block" end)

    assert_receive {:trailblazer_event, :planner, {:mirrored, "vortex:abcdef1", "block"}}
  end

  test "a companion crash restarts its task group and kills old verification workers", ctx do
    start_supervised!(
      {Trailblazer.Planner.Supervisor,
       name: :planner_group,
       tasks: :planner_group_tasks,
       companion_name: :planner_group_companion,
       planner: {ctx.cli, []}}
    )

    old = Process.whereis(:planner_group_companion)
    parent = self()

    {:ok, worker} =
      Task.Supervisor.start_child(:planner_group_tasks, fn ->
        send(parent, :verification_started)
        Process.sleep(:infinity)
      end)

    assert_receive :verification_started
    monitor = Process.monitor(worker)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000

    eventually(fn ->
      is_pid(Process.whereis(:planner_group_companion)) and
        Process.whereis(:planner_group_companion) != old
    end)

    assert Task.Supervisor.children(:planner_group_tasks) == []
  end

  test "a hanging planner mirror is bounded so the companion remains responsive", ctx do
    {repo, _} = repo(ctx.dir)
    id = admit(repo, %{ref: "vortex:abcdef1", deadline_ms: nil})
    File.write!(Path.join(ctx.dir, "hang"), "")
    pid = start(ctx, mirror_limit_ms: 100)
    CaseRecord.close(id, %{case: id, status: :failed, summary: "bounded mirror"})
    Trailblazer.Events.publish({:case, id}, %{closed: true})
    eventually(fn -> row(id).state == "mirror_block" end)
    assert is_map(:sys.get_state(pid, 1_000))
    assert row(id).state == "mirror_block"
  end

  test "a failed verification status read cannot be marked done", ctx do
    {repo, git} = repo(ctx.dir)
    id = admit(repo, %{ref: "vortex:abcdef1", deadline_ms: nil}, "rm .git")
    git.(["branch", "trailblazer/" <> id])
    {sha, 0} = System.cmd("git", ["rev-parse", "trailblazer/" <> id], cd: repo)
    start(ctx)

    CaseRecord.close(id, %{
      case: id,
      status: :fixed,
      commit: String.trim(sha),
      summary: "test status failure"
    })

    Trailblazer.Events.publish({:case, id}, %{closed: true})
    eventually(fn -> row(id).state in ["done", "block"] end)
    assert row(id).state == "block"
    assert calls(ctx.dir) =~ "status"
  end

  test "recovery removes an interrupted verification worktree before checking again", ctx do
    {repo, git} = repo(ctx.dir)
    gate = Path.join(ctx.dir, "allow-check")
    started = Path.join(ctx.dir, "check-started")
    check = "touch #{started}; while [ ! -e #{gate} ]; do sleep 0.05; done; test -f a.txt"
    id = admit(repo, %{ref: "vortex:abcdef1", deadline_ms: nil}, check)
    git.(["branch", "trailblazer/" <> id])
    {sha, 0} = System.cmd("git", ["rev-parse", "trailblazer/" <> id], cd: repo)

    start_supervised!(
      {Trailblazer.Planner.Supervisor,
       name: :planner_group,
       tasks: :planner_group_tasks,
       companion_name: :planner_group_companion,
       planner: {ctx.cli, []}}
    )

    CaseRecord.close(id, %{
      case: id,
      status: :fixed,
      commit: String.trim(sha),
      summary: "restart during check"
    })

    Trailblazer.Events.publish({:case, id}, %{closed: true})
    eventually(fn -> File.exists?(started) end)
    Process.exit(Process.whereis(:planner_group_companion), :kill)
    File.write!(gate, "")
    eventually(fn -> row(id).state == "done" end)
    {list, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: repo)
    assert length(Regex.scan(~r/^worktree /m, list)) == 1
  end
end
