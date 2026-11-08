defmodule Trailblazer.LoopTest.Guards do
  use ExUnit.Case, async: false

  alias Trailblazer.Loop

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

  defp task(repo, extra \\ %{}),
    do:
      Map.merge(
        %{repo: repo, request: "Greet with a comma", files: ["lib/greeting.ex"], check: @check},
        extra
      )

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

  test "an over-long request line commits with shortened prose and every bug reference kept",
       %{repo: repo, opts: opts} do
    script([reply(@fix), reply("PASS")])
    long = "Fix bug:abcdef1 " <> String.duplicate("word ", 60) <> "bug:1234567"
    report = Loop.run(task(repo, %{request: long <> "\nDetails."}), opts)
    assert report.status == :fixed
    message = git(repo, ["log", "-1", "--format=%B", report.branch]) |> String.trim()
    assert byte_size(message) <= 255
    assert message =~ ~r/^Fix word word .*\.\.\. bug:abcdef1 bug:1234567$/
  end

  test "a request line that is nothing but references stays uncommitted", %{
    repo: repo,
    opts: opts
  } do
    script([reply(@fix), reply("PASS")])
    refs = Enum.map_join(1..30, " ", &"bug:#{String.pad_leading(Integer.to_string(&1), 7, "0")}")
    report = Loop.run(task(repo, %{request: refs}), opts)
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
end
