defmodule Trailblazer.LoopTest do
  use ExUnit.Case, async: false

  alias Trailblazer.Loop
  alias Trailblazer.Loop.CaseRecord

  # A model that answers from a script, one reply per call, and remembers
  # what it was asked.
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

  @check "grep -q 'Hello, ' lib/greeting.ex"

  defp task(repo, extra \\ %{}),
    do:
      Map.merge(
        %{repo: repo, request: "Greet with a comma", files: ["lib/greeting.ex"], check: @check},
        extra
      )

  defmodule MutatingCheck do
    def run(path, _command, _opts) do
      File.write!(Path.join(path, "lib/greeting.ex"), "unchecked mutation\n")
      %{status: :pass, exit: 0, output_tail: "pass"}
    end
  end

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

  test "a complete fenced JSON edit array uses the same check review and commit path", %{
    repo: repo,
    opts: opts
  } do
    text = "```json\n" <> Jason.encode!([greeting_block()]) <> "\n```"
    script([reply(text), reply("## PASS")])
    report = Loop.run(task(repo), opts)
    assert report.status == :fixed
    assert git(repo, ["show", "#{report.commit}:lib/greeting.ex"]) =~ "Hello, "
  end

  test "an admitted primary hands a fixed candidate to the coordinator, which integrates and cleans up",
       %{repo: repo, opts: opts} do
    text = "```json\n" <> Jason.encode!([greeting_block()]) <> "\n```"
    script([reply(text), reply("## PASS")])
    report = Loop.run(task(repo, %{primary: "main"}), opts)
    assert report.status == :fixed
    assert report.integration.result == report.commit
    assert String.trim(git(repo, ["rev-parse", "main"])) == report.commit
    assert report.worktree == nil
    assert report.summary =~ "Integrated into main"

    {_, 1} =
      System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/" <> report.branch],
        cd: repo
      )

    assert Trailblazer.Loop.Lifecycle.get(report.case)["stage"] == "cleanup_complete"
  end

  test "without an admitted primary a fixed candidate's branch is retained for the caller", %{
    repo: repo,
    opts: opts
  } do
    text = "```json\n" <> Jason.encode!([greeting_block()]) <> "\n```"
    script([reply(text), reply("## PASS")])
    main = String.trim(git(repo, ["rev-parse", "main"]))
    report = Loop.run(task(repo), opts)
    assert report.status == :fixed
    refute Map.has_key?(report, :integration)
    assert String.trim(git(repo, ["rev-parse", "main"])) == main
    assert String.trim(git(repo, ["rev-parse", report.branch])) == report.commit
  end

  defp saved_reply(repo, overrides \\ %{}, close? \\ true, extra \\ %{}) do
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

  test "saved reply recovery performs no coding inference and records immutable provenance", %{
    repo: repo,
    opts: opts
  } do
    source = saved_reply(repo)
    script([reply("PASS")])
    report = Loop.run(task(repo, %{replay_reply_from: source}), opts)
    assert report.status == :fixed
    assert report.cost.model_calls == 1
    assert report.cost.completion_tokens == 10
    assert CaseRecord.get(source).status == "failed"
    assert Enum.any?(CaseRecord.get(report.case).events, &(&1.data["replayed_from"] == source))
    assert git(repo, ["show", "#{report.commit}:lib/greeting.ex"]) =~ "Hello, "
  end

  test "recovery refuses partial replies and different base peer or check without model calls", %{
    repo: repo,
    opts: opts
  } do
    source = saved_reply(repo)
    partial = saved_reply(repo, %{finish_reason: "length"})
    open = saved_reply(repo, %{}, false)

    for extra <- [
          %{replay_reply_from: partial},
          %{replay_reply_from: open},
          %{replay_reply_from: "missing"},
          %{replay_reply_from: source, from: "other-peer"},
          %{replay_reply_from: source, check: "false"}
        ] do
      report = Loop.run(task(repo, extra), opts)
      assert report.status == :failed
      assert report.cost.model_calls == 0
      assert report.files == []
    end

    other = repo <> "-other"
    {_, 0} = System.cmd("git", ["clone", "-q", repo, other])
    on_exit(fn -> File.rm_rf!(other) end)
    report = Loop.run(task(other, %{replay_reply_from: source}), opts)
    assert report.status == :failed
    assert report.cost.model_calls == 0
    File.write!(Path.join(repo, "new.txt"), "new base")
    git(repo, ["add", "."])
    git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "new base"])
    report = Loop.run(task(repo, %{replay_reply_from: source}), opts)
    assert report.status == :failed
    assert report.cost.model_calls == 0
    refute_received {:asked, _, _}
  end

  test "a failed recovery review preserves the applied artifact and never regenerates code", %{
    repo: repo,
    opts: opts
  } do
    source = saved_reply(repo)
    script([reply("FAIL: preserve evidence")])
    report = Loop.run(task(repo, %{replay_reply_from: source}), opts)
    assert report.status == :failed
    assert report.attempts == 1
    assert report.cost.model_calls == 1
    assert File.read!(Path.join(report.worktree, "lib/greeting.ex")) =~ "Hello, "
  end

  test "native edit submission follows the same check review and candidate path", %{
    repo: repo,
    opts: opts
  } do
    script([submitted([greeting_block()]), reply("PASS")])
    report = Loop.run(task(repo), opts)
    assert report.status == :fixed
    assert report.attempts == 1
    assert git(repo, ["show", "#{report.commit}:lib/greeting.ex"]) =~ "Hello, "
    assert File.read!(Path.join(repo, "lib/greeting.ex")) == @greeting
  end

  test "reading budget ends with a forced native edit tool, never removes the edit interface", %{
    repo: repo,
    opts: opts
  } do
    read =
      reply("", %{
        tool_calls: [%{id: "read1", name: "read", arguments: ~s({"path":"lib/greeting.ex"})}]
      })

    final = fn _messages, options ->
      assert Enum.map(options[:tools], & &1.function.name) ==
               ~w(submit_edits)

      assert options[:tool_choice] == "required"
      submitted([greeting_block()])
    end

    script(List.duplicate(read, 6) ++ [final, reply("PASS")])
    assert Loop.run(task(repo), opts).status == :fixed
  end

  test "zero read rounds forces native edits on the first call, including persisted string keys",
       %{
         repo: repo,
         opts: opts
       } do
    first = fn _messages, options ->
      assert Enum.map(options[:tools], & &1.function.name) ==
               ~w(submit_edits)

      assert options[:tool_choice] == "required"
      assert options[:reasoning_budget_tokens] == 1024
      submitted([greeting_block()])
    end

    script([first, reply("PASS")])

    persisted =
      task(repo, %{read_rounds: 0, reasoning_budget_tokens: 1024})
      |> Jason.encode!()
      |> Jason.decode!()

    report = Loop.run(persisted, opts)
    assert report.status == :fixed
    assert report.cost.model_calls == 2
    assert git(repo, ["show", "#{report.commit}:lib/greeting.ex"]) =~ "Hello, "
  end

  test "one read round allows one exchange then forces edits", %{repo: repo, opts: opts} do
    first = fn _messages, options ->
      assert Enum.any?(options[:tools], &(&1.function.name == "read"))
      refute options[:tool_choice]

      reply("", %{
        tool_calls: [%{id: "r", name: "read", arguments: ~s({"path":"lib/greeting.ex"})}]
      })
    end

    second = fn _messages, options ->
      assert Enum.map(options[:tools], & &1.function.name) ==
               ~w(submit_edits)

      assert options[:tool_choice] == "required"
      submitted([greeting_block()])
    end

    script([first, second, reply("PASS")])
    assert Loop.run(task(repo, %{read_rounds: 1}), opts).status == :fixed
  end

  test "invalid read budgets fail before any model call", %{repo: repo, opts: opts} do
    for invalid <- [-1, 7, true, false, nil, "0", 0.5] do
      assert_raise ArgumentError, ~r/read_rounds/, fn ->
        Loop.run(task(repo, %{read_rounds: invalid}), opts)
      end
    end

    refute_received {:asked, _, _}
  end

  test "output exhaustion stops after one call without applying edits or retrying", %{
    repo: repo,
    opts: opts
  } do
    script([{:error, :output_limit}])
    report = Loop.run(task(repo), opts)
    assert report.status == :failed
    assert report.summary =~ "output budget"
    assert report.cost.model_calls == 1
    assert report.commit == nil
    assert report.files == []
  end

  test "a mixed read and edit batch is rejected without applying any edit", %{
    repo: repo,
    opts: opts
  } do
    {:ok, submission} = submitted([greeting_block()])
    read = %{id: "read1", name: "read", arguments: ~s({"path":"lib/greeting.ex"})}
    invalid = reply("", %{tool_calls: submission.tool_calls ++ [read]})
    script(List.duplicate(invalid, 3))
    report = Loop.run(task(repo), opts)
    assert report.status == :failed
    assert report.files == []
    assert File.read!(Path.join(report.worktree, "lib/greeting.ex")) == @greeting
  end

  test "a check or review cannot change the checked candidate tree", %{repo: repo, opts: opts} do
    script([reply(@fix), reply("PASS")])
    report = Loop.run(task(repo), Keyword.put(opts, :check, MutatingCheck))
    assert report.status == :failed
    assert report.commit == nil
    assert report.summary =~ "changed after"
    assert File.dir?(report.worktree)
  end

  test "a task whose edit, check and review pass is committed on its own branch", %{
    repo: repo,
    opts: opts
  } do
    call = %{id: "c1", name: "where", arguments: ~s({"name": "hello"})}
    script([reply("", %{tool_calls: [call]}), reply(@fix), reply("PASS")])

    report = Loop.run(task(repo), opts)

    assert report.status == :fixed
    assert report.attempts == 1
    assert report.files == ["lib/greeting.ex"]
    assert report.check == %{status: :pass}
    assert report.branch == "trailblazer/#{report.case}"
    assert report.cost.model_calls == 3
    assert report.cost.prompt_tokens == 300
    assert is_binary(report.commit)
    assert report.worktree == nil
    assert String.trim(git(repo, ["rev-parse", report.branch])) == report.commit
    journal = Trailblazer.Loop.Lifecycle.get(report.case)
    assert journal["stage"] == "candidate_ready"
    assert journal["candidate"] == report.commit
    assert journal["check"]["command"] == @check
    assert journal["result"] == nil
    assert journal["cleanup"] == "candidate_workspace_removed"

    # committed on the branch, the caller's checkout untouched
    assert git(repo, ["show", "#{report.branch}:lib/greeting.ex"]) =~ "Hello, "
    assert File.read!(Path.join(repo, "lib/greeting.ex")) == @greeting
    assert git(repo, ["rev-parse", "--abbrev-ref", "HEAD"]) == "main\n"

    # the request's first line is the whole message (trailblazer:6cccd98)
    assert git(repo, ["log", "-1", "--format=%B", report.branch]) |> String.trim() ==
             "Greet with a comma"

    # the tool call was answered and its answer sent back
    assert_received {:asked, _first, first_opts}
    assert first_opts[:tools] != nil
    assert_received {:asked, second, _}
    assert Enum.any?(second, &(&1[:role] == "tool" and &1[:tool_call_id] == "c1"))
    assert Enum.any?(second, &(&1[:role] == "assistant" and &1[:tool_calls] != nil))

    # the reviewer saw the diff, in a context of its own, with no tools
    assert_received {:asked, [%{role: "system", content: review_system}, %{content: review_user}],
                     review_opts}

    assert review_system =~ "PASS"
    assert review_user =~ "+  def hello(name), do: \"Hello, \" <> name"
    assert review_opts[:tools] == nil

    # the case is whole and in order
    record = CaseRecord.get(report.case)
    assert record.status == "fixed"
    kinds = Enum.map(record.events, & &1.kind)

    assert Enum.reject(kinds, &(&1 == "attempt")) ==
             ~w(prompt reply tool_call prompt reply edit check prompt reply review report)
  end

  test "a block that misses comes back with the closest lines, and the next attempt fixes it", %{
    repo: repo,
    opts: opts
  } do
    miss = String.replace(@fix, ~s("Hello " <> name), ~s("Hi " <> name), global: false)
    script([reply(miss), reply(@fix), reply("PASS")])

    report = Loop.run(task(repo), opts)
    assert report.status == :fixed
    assert report.attempts == 2

    assert_received {:asked, _, _}
    assert_received {:asked, [_, %{content: second_user}], _}
    assert second_user =~ "## The last attempt failed"
    assert second_user =~ "failed to match"
    assert second_user =~ ~s|def hello(name), do: "Hello " <> name|
  end

  test "a failed check is fed back with its output, and the worktree is reset between attempts",
       %{repo: repo, opts: opts} do
    wrong = String.replace(@fix, ~s("Hello, " <> name), ~s("Hello; " <> name))
    script([reply(wrong), reply(@fix), reply("PASS")])

    report =
      Loop.run(
        task(repo, %{check: "echo the greeting has no comma; grep -q 'Hello, ' lib/greeting.ex"}),
        opts
      )

    assert report.status == :fixed
    assert report.attempts == 2

    assert_received {:asked, _, _}
    assert_received {:asked, [_, %{content: second_user}], _}
    assert second_user =~ "the greeting has no comma"
    assert second_user =~ "Previous submitted edit blocks"
    assert second_user =~ "Hello; "
    # the second attempt's SEARCH matched, so the first attempt's edit was undone
    assert git(repo, ["show", "#{report.branch}:lib/greeting.ex"]) =~ ~s("Hello, ")
  end

  test "a retry explains the reset and recreates a test discarded with the failed edit",
       %{repo: repo, opts: opts} do
    new_test = """

    test/greeting.txt
    ```
    <<<<<<< SEARCH
    =======
    Hello, Ada
    >>>>>>> REPLACE
    ```
    """

    wrong = String.replace(@fix, ~s("Hello, " <> name), ~s("Hello; " <> name))

    script([
      reply(wrong <> new_test),
      fn [_, %{content: user}], _ ->
        assert user =~ "previous edits remain in the attempt checkpoint"
        assert user =~ "original files"
        assert user =~ "Previous submitted edit blocks"
        assert user =~ "Hello; "
        assert user =~ "test/greeting.txt"
        assert user =~ "Hello, Ada"

        worktree =
          git(repo, ["worktree", "list", "--porcelain"])
          |> String.split("\n")
          |> Enum.find_value(fn line ->
            case String.split(line, "worktree ", parts: 2) do
              ["", path] when path != repo -> path
              _ -> nil
            end
          end)

        assert File.read!(Path.join(worktree, "lib/greeting.ex")) == @greeting
        refute File.exists?(Path.join(worktree, "test/greeting.txt"))
        reply(@fix <> new_test)
      end,
      reply("PASS")
    ])

    report = Loop.run(task(repo), opts)
    assert report.status == :fixed
    assert report.attempts == 2
    assert git(repo, ["show", "#{report.branch}:test/greeting.txt"]) == "Hello, Ada\n"
    assert_received {:asked, [system, %{content: first}], _}
    assert_received {:asked, [^system, %{content: second}], _}
    assert String.starts_with?(second, first <> "\n\n## The last attempt failed")
  end

  defmodule PoisoningFailedCheck do
    def run(path, command, opts) do
      if Process.get(:poisoned_check) do
        Trailblazer.Loop.Check.run(path, command, opts)
      else
        Process.put(:poisoned_check, true)
        File.write!(Path.join(path, "lib/greeting.ex"), "CHECK_MUTATION_MUST_NOT_BE_CONTEXT\n")
        %{status: :fail, exit: 1, output_tail: "candidate has no comma"}
      end
    end
  end

  test "correction context excludes check mutations and replaces evidence on a missed submission",
       %{repo: repo, opts: opts} do
    wrong = String.replace(@fix, ~s("Hello, " <> name), ~s("Hello; " <> name))
    miss = String.replace(@fix, ~s("Hello " <> name), ~s("Hi " <> name), global: false)

    script([
      reply(wrong),
      fn [_, %{content: user}], _ ->
        assert user =~ "candidate has no comma"
        assert user =~ "Previous submitted edit blocks"
        assert user =~ "Hello; "
        refute user =~ "CHECK_MUTATION_MUST_NOT_BE_CONTEXT"
        reply(miss)
      end,
      fn [_, %{content: user}], _ ->
        assert user =~ "Previous submitted edit blocks"
        assert user =~ "Hi "
        refute user =~ "Hello; "
        reply(@fix)
      end,
      reply("PASS")
    ])

    report = Loop.run(task(repo), Keyword.put(opts, :check, PoisoningFailedCheck))
    assert report.status == :fixed
    assert report.attempts == 3
    assert File.read!(Path.join(repo, "lib/greeting.ex")) == @greeting
  end

  test "dependency evidence is prepared once and shared with retries and review", %{
    repo: repo,
    opts: opts
  } do
    package = Path.join(repo, "node_modules/@babylonjs/core")
    File.mkdir_p!(Path.join(package, "Maths"))
    File.write!(Path.join(repo, "bun.lock"), "{}")

    File.write!(
      Path.join(package, "package.json"),
      ~s({"name":"@babylonjs/core","version":"9.31.0","types":"index.d.ts"})
    )

    File.write!(Path.join(package, "index.d.ts"), ~s(export * from "./Maths/pure.js";))
    File.write!(Path.join(package, "Maths/pure.d.ts"), ~s(export * from "./math.scalar.js";))
    declaration = Path.join(package, "Maths/math.scalar.d.ts")

    File.write!(
      declaration,
      "export declare const Scalar: {\n    Clamp(value: number): number;\n};\n"
    )

    wrong = String.replace(@fix, ~s("Hello, " <> name), ~s("Hello; " <> name))

    script([
      fn [_, %{content: user}], _ ->
        assert user =~ "export declare const Scalar"
        assert user =~ "Clamp(value: number)"
        File.rm!(declaration)
        reply(wrong)
      end,
      fn [_, %{content: user}], _ ->
        assert user =~ "Clamp(value: number)"
        reply(@fix)
      end,
      fn [_, %{content: user}], _ ->
        assert user =~ "Clamp(value: number)"
        refute user =~ "unavailable"
        reply("PASS")
      end
    ])

    report =
      Loop.run(task(repo, %{request: "Use a clamp helper", design: ["Babylon first"]}), opts)

    assert report.status == :fixed
    assert report.attempts == 2

    sizes =
      Enum.find_value(CaseRecord.get(report.case).events, fn e ->
        e.kind == "attempt" and e.data["stage"] == "prompt_size" and e.data["bytes"]
      end)

    assert sizes["Installed dependency evidence"] > 0
  end

  test "a failed review uses up an attempt and its findings are fed back", %{
    repo: repo,
    opts: opts
  } do
    script([
      reply(@fix),
      reply("FAIL: lib/greeting.ex:2 the design wants an exclamation mark"),
      reply(@fix),
      reply("PASS")
    ])

    report = Loop.run(task(repo), opts)
    assert report.status == :fixed
    assert report.attempts == 2

    for _ <- 1..2, do: assert_received({:asked, _, _})
    assert_received {:asked, [_, %{content: third_user}], _}
    assert third_user =~ "exclamation mark"
  end

  test "an unclear review is asked once more before it counts", %{repo: repo, opts: opts} do
    script([reply(@fix), reply("Looks fine to me."), reply("PASS")])
    assert Loop.run(task(repo), opts).status == :fixed
  end

  test "three failures end as failed with a dossier; the last attempt is left to inspect", %{
    repo: repo,
    opts: opts
  } do
    script([reply("no blocks here"), reply("nor here"), reply(@fix), reply("FAIL: wrong")])

    report = Loop.run(task(repo), opts)
    assert report.status == :failed
    assert report.attempts == 3
    assert report.commit == nil
    assert report.dossier =~ "## Request"
    assert report.dossier =~ "no blocks (2)"
    assert report.dossier =~ "review (1)"
    assert File.read!(Path.join(report.worktree, "lib/greeting.ex")) =~ "Hello, "

    record = CaseRecord.get(report.case)
    assert record.status == "failed"
    assert Enum.any?(record.events, &(&1.kind == "dossier"))
  end

  test "with no check the change is unverified and not committed", %{repo: repo, opts: opts} do
    script([reply(@fix), reply("PASS")])
    report = Loop.run(task(repo, %{check: nil}), opts)

    assert report.status == :unverified
    assert report.commit == nil
    assert git(repo, ["rev-parse", report.branch]) == git(repo, ["rev-parse", "main"])
    assert File.read!(Path.join(report.worktree, "lib/greeting.ex")) =~ "Hello, "
  end

  test "a reply cut off at the length limit is a failed attempt, not a half edit", %{
    repo: repo,
    opts: opts
  } do
    script([
      reply(String.slice(@fix, 0, 80), %{finish_reason: "length"}),
      reply(@fix),
      reply("PASS")
    ])

    report = Loop.run(task(repo), opts)
    assert report.status == :fixed
    assert report.attempts == 2
  end

  test "the model being down ends the task at once, recorded", %{repo: repo, opts: opts} do
    script([{:error, :model_down}])
    report = Loop.run(task(repo), opts)
    assert report.status == :failed
    assert report.summary =~ "not running"
    assert CaseRecord.get(report.case).status == "failed"
  end

  test "an unavailable reviewer cannot turn a passing check into a commit", %{
    repo: repo,
    opts: opts
  } do
    script([reply(@fix), {:error, :model_down}, {:error, :model_down}, {:error, :model_down}])
    report = Loop.run(task(repo), opts)
    assert report.status == :awaiting_review
    assert report.commit == nil
    assert report.cost.model_calls == 4
    assert git(repo, ["rev-parse", report.branch]) == git(repo, ["rev-parse", "main"])
    assert report.check == %{status: :pass}
    assert File.dir?(report.worktree)
  end

  test "a timed-out first review pass is retried and a later passing pass commits", %{
    repo: repo,
    opts: opts
  } do
    script([reply(@fix), {:error, :model_down}, reply("PASS")])
    report = Loop.run(task(repo), opts)

    assert report.status == :fixed
    assert report.commit != nil
    assert report.check == %{status: :pass}
    assert report.cost.model_calls == 3
    assert git(repo, ["show", "#{report.branch}:lib/greeting.ex"]) =~ "Hello, "
  end

  test "the reviewer is a dedicated model on its own router with its own 15-minute backstop",
       %{repo: repo, opts: opts} do
    script([reply(@fix), reply("## PASS")])
    assert Loop.run(task(repo), opts).status == :fixed

    assert_received {:asked, _, coder_opts}
    assert_received {:asked, _, reviewer_opts}
    refute Keyword.has_key?(coder_opts, :model)
    assert reviewer_opts[:model] == "nemotron-3.5-bolt-e4b:q4"
    assert reviewer_opts[:model_url] == "http://127.0.0.1:8098/v1"
    assert reviewer_opts[:backstop_ms] in 1..900_000
    assert reviewer_opts[:role] == :reviewer
  end

  test "a permanently unclear review with a passing check ends awaiting_review with the checked tree pinned",
       %{repo: repo, opts: opts} do
    script([
      reply(@fix),
      reply("Looks fine to me."),
      reply("Looks fine still."),
      reply("Definitely fine.")
    ])

    report = Loop.run(task(repo), opts)

    assert report.status == :awaiting_review
    assert report.commit == nil
    assert report.check == %{status: :pass}
    assert File.dir?(report.worktree)

    assert report.awaiting_review.ref == "refs/trailblazer/checkpoints/#{report.case}"

    assert git(repo, ["rev-parse", report.awaiting_review.ref]) ==
             git(report.worktree, ["write-tree"])

    assert CaseRecord.get(report.case).status == "awaiting_review"
  end

  test "a reviewer equal to the coder is refused before any reviewer call", %{
    repo: repo,
    opts: opts
  } do
    Application.put_env(:trailblazer, :review_model, Trailblazer.Config.get(:code_model))
    on_exit(fn -> Application.delete_env(:trailblazer, :review_model) end)

    script([reply(@fix)])
    report = Loop.run(task(repo), opts)

    assert report.status == :awaiting_review
    assert report.commit == nil
    assert report.cost.model_calls == 1
    assert report.awaiting_review.reason == :same_model_review_refused
    assert CaseRecord.get(report.case).status == "awaiting_review"
  end

  test "an awaiting_review case with an admitted primary is not retired; worktree and branch survive",
       %{repo: repo, opts: opts} do
    script([reply(@fix), {:error, :model_down}, {:error, :model_down}, {:error, :model_down}])
    report = Loop.run(task(repo, %{primary: "main"}), opts)

    assert report.status == :awaiting_review
    assert File.dir?(report.worktree)
    assert git(repo, ["rev-parse", report.branch]) == git(repo, ["rev-parse", "main"])
    refute Map.has_key?(report, :integration)

    {_, 0} =
      System.cmd(
        "git",
        ["show-ref", "--verify", "--quiet", "refs/trailblazer/checkpoints/" <> report.case],
        cd: repo
      )
  end

  test "E16: a crash anywhere ends the task as failed with its record closed", %{
    repo: repo,
    opts: opts
  } do
    report = Loop.run(task(repo), Keyword.put(opts, :model, Boom))
    assert report.status == :failed

    record = CaseRecord.get(report.case)
    assert record.status == "failed"
    assert Enum.any?(record.events, &(&1.kind == "error" and &1.data["error"] =~ "blew up"))
  end

  test "a case opened by the caller is used, not a second one", %{repo: repo, opts: opts} do
    {:ok, id} = CaseRecord.open(task(repo))
    script([reply(@fix), reply("PASS")])
    assert Loop.run(task(repo), Keyword.put(opts, :case_id, id)).case == id
    assert CaseRecord.get(id).status == "fixed"
  end

  test "the embedding gate is held around every model call and only then", %{
    repo: repo,
    opts: opts
  } do
    me = self()

    signal = fn message ->
      fn ->
        send(me, message)
        :ok
      end
    end

    gate = {signal.(:hold), signal.(:release)}

    script([
      fn _, _ ->
        assert_received :hold
        refute_received :release
        reply(@fix)
      end,
      reply("PASS")
    ])

    assert Loop.run(task(repo), Keyword.put(opts, :gate, gate)).status == :fixed
    assert_received :release
    assert_received :hold
    assert_received :release
    refute_received :hold
  end

  test "a request for Trailblazer's own repository is refused", %{opts: opts} do
    own = Path.expand("../..", __DIR__)
    report = Loop.run(task(own), opts)
    assert report.status == :failed
    assert report.summary =~ "own repo"
  end

  # The first live trial: Qwen wrote lib/greeting.ex (the prompt's example)
  # and then lib/calc.py for a calc.py at the root, three attempts running.
  test "a block naming the file in the wrong directory still applies", %{repo: repo, opts: opts} do
    wrong_dir = String.replace(@fix, "lib/greeting.ex\n```", "src/greeting.ex\n```")
    script([reply(wrong_dir), reply("PASS")])
    report = Loop.run(task(repo), opts)
    assert report.status == :fixed
    assert report.files == ["lib/greeting.ex"]
  end

  test "a reply of blocks alone still gets a summary and commit message", %{
    repo: repo,
    opts: opts
  } do
    blocks_only = String.replace(@fix, "Add a comma after Hello.\n\n", "")
    script([reply(blocks_only), reply("PASS")])
    report = Loop.run(task(repo), opts)
    assert report.summary == "Changed lib/greeting.ex."

    assert git(repo, ["log", "-1", "--format=%B", report.branch]) |> String.trim() ==
             "Greet with a comma"
  end

  test "an over-long request line is never truncated into a commit; the work stays uncommitted",
       %{repo: repo, opts: opts} do
    script([reply(@fix), reply("PASS")])
    long = String.duplicate("x", 250) <> " bug:abcdef1"
    report = Loop.run(task(repo, %{request: long <> "\nDetails."}), opts)
    assert report.status == :failed
    assert report.summary =~ "over 255 characters"
    assert report[:commit] == nil
  end

  test "worker commits run the repository's hooks, and a refusal is reported", %{
    repo: repo,
    opts: opts
  } do
    hook = Path.join([repo, ".git", "hooks", "commit-msg"])
    File.write!(hook, "#!/bin/sh\necho 'refused by hook' >&2\nexit 1\n")
    File.chmod!(hook, 0o755)
    script([reply(@fix), reply("PASS")])
    report = Loop.run(task(repo), opts)
    assert report.status == :failed
    assert report.summary =~ "refused by hook"
  end

  # Live T3 on sojourney: blocks alone and without fences; the summary was the
  # last lines of the REPLACE text.
  test "a reply of unfenced blocks alone still gets a summary", %{repo: repo, opts: opts} do
    unfenced =
      @fix
      |> String.replace("Add a comma after Hello.\n\n", "")
      |> String.replace(~r/^```[^\n]*\n/m, "")

    script([reply(unfenced), reply("PASS")])
    report = Loop.run(task(repo), opts)
    assert report.status == :fixed
    assert report.summary == "Changed lib/greeting.ex."
  end

  # The second live trial: `python3 test_calc.py` wrote __pycache__/*.pyc, the
  # diff carried it, and the reviewer failed a correct fix for committing it.
  test "D19: what the check leaves behind is neither reviewed nor committed", %{
    repo: repo,
    opts: opts
  } do
    script([reply(@fix), reply("PASS")])
    check = "#{@check} && mkdir -p __pycache__ && echo junk > __pycache__/greeting.pyc"

    report = Loop.run(task(repo, %{check: check}), opts)

    assert report.status == :fixed
    assert_received {:asked, _coder, _}
    assert_received {:asked, [_, %{content: review_user}], _}
    assert review_user =~ "Hello, "
    refute review_user =~ "pyc"
    assert git(repo, ["show", "--name-only", "--format=", report.branch]) == "lib/greeting.ex\n"
  end

  test "a task naming its files gets their chunks in the trail and only their names as files", %{
    repo: repo,
    opts: opts
  } do
    me = self()

    trail = fn _repo, _request, trail_opts ->
      send(me, {:trail_opts, trail_opts})
      %{text: "", notes: []}
    end

    opts = Keyword.put(opts, :trail, trail)
    script([reply(@fix), reply("PASS")])
    Loop.run(task(repo), opts)
    assert_received {:trail_opts, named}
    # the named files seed the trail and their chunks are packed like any other
    assert named[:files] == ["lib/greeting.ex"]
    refute Keyword.has_key?(named, :omit)
    assert named[:budget] == Trailblazer.Config.get(:trail_tokens)

    assert_received {:asked, [_system, %{content: user}], _}
    assert user =~ "lib/greeting.ex: 3 lines"
    refute user =~ "def hello(name)"
    drain_asked()
  end

  defp drain_asked do
    receive do
      {:asked, _, _} -> drain_asked()
    after
      0 -> :ok
    end
  end

  # E25 follow-up (Codex): the cache dies if another model takes the router.
  test "a coder retry that finds no cached prefix is a prompt_cache_miss anomaly", %{
    repo: repo,
    opts: opts
  } do
    :ok = Trailblazer.Events.subscribe(:anomaly)
    miss = String.replace(@fix, "Hello \" <> name\n=======", "Howdy \" <> name\n=======")

    with_progress = fn content, cache ->
      fn _messages, opts ->
        opts[:on_progress].(%{total: 900, processed: cache, cache: cache, ms: 0})
        reply(content)
      end
    end

    # attempt 1 misses its edit; attempt 2 extends the same prompt
    script([with_progress.(miss, 0), with_progress.(@fix, 0), reply("PASS")])
    report = Loop.run(task(repo), opts)
    assert report.status == :fixed
    case_subject = "case #{report.case}"

    assert_receive {:trailblazer_event, :anomaly,
                    %{
                      kind: "prompt_cache_miss",
                      subject: ^case_subject,
                      evidence: %{prompt_tokens: 900}
                    }}

    # the first call has nothing to find; a retry that finds its prefix is fine
    script([with_progress.(miss, 0), with_progress.(@fix, 850), reply("PASS")])
    report = Loop.run(task(repo), opts)
    case_subject = "case #{report.case}"

    refute_received {:trailblazer_event, :anomaly,
                     %{kind: "prompt_cache_miss", subject: ^case_subject}}
  end

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
    script(List.duplicate(submitted([greeting_block()]), 3))
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

  test "a missed atomic submission retains all blocks for a zero-read correction", %{
    repo: repo,
    opts: opts
  } do
    miss = %{greeting_block() | search: ~s|  def hello(name), do: "Hi " <> name\n|}
    addition = %{path: "notes.txt", search: "", replace: "RETAIN_SUBMITTED_NOTE\n"}

    script([
      submitted([addition, miss]),
      fn messages, _ ->
        previous = Enum.find(Enum.reverse(messages), &(&1.role == "assistant"))
        assert hd(previous.tool_calls).function.arguments =~ "RETAIN_SUBMITTED_NOTE"
        assert hd(previous.tool_calls).function.arguments =~ "notes.txt"
        assert List.last(messages).role == "tool"
        refute Enum.at(messages, 1).content =~ "Previous submitted edit blocks"

        record =
          CaseRecord.open_cases()
          |> Enum.map(&CaseRecord.get(&1, inline: false))
          |> Enum.find(&(&1.repo == repo))

        refute File.exists?(Path.join(record.lifecycle["path"], "notes.txt"))
        assert File.read!(Path.join(record.lifecycle["path"], "lib/greeting.ex")) == @greeting
        submitted([addition, greeting_block()])
      end,
      reply("PASS")
    ])

    report = Loop.run(task(repo, %{read_rounds: 0}), opts)
    assert report.status == :fixed
    assert report.attempts == 1
    assert git(repo, ["show", "#{report.commit}:notes.txt"]) == "RETAIN_SUBMITTED_NOTE\n"
  end

  test "zero-read miss without source context stops before an unchanged retry", %{
    repo: repo,
    opts: opts
  } do
    miss = %{greeting_block() | search: "unrelated prose: revise the normative paragraph\n"}
    script([submitted([miss])])
    report = Loop.run(task(repo, %{read_rounds: 0}), opts)
    assert report.status == :failed
    assert report.summary =~ "source_context_missing"
    assert report.summary =~ "lib/greeting.ex"
    assert report.cost.model_calls == 1

    assert Enum.any?(
             CaseRecord.get(report.case).events,
             &(&1.kind == "error" and &1.data["reason"] == "source_context_missing")
           )

    assert_received {:asked, _, _}
    refute_received {:asked, _, _}
  end

  test "nonzero read budget permits a local correction for a source-context miss", %{
    repo: repo,
    opts: opts
  } do
    miss = %{greeting_block() | search: "unrelated prose: revise the normative paragraph\n"}
    script([submitted([miss]), submitted([greeting_block()]), reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 1}), opts)
    assert report.status == :fixed
    assert report.attempts == 1
  end

  test "zero-read missing path with candidate names can correct its target", %{
    repo: repo,
    opts: opts
  } do
    File.mkdir_p!(Path.join(repo, "other"))
    File.write!(Path.join(repo, "other/greeting.ex"), @greeting)
    git(repo, ["add", "."])
    git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "ambiguous names"])

    script([
      submitted([%{greeting_block() | path: "missing/greeting.ex"}]),
      fn messages, _ ->
        feedback = List.last(messages)
        assert feedback.role == "tool"
        assert feedback.content =~ "lib/greeting.ex"
        assert feedback.content =~ "other/greeting.ex"
        previous = Enum.find(Enum.reverse(messages), &(&1.role == "assistant"))
        assert hd(previous.tool_calls).function.arguments =~ "missing/greeting.ex"
        submitted([greeting_block()])
      end,
      reply("PASS")
    ])

    report = Loop.run(task(repo, %{read_rounds: 0}), opts)
    assert report.status == :fixed
    assert report.attempts == 1
  end

  test "malformed native arguments are corrected in the same conversation", %{
    repo: repo,
    opts: opts
  } do
    bad =
      reply("", %{tool_calls: [%{id: "bad-json", name: "submit_edits", arguments: "{not json"}]})

    correction = fn messages, options ->
      assert Enum.map(options[:tools], & &1.function.name) == ["submit_edits"]
      assert Enum.at(messages, -1).role == "tool"
      assert Enum.at(messages, -1).tool_call_id == "bad-json"
      assert Enum.at(messages, -1).content =~ "submit_edits"
      submitted([greeting_block()])
    end

    script([bad, correction, reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 0}), opts)
    assert report.status == :fixed
    assert report.attempts == 1
    assert report.cost.model_calls == 3
  end

  test "repeated forbidden reads exhaust the shared correction budget without executing", %{
    repo: repo,
    opts: opts
  } do
    read =
      reply("", %{
        tool_calls: [%{id: "forbidden", name: "read", arguments: ~s({"path":"lib/greeting.ex"})}]
      })

    script(List.duplicate(read, 4))
    report = Loop.run(task(repo, %{read_rounds: 0, primary: "main"}), opts)
    assert report.status == :failed
    assert report.summary =~ "edit_repair_exhausted"
    assert report.attempts == 1
    assert report.cost.model_calls == 3
    assert File.dir?(report.worktree)
    assert File.read!(Path.join(report.worktree, "lib/greeting.ex")) == @greeting
    assert git(repo, ["show", "main:lib/greeting.ex"]) == @greeting
    events = CaseRecord.get(report.case).events

    refute Enum.any?(
             events,
             &(&1.kind == "tool_call" and &1.data["name"] == "read" and
                 &1.data["status"] != "refused")
           )
  end

  test "three missed submissions stop one attempt and retain evidence", %{repo: repo, opts: opts} do
    miss = %{greeting_block() | search: ~s|  def hello(name), do: "Hi " <> name\n|}
    script(List.duplicate(submitted([miss]), 4))
    report = Loop.run(task(repo, %{read_rounds: 1}), opts)
    assert report.status == :failed
    assert report.summary =~ "edit_repair_exhausted"
    assert report.attempts == 1
    assert report.cost.model_calls == 3
    assert File.read!(Path.join(report.worktree, "lib/greeting.ex")) == @greeting
  end

  test "native ranges use the digest delivered by read without recopying source", %{
    repo: repo,
    opts: opts
  } do
    read =
      reply("", %{
        tool_calls: [%{id: "read-hash", name: "read", arguments: ~s({"path":"lib/greeting.ex"})}]
      })

    submit = fn messages, options ->
      assert options[:tool_choice] == "required"

      assert options[:tools] ==
               [Trailblazer.Loop.Tools.edit_definition(:ranges)]

      digest = :crypto.hash(:sha256, @greeting) |> Base.encode16(case: :lower)

      assert Enum.find(Enum.reverse(messages), &(&1.role == "tool")).content =~
               "sha256: #{digest}"

      submitted([
        %{
          path: "lib/greeting.ex",
          sha256: digest,
          start: 2,
          end: 2,
          first: ~s|  def hello(name), do: "Hello " <> name|,
          last: ~s|def hello(name), do: "Hello " <> name|,
          replace: ~s|  def hello(name), do: "Hello, " <> name\n|
        }
      ])
    end

    script([read, submit, reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 1}), opts)
    assert report.status == :fixed
    assert report.attempts == 1
    assert git(repo, ["show", "#{report.commit}:lib/greeting.ex"]) =~ "Hello, "
  end

  test "whole-file append misuse is corrected locally to a digest-bound replacement", %{
    repo: repo,
    opts: opts
  } do
    replacement = String.replace(@greeting, "Hello ", "Hello, ")

    correction = fn messages, _ ->
      feedback = List.last(messages)
      assert feedback.role == "tool"
      assert feedback.content =~ "file_exists"
      hash = :crypto.hash(:sha256, @greeting) |> Base.encode16(case: :lower)
      assert feedback.content =~ hash

      submitted([
        %{
          path: "lib/greeting.ex",
          sha256: hash,
          start: 1,
          end: 3,
          first: @greeting |> String.split("\n") |> Enum.at(0),
          last: @greeting |> String.split("\n") |> Enum.at(2),
          replace: replacement
        }
      ])
    end

    script([
      submitted([%{path: "lib/greeting.ex", search: "", replace: replacement}]),
      correction,
      reply("PASS")
    ])

    report = Loop.run(task(repo, %{read_rounds: 0}), opts)
    assert report.status == :fixed
    assert report.attempts == 1
    assert report.cost.model_calls == 3
    assert git(repo, ["show", "#{report.commit}:lib/greeting.ex"]) == replacement
  end

  test "existing named files with read rounds advertise an unambiguous range schema", %{
    repo: repo,
    opts: opts
  } do
    first = fn _messages, options ->
      items = List.last(options[:tools]).function.parameters.properties.blocks.items
      refute Map.has_key?(items, :anyOf)
      assert "sha256" in items.required
      submitted([greeting_block()])
    end

    script([first, reply("PASS")])
    assert Loop.run(task(repo, %{read_rounds: 1}), opts).status == :fixed
  end

  test "zero-read and new-file tasks keep the compatible dual schema", %{repo: repo, opts: opts} do
    for extra <- [%{read_rounds: 0}, %{files: ["lib/greeting.ex", "notes.txt"], read_rounds: 1}] do
      first = fn _messages, options ->
        items = List.last(options[:tools]).function.parameters.properties.blocks.items
        assert length(items.anyOf) == 2
        submitted([greeting_block()])
      end

      script([first, reply("PASS")])
      assert Loop.run(task(repo, extra), opts).status == :fixed
    end
  end

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
  test "generated code remains reachable after the next attempt resets the checkout", %{
    repo: repo,
    opts: opts
  } do
    wrong = String.replace(@fix, ~s("Hello, " <> name), ~s("Hello; " <> name))
    script([reply(wrong), reply(@fix), reply("PASS")])
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

    script([reply(@fix), reply(@fix), reply("PASS")])

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
