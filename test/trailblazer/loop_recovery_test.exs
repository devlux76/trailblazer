defmodule Trailblazer.LoopTest.Recovery do
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

  # Recall runs in a job of its own, so the test's pid is found globally.

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
               ~w(submit_edits edit)

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
               ~w(submit_edits edit)

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
               ~w(submit_edits edit)

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

  test "a failed check is fed back with its output, and the retry continues from those edits",
       %{repo: repo, opts: opts} do
    wrong = String.replace(@fix, ~s("Hello, " <> name), ~s("Hello; " <> name))
    script([reply(wrong), reply(@correct), reply("PASS")])

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
    assert second_user =~ "Your previous edits are still applied"
    # the correction matched the carried edit, so the output refers to real code
    assert git(repo, ["show", "#{report.branch}:lib/greeting.ex"]) =~ ~s("Hello, ")
  end

  test "a retry keeps the previous edits, including a created test file",
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
        assert user =~ "Your previous edits are still applied"
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

        assert File.read!(Path.join(worktree, "lib/greeting.ex")) =~ "Hello; "
        assert File.read!(Path.join(worktree, "test/greeting.txt")) == "Hello, Ada\n"
        reply(@correct)
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
end
