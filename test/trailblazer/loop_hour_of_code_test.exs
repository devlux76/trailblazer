defmodule Trailblazer.LoopTest.HourOfCode do
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

  @correct """
  lib/greeting.ex
  ```elixir
  <<<<<<< SEARCH
    def hello(name), do: "Hello; " <> name
  =======
    def hello(name), do: "Hello, " <> name
  >>>>>>> REPLACE
  ```
  """

  @exclaim """
  lib/greeting.ex
  ```elixir
  <<<<<<< SEARCH
    def hello(name), do: "Hello, " <> name
  =======
    def hello(name), do: "Hello, " <> name <> "!"
  >>>>>>> REPLACE
  ```
  """

  defp task(repo, extra \\ %{}),
    do:
      Map.merge(
        %{repo: repo, request: "Greet with a comma", files: ["lib/greeting.ex"], check: @check},
        extra
      )

  @tag :hour_of_code
  test "hour of code expires three fresh contexts and preserves every partial", %{
    repo: repo,
    opts: opts
  } do
    timeout = fn _messages, call_opts ->
      assert is_integer(call_opts[:backstop_ms])
      assert call_opts[:backstop_ms] <= 200
      {:ok, partial} = reply("unfinished code", %{finish_reason: nil})
      call_opts[:on_partial].(partial)
      Process.sleep(call_opts[:backstop_ms] + 5)
      {:error, {:backstop, :generation_test}}
    end

    script(List.duplicate(timeout, 3))
    report = Loop.run(task(repo, %{primary: "main"}), opts ++ [generation_limit_ms: 200])
    assert report.status == :failed
    assert report.reason == :decomposition_required
    assert report.attempts == 3
    assert File.dir?(report.worktree)
    events = CaseRecord.get(report.case).events
    assert Enum.count(events, &(&1.kind == "reply" and &1.data["partial"] == true)) == 3
    checkpoints = Enum.filter(events, &(&1.data["stage"] == "attempt_checkpoint"))
    assert length(checkpoints) == 3

    for e <- checkpoints do
      assert String.trim(git(repo, ["rev-parse", e.data["ref"]])) == e.data["tree"]
    end

    for _ <- 1..3 do
      assert_received {:asked, messages, _}
      refute Enum.any?(messages, &(&1.role == "assistant"))
    end

    refute_received {:asked, _, _}
  end

  test "a text reply repeating blocks that change nothing is looping; real edits are not" do
    block = fn search, replace ->
      "a.ex\n```\n<<<<<<< SEARCH\n#{search}\n=======\n#{replace}\n>>>>>>> REPLACE\n```\n"
    end

    real = block.("x = 1", "x = 2") <> block.("y = 1", "y = 2") <> block.("z = 1", "z = 2")
    assert Loop.looping_blocks?(real) == false
    assert Loop.looping_blocks?(real <> block.("a", "a") <> block.("b", "b")) == false
    assert Loop.looping_blocks?(real <> block.("a", "a") <> block.("b", "b") <> block.("c", "c"))
  end

  @tag :hour_of_code
  test "after the configured local attempts the frontier is pinged with a written brief", %{
    repo: repo,
    opts: opts
  } do
    dir = Path.join(System.tmp_dir!(), "tb-ping-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    out = Path.join(dir, "pinged")
    ping = Path.join(dir, "ping")
    File.write!(ping, "#!/bin/sh\nprintf '%s|%s' \"$PING_FROM\" \"$1\" > #{out}\n")
    File.chmod!(ping, 0o755)
    Application.put_env(:trailblazer, :code_attempts, 2)
    Application.put_env(:trailblazer, :frontier_ping, [ping])

    on_exit(fn ->
      Application.delete_env(:trailblazer, :code_attempts)
      Application.delete_env(:trailblazer, :frontier_ping)
      File.rm_rf(dir)
    end)

    timeout = fn _messages, call_opts ->
      Process.sleep(call_opts[:backstop_ms] + 5)
      {:error, {:backstop, :generation_test}}
    end

    script(List.duplicate(timeout, 2))
    report = Loop.run(task(repo), opts ++ [generation_limit_ms: 100])
    assert report.status == :failed
    assert report.attempts == 2
    assert_received {:asked, _, _}
    assert_received {:asked, _, _}
    refute_received {:asked, _, _}

    brief = Path.join(CaseRecord.dir(report.case), "dossier.md")
    assert File.read!(brief) =~ "Check:"

    pinged =
      Enum.find_value(1..50, fn _ ->
        Process.sleep(20)
        File.exists?(out) && File.read!(out)
      end)

    assert pinged =~ "Trailblazer|Trailblazer frontier fallback: case #{report.case}"
    assert pinged =~ "Brief: #{brief}"
  end

  @tag :hour_of_code
  test "read exchanges share the same generation deadline instead of resetting it", %{
    repo: repo,
    opts: opts
  } do
    script([
      fn _, call_opts ->
        assert call_opts[:backstop_ms] <= 400
        Process.sleep(160)

        reply("", %{
          tool_calls: [%{id: "read1", name: "read", arguments: ~s({"path":"lib/greeting.ex"})}]
        })
      end,
      fn _, call_opts ->
        assert call_opts[:backstop_ms] < 250
        Process.sleep(call_opts[:backstop_ms] + 5)
        {:error, {:backstop, :generation_test}}
      end,
      reply(@fix),
      reply("PASS")
    ])

    report = Loop.run(task(repo), opts ++ [generation_limit_ms: 400])
    assert report.status == :fixed
    assert report.attempts == 2
  end

  @tag :hour_of_code
  test "verification has one budget and preserves a checked tree when review expires", %{
    repo: repo,
    opts: opts
  } do
    script([
      reply(@fix),
      fn _, call_opts ->
        assert call_opts[:backstop_ms] <= 1000
        Process.sleep(call_opts[:backstop_ms] + 5)
        {:error, {:backstop, :review_test}}
      end
    ])

    report = Loop.run(task(repo), opts ++ [verification_limit_ms: 1000])
    assert report.status == :awaiting_review
    assert report.reason == :verification_budget_exhausted
    assert report.check.status == :pass
    assert report.commit == nil
    assert File.read!(Path.join(report.worktree, "lib/greeting.ex")) =~ "Hello, "
    assert_received {:asked, _, _}
    assert_received {:asked, _, _}
    refute_received {:asked, _, _}
  end

  @tag :hour_of_code
  test "checks cannot consume a new verification allowance on each attempt", %{
    repo: repo,
    opts: opts
  } do
    script([reply(@fix), reply(@fix), reply(@fix)])
    report = Loop.run(task(repo, %{check: "sleep 2"}), opts ++ [verification_limit_ms: 100])
    assert report.status == :awaiting_review
    assert report.reason == :verification_budget_exhausted
    assert report.check.status == :timeout
    assert report.attempts == 1
  end

  defmodule StalledRead do
    def call(_, _, _, _) do
      Process.sleep(5000)
      "too late"
    end
  end

  @tag :hour_of_code
  test "a stuck read is interrupted by the same generation timer", %{repo: repo, opts: opts} do
    read =
      reply("", %{
        tool_calls: [%{id: "read1", name: "read", arguments: ~s({"path":"lib/greeting.ex"})}]
      })

    script([read, read, read])
    started = System.monotonic_time(:millisecond)
    report = Loop.run(task(repo), opts ++ [tools: StalledRead, generation_limit_ms: 100])
    assert System.monotonic_time(:millisecond) - started < 2500
    assert report.reason == :decomposition_required
    assert report.attempts == 3
  end

  @tag :hour_of_code
  test "generated code remains reachable after the next attempt continues from it", %{
    repo: repo,
    opts: opts
  } do
    wrong = String.replace(@fix, ~s("Hello, " <> name), ~s("Hello; " <> name))
    script([reply(wrong), reply(@correct), reply("PASS")])
    report = Loop.run(task(repo), opts)
    assert report.status == :fixed
    ref = "refs/trailblazer/attempts/#{report.case}/1"
    assert git(repo, ["show", ref <> ":lib/greeting.ex"]) =~ "Hello; "
    assert git(repo, ["show", report.commit <> ":lib/greeting.ex"]) =~ "Hello, "
  end

  defmodule CheckpointIndex do
    def watch(_), do: {:ok, self()}

    def fresh(path) do
      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
      {:ok, %{head: String.trim(sha), generation: 1}}
    end

    def status(_), do: %{pending_vectors: 0}
  end

  @tag :compiled_checkpoint
  test "compilation commits despite failing tests and files one bug for identical code", %{
    repo: repo,
    opts: opts
  } do
    parent = self()

    command = fn exe, args ->
      send(parent, {:failure_command, exe, args})
      {~s({"ref":"vortex:abcdef1"}), 0}
    end

    script([reply(@fix), reply(@fix), reply(@fix)])

    report =
      Loop.run(
        task(repo, %{request: "Greet with comma bug:abcdef1", compilation: "true", check: "false"}),
        Keyword.merge(opts, checkpoint_opts: [indexer: CheckpointIndex, command: command])
      )

    assert report.status == :failed
    assert report.check.status == :fail
    assert report.compiled.commit != nil
    assert git(repo, ["show", report.compiled.commit <> ":lib/greeting.ex"]) =~ "Hello, "
    assert git(repo, ["rev-parse", "main"]) |> String.trim() == report.compiled.base
    assert report.test_bugs == ["vortex:abcdef1"]
    assert_received {:failure_command, "planner", args}
    assert "add" == hd(args)
    assert Enum.any?(args, &String.contains?(&1, report.compiled.commit))
    refute_received {:failure_command, _, _}
    assert File.dir?(report.compiled.worktree)
  end

  @tag :compiled_checkpoint
  test "failed compilation cannot produce a compiling checkpoint", %{repo: repo, opts: opts} do
    script([reply(@fix), reply(@fix), reply(@fix)])

    report =
      Loop.run(
        task(repo, %{compilation: "false"}),
        Keyword.merge(opts, checkpoint_opts: [indexer: CheckpointIndex])
      )

    assert report.status == :failed
    assert report.compiled == nil

    refute Enum.any?(
             CaseRecord.get(report.case).events,
             &(&1.data["stage"] == "compiled_checkpoint")
           )
  end

  @tag :compiled_checkpoint
  test "a waiting reviewer still leaves the compiling code committed and indexed", %{
    repo: repo,
    opts: opts
  } do
    script([reply(@fix), {:error, :model_down}, {:error, :model_down}, {:error, :model_down}])

    report =
      Loop.run(
        task(repo, %{request: "Greet with comma bug:abcdef1", compilation: "true"}),
        Keyword.merge(opts, checkpoint_opts: [indexer: CheckpointIndex])
      )

    assert report.status == :awaiting_review
    assert report.commit == nil
    assert report.compiled.index.head == report.compiled.commit
    assert git(repo, ["show", report.compiled.commit <> ":lib/greeting.ex"]) =~ "Hello, "
  end

  defmodule FailTestsOnce do
    def default(_), do: "tests"
    def run(_path, "compile", _opts), do: %{status: :pass, exit: 0, output_tail: "compiled"}

    def run(_path, "tests", _opts) do
      if Process.get(:test_failed_once) do
        %{status: :pass, exit: 0, output_tail: "passed"}
      else
        Process.put(:test_failed_once, true)
        %{status: :fail, exit: 1, output_tail: "test regression"}
      end
    end
  end

  @tag :compiled_checkpoint
  test "a later passing reviewed candidate resolves its checkpoint test reports", %{
    repo: repo,
    opts: opts
  } do
    parent = self()

    command = fn exe, args ->
      send(parent, {:resolved_command, exe, args})
      {~s({"ref":"vortex:abcdef1"}), 0}
    end

    script([reply(@fix), reply(@exclaim), reply("PASS")])

    report =
      Loop.run(
        task(repo, %{
          request: "Greet with comma bug:abcdef1",
          compilation: "compile",
          check: "tests"
        }),
        Keyword.merge(opts,
          check: FailTestsOnce,
          checkpoint_opts: [indexer: CheckpointIndex, command: command]
        )
      )

    assert report.status == :fixed
    assert report.test_bugs == ["vortex:abcdef1"]
    assert_received {:resolved_command, "git", ["bug", "bug", "status", "close", "abcdef1"]}
  end
end
