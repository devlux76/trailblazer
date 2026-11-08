defmodule Trailblazer.LoopTest.Corrections do
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

  @fix_tags """
  Add a comma after Hello.

  <edit path="lib/greeting.ex" start="2" end="2">
  <first>  def hello(name), do: "Hello " <> name</first>
  <last>  def hello(name), do: "Hello " <> name</last>
  <replace>
    def hello(name), do: "Hello, " <> name
  </replace>
  </edit>
  """

  @check "grep -q 'Hello, ' lib/greeting.ex"

  # A retry continues from the previous attempt's edits, so corrections are
  # made against them (not against the original file).

  defp task(repo, extra),
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
      assert Enum.map(options[:tools], & &1.function.name) == ["submit_edits", "edit"]
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

  test "text edit mode: no edit tool, numbered source, tag reply applied", %{
    repo: repo,
    opts: opts
  } do
    coder = fn messages, options ->
      assert hd(messages).content =~ "There is no edit tool"
      assert hd(messages).content =~ "<edit path="
      user = Enum.at(messages, 1).content
      assert user =~ "## Current source"

      assert user =~
               "lib/greeting.ex (3 lines)\n```elixir\n1| defmodule Greeting do\n" <>
                 ~s[2|   def hello(name), do: "Hello " <> name\n3| end\n```]

      refute options[:tools]
      refute options[:tool_choice]
      assert List.last(messages).content =~ "<edit>/<create> blocks only"
      reply(@fix_tags)
    end

    script([coder, reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 0, edit_mode: "text"}), opts)
    assert report.status == :fixed
    assert git(repo, ["show", "#{report.commit}:lib/greeting.ex"]) =~ "Hello, "
  end

  test "text mode refuses SEARCH/REPLACE and takes the corrected tag reply", %{
    repo: repo,
    opts: opts
  } do
    fixed = fn messages, _ ->
      assert Enum.at(messages, 1).content =~ "Your reply had no edits"
      assert Enum.at(messages, 1).content =~ "<edit path start end>"
      reply(@fix_tags)
    end

    script([reply(@fix), fixed, reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 0, edit_mode: :text}), opts)
    assert report.status == :fixed
    assert report.attempts == 2
  end

  test "text mode: a miscounted range is refused by its quotes, not applied", %{
    repo: repo,
    opts: opts
  } do
    # quotes found once elsewhere: the range moves to them (line 1 survives)
    miscounted = String.replace(@fix_tags, ~s(start="2" end="2"), ~s(start="1" end="1"))
    script([reply(miscounted), reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 0, edit_mode: :text}), opts)
    assert report.status == :fixed
    file = git(repo, ["show", "#{report.commit}:lib/greeting.ex"])
    assert file =~ "defmodule Greeting do"
    assert file =~ "Hello, "

    # quotes found nowhere: refused with the current lines, nothing written
    invented =
      String.replace(@fix_tags, "<first>  def hello", "<first>  def greet")

    fixed = fn messages, _ ->
      assert Enum.at(messages, 1).content =~ "anchor_mismatch"
      reply(@fix_tags)
    end

    script([reply(invented), fixed, reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 0, edit_mode: :text}), opts)
    assert report.status == :fixed
    assert report.attempts == 2
  end

  test "a bare-code <edit> is answered with the named lines and the block to fill", %{
    repo: repo,
    opts: opts
  } do
    bare =
      ~s[<edit path="lib/greeting.ex" start="2" end="2">\n  def hello(name), do: "Hello, " <> name\n</edit>\n]

    fixed = fn messages, _ ->
      feedback = Enum.at(messages, 1).content
      assert feedback =~ "holds only code"
      assert feedback =~ ~s(lib/greeting.ex lines 2-2 are now:\n2|   def hello)
      assert feedback =~ ~s[<first>  def hello(name), do: "Hello " <> name</first>]
      reply(@fix_tags)
    end

    script([reply(bare), fixed, reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 0, edit_mode: :text}), opts)
    assert report.status == :fixed
    assert report.attempts == 2
  end

  test "restating edits carried from a failed attempt goes on to verification", %{
    repo: repo,
    opts: opts
  } do
    # the review fails attempt 1; attempt 2 restates the (now carried) fixed
    # line as it stands, which changes no byte but must still be checked and
    # reviewed
    restated = String.replace(@fix_tags, ~s("Hello " <> name</), ~s("Hello, " <> name</))
    script([reply(@fix_tags), reply("FAIL: flaky"), reply(restated), reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 0, edit_mode: :text}), opts)
    assert report.status == :fixed
    assert report.attempts == 2
  end

  test "an edit that changes nothing is said once and ends the case the second time", %{
    repo: repo,
    opts: opts
  } do
    noop = String.replace(@fix_tags, ~s("Hello, "), ~s("Hello "))
    refute noop == @fix_tags

    second = fn messages, _ ->
      assert Enum.at(messages, 1).content =~ "changed nothing"
      reply(noop)
    end

    script([reply(noop), second])
    report = Loop.run(task(repo, %{read_rounds: 0, edit_mode: :text}), opts)
    assert report.status == :failed
    assert report.summary =~ "no_change"
    assert report.cost.model_calls == 2
  end

  test "text edit mode reads with tools but never offers submit_edits", %{repo: repo, opts: opts} do
    read = fn _messages, options ->
      names = Enum.map(options[:tools], & &1.function.name)
      assert "read" in names
      refute "submit_edits" in names

      reply("", %{
        tool_calls: [%{id: "r1", name: "read", arguments: ~s({"path":"lib/greeting.ex"})}]
      })
    end

    final = fn messages, options ->
      refute options[:tools]
      assert Enum.any?(messages, &(&1.role == "tool"))
      reply(@fix_tags)
    end

    script([read, final, reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 1, edit_mode: :text}), opts)
    assert report.status == :fixed
  end

  test "text mode answers an unoffered submit_edits call like an unknown tool", %{
    repo: repo,
    opts: opts
  } do
    rogue = fn _messages, options ->
      refute options[:tool_choice]
      submitted([greeting_block()])
    end

    final = fn messages, options ->
      refute options[:tools]
      refute options[:tool_choice]
      tool = Enum.find(messages, &(&1.role == "tool"))
      assert tool.content =~ "no edit tool in this mode"
      reply(@fix_tags)
    end

    script([rogue, final, reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 1, edit_mode: :text}), opts)
    assert report.status == :fixed
  end

  test "tool mode does not send named files whole", %{repo: repo, opts: opts} do
    coder = fn messages, _options ->
      refute Enum.at(messages, 1).content =~ "## Current source"
      submitted([greeting_block()])
    end

    script([coder, reply("PASS")])
    assert Loop.run(task(repo, %{read_rounds: 0}), opts).status == :fixed
  end
end
