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
      gate: false
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
      assert Enum.map(options[:tools], & &1.function.name) == ["submit_edits"]
      assert options[:tool_choice] == %{type: "function", function: %{name: "submit_edits"}}
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
      assert Enum.map(options[:tools], & &1.function.name) == ["submit_edits"]
      assert options[:tool_choice] == %{type: "function", function: %{name: "submit_edits"}}
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
      assert Enum.map(options[:tools], & &1.function.name) == ["submit_edits"]
      assert options[:tool_choice] == %{type: "function", function: %{name: "submit_edits"}}
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
    assert second_user =~ "Previous applied edits"
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
        assert user =~ "previous edits were discarded"
        assert user =~ "original files"
        assert user =~ "Previous applied edits"
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

  test "correction context keeps model edits before check mutations and clears them after a missed edit",
       %{repo: repo, opts: opts} do
    wrong = String.replace(@fix, ~s("Hello, " <> name), ~s("Hello; " <> name))
    miss = String.replace(@fix, ~s("Hello " <> name), ~s("Hi " <> name), global: false)

    script([
      reply(wrong),
      fn [_, %{content: user}], _ ->
        assert user =~ "candidate has no comma"
        assert user =~ "Previous applied edits"
        assert user =~ "Hello; "
        refute user =~ "CHECK_MUTATION_MUST_NOT_BE_CONTEXT"
        reply(miss)
      end,
      fn [_, %{content: user}], _ ->
        refute user =~ "Previous applied edits"
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
    script([reply(@fix), {:error, :model_down}])
    report = Loop.run(task(repo), opts)
    assert report.status == :failed
    assert report.commit == nil
    assert git(repo, ["rev-parse", report.branch]) == git(repo, ["rev-parse", "main"])
    assert report.check == %{status: :pass}
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
    assert report.status == :failed
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
end
