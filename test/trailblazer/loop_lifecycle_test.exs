defmodule Trailblazer.LoopTest.Lifecycle do
  use ExUnit.Case, async: false

  alias Trailblazer.Loop
  alias Trailblazer.Loop.CaseRecord

  defmodule Script do
    def chat(messages, opts) do
      send(Process.get(:loop_test), {:asked, messages, opts})

      case Process.get(:script, []) do
        [next | rest] ->
          Process.put(:script, rest)
          if is_function(next), do: next.(messages, opts), else: next

        [] ->
          raise "the script ran out"
      end
    end
  end

  defmodule Boom do
    def chat(_messages, _opts), do: raise("the model client blew up")
  end

  @greeting """
  defmodule Greeting do
    def hello(name), do: "Hello " <> name
  end
  """

  setup do
    repo = Path.join(System.tmp_dir!(), "trailblazer-loop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join(repo, "lib/greeting.ex"), @greeting)
    git(repo, ["init", "-q", "-b", "main"])
    git(repo, ["add", "."])
    git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"])
    on_exit(fn -> File.rm_rf!(repo) end)
    Process.put(:loop_test, self())

    opts = [
      model: Script,
      trail: fn _repo, _request, _opts ->
        %{text: "lib/greeting.ex:1-3\n  def hello(name)", notes: []}
      end,
      gate: false,
      checkpoint_opts: [command: fn _, _ -> {~s({"ref":"fixture:abcdef1"}), 0} end]
    ]

    %{repo: repo, opts: opts}
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  defp script(replies), do: Process.put(:script, replies)

  defp reply(content, extra \\ %{}) do
    {:ok,
     Map.merge(
       %{
         content: content,
         reasoning: "thinking",
         tool_calls: [],
         usage: %{prompt_tokens: 100, completion_tokens: 10},
         ms: 5,
         finish_reason: "stop"
       },
       extra
     )}
  end

  @fix """
  Add a comma after Hello.

  lib/greeting.ex
  ```elixir
  <<<<<<< SEARCH
    def hello(name), do: "Hello " <> name
  =======
    def hello(name), do: "Hello, " <> name
  >>>>>>> REPLACE
  ```
  """

  # The same fix in text mode's tag dialect: code raw, no digest.

  @check "grep -q 'Hello, ' lib/greeting.ex"

  # A retry continues from the previous attempt's edits, so corrections are
  # made against them (not against the original file).

  defp task(repo, extra \\ %{}),
    do:
      Map.merge(
        %{repo: repo, request: "Greet with a comma", files: ["lib/greeting.ex"], check: @check},
        extra
      )

  defp submitted(blocks) do
    reply("", %{
      tool_calls: [
        %{id: "edit1", name: "submit_edits", arguments: Jason.encode!(%{blocks: blocks})}
      ]
    })
  end

  defp greeting_block do
    %{
      path: "lib/greeting.ex",
      search: ~s|  def hello(name), do: "Hello " <> name\n|,
      replace: ~s|  def hello(name), do: "Hello, " <> name\n|
    }
  end

  # Recall runs in a job of its own, so the test's pid is found globally.

  defp saved_reply(repo, overrides, close?, extra) do
    {:ok, id} = CaseRecord.open(task(repo, Map.merge(%{from: "cli"}, extra)))

    :ok =
      CaseRecord.event(id, :attempt, %{
        stage: :workspace,
        base: String.trim(git(repo, ["rev-parse", "HEAD"]))
      })

    {:ok, data} = reply("```json\n" <> Jason.encode!([greeting_block()]) <> "\n```")
    :ok = CaseRecord.event(id, :reply, Map.merge(data, %{role: :coder}) |> Map.merge(overrides))
    :ok = CaseRecord.event(id, :edit, %{status: :no_blocks})
    if close?, do: CaseRecord.close(id, %{case: id, status: :failed, summary: "format rejected"})

    on_exit(fn ->
      if CaseRecord.get(id).status == "open",
        do: CaseRecord.close(id, %{case: id, status: :failed})
    end)

    id
  end

  defp drain_asked do
    receive do
      {:asked, _, _} -> drain_asked()
    after
      0 -> :ok
    end
  end

  # E25 follow-up (Codex): the cache dies if another model takes the router.

  describe "B4" do
    test "the worktree is made while the trail is still being built", %{repo: repo, opts: opts} do
      me = self()
      {:ok, id} = CaseRecord.open(task(repo))
      :ok = Trailblazer.Events.subscribe({:case, id})

      trail = fn _repo, _request, _opts ->
        send(me, {:trail_waiting, self()})

        receive do
          :go -> %{text: "", notes: []}
        end
      end

      opts = Keyword.merge(opts, trail: trail, case_id: id)

      runner =
        Task.async(fn ->
          Process.put(:script, [reply(@fix), reply("PASS")])
          Process.put(:loop_test, me)
          Loop.run(task(repo), opts)
        end)

      assert_receive {:trail_waiting, trail_pid}
      # the workspace's event arrives while the trail is still held
      assert_receive {:trailblazer_event, {:case, ^id}, %{kind: "attempt"}}
      assert [%{data: %{"stage" => "workspace"}} | _] = CaseRecord.get(id).events
      send(trail_pid, :go)
      assert %{status: :fixed} = Task.await(runner)
    end

    test "a trail that crashes leaves the task going, with the crash recorded", %{
      repo: repo,
      opts: opts
    } do
      script([reply(@fix), reply("PASS")])
      opts = Keyword.put(opts, :trail, fn _, _, _ -> raise "trail blew up" end)
      report = Loop.run(task(repo), opts)
      assert report.status == :fixed

      assert Enum.any?(CaseRecord.get(report.case).events, fn e ->
               e.kind == "attempt" and is_binary(e.data["error"]) and
                 e.data["error"] =~ "trail blew up"
             end)
    end

    test "the head start: the check, and a test to follow when a test is asked for", %{
      repo: repo,
      opts: opts
    } do
      File.mkdir_p!(Path.join(repo, "test"))
      File.write!(Path.join(repo, "test/greeting_test.exs"), "test \"hello\" do\nend\n")
      git(repo, ["add", "."])
      git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "test"])

      script([reply(@fix), reply("PASS")])
      report = Loop.run(task(repo, %{request: "Greet with a comma and add a test"}), opts)
      assert report.status == :fixed
      assert_received {:asked, [_, %{content: user}], _}
      assert user =~ "## Check\n\nYour change must pass: `#{@check}`"
      assert user =~ "## A test to follow\n\ntest/greeting_test.exs\n"

      sizes =
        Enum.find_value(CaseRecord.get(report.case).events, fn e ->
          e.kind == "attempt" and e.data["stage"] == "prompt_size" and e.data["bytes"]
        end)

      assert sizes["system"] > 0
      assert sizes["Request"] > 0
      assert sizes["A test to follow"] > 0

      # no test asked for: no pattern; the check is still there
      drain_asked()
      script([reply(@fix), reply("PASS")])
      Loop.run(task(repo), opts)
      assert_received {:asked, [_, %{content: plain}], _}
      refute plain =~ "A test to follow"
      assert plain =~ "## Check"
    end
  end

  # A live run printed nothing until it ended; a reviewer thinking for twelve
  # minutes looked the same as one that had hung.

  test "every step is logged as it happens and every streamed token reaches stream.log", %{
    repo: repo,
    opts: opts
  } do
    streaming = fn content ->
      fn _messages, opts ->
        opts[:on_delta].(%{reasoning: "mulling it over", content: ""})
        opts[:on_delta].(%{reasoning: "", content: content})
        reply(content)
      end
    end

    script([streaming.(@fix), streaming.("PASS")])

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        send(self(), {:report, Loop.run(task(repo), opts)})
      end)

    assert_received {:report, %{status: :fixed, case: id}}

    for kind <- ~w(prompt reply edit check review report) do
      assert log =~ "case #{id} #{kind} "
    end

    assert log =~ ~s(content "Add a comma after Hello.)

    stream = File.read!(Path.join(CaseRecord.dir(id), "stream.log"))

    assert stream =~
             ~r/===== coder call.*=====\nmulling it over\n----- answer -----\nAdd a comma/s

    assert stream =~ ~r/===== reviewer call.*=====\nmulling it over\n----- answer -----\nPASS/s
  end

  # Codex's review of L7 (tmp/core/review-l7/loop_review_test.exs).

  defmodule ResetFailure do
    alias Trailblazer.Loop.Workspace
    defdelegate open(repo, id), to: Workspace
    defdelegate provision(ws, repo), to: Workspace
    defdelegate diff(ws, paths), to: Workspace
    defdelegate commit(ws, message, paths), to: Workspace
    defdelegate close(ws), to: Workspace
    def reset(_ws), do: {:error, :reset_failed}
  end

  defmodule ProvisionFailure do
    alias Trailblazer.Loop.Workspace
    defdelegate open(repo, id), to: Workspace
    def provision(_, _), do: {:error, :no_space}
  end

  defmodule CloseFailure do
    alias Trailblazer.Loop.Workspace
    defdelegate open(repo, id), to: Workspace
    defdelegate provision(ws, repo), to: Workspace
    defdelegate diff(ws, paths), to: Workspace
    defdelegate commit(ws, message, paths), to: Workspace
    def close(_ws), do: {:error, :cleanup_failed}
  end

  test "candidate cleanup failure retains its path and durable evidence", %{
    repo: repo,
    opts: opts
  } do
    script([reply(@fix), reply("PASS")])
    report = Loop.run(task(repo), Keyword.put(opts, :workspace, CloseFailure))
    assert report.status == :fixed
    assert File.dir?(report.worktree)
    journal = Trailblazer.Loop.Lifecycle.get(report.case)
    assert journal["candidate"] == report.commit
    assert journal["cleanup"] == "candidate_workspace_pending"
    assert journal["last_error"] =~ "cleanup_failed"
  end

  test "invalid lifecycle admission gives a clean failure reason", %{repo: repo, opts: opts} do
    report = Loop.run(task(repo, %{primary: "bad branch"}), opts)
    assert report.status == :failed
    assert report.summary =~ "invalid_primary"
    refute report.summary =~ "MatchError"
    assert File.dir?(report.worktree)
  end

  test "a review cut off at the length limit is not a PASS", %{repo: repo, opts: opts} do
    script([reply(@fix), reply("PASS", %{finish_reason: "length"}), reply("none"), reply("none")])
    report = Loop.run(task(repo), opts)
    # a length-cut review is not a verdict; three unusable passes park the case
    # as awaiting_review instead of failing a checked tree (operator rule)
    assert report.status == :awaiting_review
    assert report.commit == nil
  end

  test "a reset that fails stops the task before the next attempt", %{repo: repo, opts: opts} do
    wrong = String.replace(@fix, ~s("Hello, " <> name), ~s("Hello; " <> name))
    script([reply(wrong), reply("none"), reply("none")])
    report = Loop.run(task(repo), Keyword.put(opts, :workspace, ResetFailure))
    assert report.status == :failed
    assert report.summary =~ "could not be reset"
    assert_received {:asked, _, _}
    refute_received {:asked, _, _}
  end

  test "a provision that fails stops the task and names the worktree", %{repo: repo, opts: opts} do
    report = Loop.run(task(repo), Keyword.put(opts, :workspace, ProvisionFailure))
    assert report.status == :failed
    assert is_binary(report.worktree)
    assert report.summary =~ "no space"
  end

  test "a crash report names the worktree and branch that survive", %{repo: repo, opts: opts} do
    report = Loop.run(task(repo), Keyword.put(opts, :model, Boom))
    assert is_binary(report.worktree)
    assert is_binary(report.branch)
  end

  defp artifact_policy(repo, command) do
    {:ok, policies} =
      Trailblazer.Loop.Artifacts.policies(
        %{
          repo => %{
            @check => %{
              "prepare" => command,
              "paths" => ["dist/greeting.ex"],
              "definitions" => ["lib/greeting.ex"]
            }
          }
        },
        %{repo => [@check]}
      )

    policies[repo][@check]
  end

  test "generation precedes the check, is reviewed, committed and durably frozen", %{
    repo: repo,
    opts: opts
  } do
    policy = artifact_policy(repo, "mkdir -p dist && cp lib/greeting.ex dist/greeting.ex")
    script([submitted([greeting_block()]), reply("PASS")])
    report = Loop.run(task(repo, %{artifacts: policy}), opts)
    assert report.status == :fixed
    assert git(repo, ["show", "#{report.commit}:dist/greeting.ex"]) =~ "Hello, "
    assert "dist/greeting.ex" in report.files
    record = CaseRecord.get(report.case)
    assert record.task["artifacts"] == policy
    assert record.lifecycle["artifacts"] == policy
    assert Enum.any?(record.events, &(&1.kind == "attempt" and &1.data["stage"] == "artifacts"))
    assert_received {:asked, _, _}
    assert_received {:asked, [_, %{content: review}], _}
    assert review =~ "Trusted artifact preparation"
    assert review =~ "definitions_changed"
    assert review =~ "lib/greeting.ex"
  end

  test "a preparation scope violation stops without another coder or reviewer call", %{
    repo: repo,
    opts: opts
  } do
    policy = artifact_policy(repo, "printf bad > rogue.txt; exit 1")
    script([submitted([greeting_block()])])
    report = Loop.run(task(repo, %{artifacts: policy}), opts)
    assert report.status == :failed
    assert report.summary =~ "outside_outputs"
    assert_received {:asked, _, _}
    refute_received {:asked, _, _}
    refute Enum.any?(CaseRecord.get(report.case).events, &(&1.kind == "check"))
  end

  test "ordinary build failure gets bounded feedback and a reset", %{repo: repo, opts: opts} do
    policy = artifact_policy(repo, "false")

    again = %{
      path: "lib/greeting.ex",
      search: ~s|  def hello(name), do: "Hello, " <> name\n|,
      replace: ~s|  def hello(name), do: "Hello, " <> name\n|
    }

    script([submitted([greeting_block()]), submitted([again]), submitted([again])])
    report = Loop.run(task(repo, %{artifacts: policy}), opts)
    assert report.status == :failed
    assert report.attempts == 3
    assert_received {:asked, _, _}
    assert_received {:asked, [_, %{content: feedback}], _}
    assert feedback =~ "Artifact preparation"
    refute Enum.any?(CaseRecord.get(report.case).events, &(&1.kind == "check"))
  end

  test "replay prepares outputs without coding and refuses a changed frozen policy", %{
    repo: repo,
    opts: opts
  } do
    policy = artifact_policy(repo, "mkdir -p dist && cp lib/greeting.ex dist/greeting.ex")
    source = saved_reply(repo, %{}, true, %{artifacts: policy})
    script([reply("PASS")])
    report = Loop.run(task(repo, %{replay_reply_from: source, artifacts: policy}), opts)
    assert report.status == :fixed
    assert report.cost.model_calls == 1
    assert git(repo, ["show", "#{report.commit}:dist/greeting.ex"]) =~ "Hello, "
    script([reply("PASS")])
    changed = artifact_policy(repo, "mkdir -p dist && printf different > dist/greeting.ex")
    report = Loop.run(task(repo, %{replay_reply_from: source, artifacts: changed}), opts)
    assert report.status == :failed
    assert report.cost.model_calls == 0
  end

  test "deleted declared outputs are explicitly highlighted for the reviewer", %{
    repo: repo,
    opts: opts
  } do
    File.mkdir_p!(Path.join(repo, "dist"))
    File.write!(Path.join(repo, "dist/greeting.ex"), "obsolete")
    git(repo, ["add", "."])
    git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "bundle"])
    policy = artifact_policy(repo, "rm -f dist/greeting.ex")
    script([submitted([greeting_block()]), reply("PASS")])
    report = Loop.run(task(repo, %{artifacts: policy}), opts)
    assert report.status == :fixed
    assert_received {:asked, _, _}
    assert_received {:asked, [_, %{content: review}], _}
    assert review =~ ~s("deleted_paths":["dist/greeting.ex"])

    assert git(repo, ["diff-tree", "--no-commit-id", "--name-status", "-r", report.commit]) =~
             "D\tdist/greeting.ex"
  end

  test "artifact policy also rebuilds fast-forward integrations before ref advancement", %{
    repo: repo,
    opts: opts
  } do
    policy = artifact_policy(repo, "mkdir -p dist && cp lib/greeting.ex dist/greeting.ex")
    script([submitted([greeting_block()]), reply("PASS")])
    report = Loop.run(task(repo, %{artifacts: policy, primary: "main"}), opts)
    assert report.status == :fixed
    assert report.integration.result == report.commit
    assert git(repo, ["show", "main:dist/greeting.ex"]) =~ "Hello, "
  end
end
