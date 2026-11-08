defmodule Trailblazer.LoopTest do
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

  defp greeting_block do
    %{
      path: "lib/greeting.ex",
      search: ~s|  def hello(name), do: "Hello " <> name\n|,
      replace: ~s|  def hello(name), do: "Hello, " <> name\n|
    }
  end

  # Recall runs in a job of its own, so the test's pid is found globally.

  defmodule ExamplesAt do
    def recall(task, opts) do
      send(
        :persistent_term.get(:examples_test_pid),
        {:recall, task.request, opts[:before], opts[:reachable]}
      )

      {:ok, %{text: "PAST CHANGE", ids: ["e1"], how: :rerank, considered: 4, rerank_error: nil}}
    end
  end

  test "with examples on, the coder sees similar past changes from before the base, and the ids are recorded",
       %{repo: repo, opts: opts} do
    base_time =
      repo |> git(["show", "-s", "--format=%ct", "HEAD"]) |> String.trim() |> String.to_integer()

    :persistent_term.put(:examples_test_pid, self())
    on_exit(fn -> :persistent_term.erase(:examples_test_pid) end)

    script([
      fn messages, _ ->
        user = Enum.map_join(messages, "\n", &(&1[:content] || ""))
        assert user =~ "## Similar past changes\n\nPAST CHANGE"
        reply(@fix_tags)
      end,
      reply("PASS")
    ])

    report =
      Loop.run(
        task(repo, %{read_rounds: 0, edit_mode: :text, examples: true}),
        Keyword.put(opts, :examples, ExamplesAt)
      )

    assert report.status == :fixed
    assert_received {:recall, "Greet with a comma", ^base_time, reachable}
    # the case repository's commits reachable from the base: here, its one commit
    assert reachable == MapSet.new([String.trim(git(repo, ["rev-parse", "HEAD"]))])

    assert %{"ids" => ["e1"], "how" => "rerank", "considered" => 4} =
             Enum.find_value(CaseRecord.get(report.case).events, fn e ->
               e.kind == "attempt" and e.data["stage"] == "examples" and e.data
             end)

    # off (the default): no recall, no section
    script([
      fn messages, _ ->
        user = Enum.map_join(messages, "\n", &(&1[:content] || ""))
        refute user =~ "Similar past changes"
        reply(@fix_tags)
      end,
      reply("PASS")
    ])

    repo2 = repo <> "-off"
    File.cp_r!(repo, repo2)
    on_exit(fn -> File.rm_rf!(repo2) end)

    assert Loop.run(
             task(repo2, %{read_rounds: 0, edit_mode: :text}),
             Keyword.put(opts, :examples, ExamplesAt)
           ).status ==
             :fixed

    refute_received {:recall, _, _, _}
  end

  test "with code_think_prefill, the trail and history are the coder's prefilled thinking, and the echo is stripped",
       %{repo: repo, opts: opts} do
    Application.put_env(:trailblazer, :code_think_prefill, true)
    on_exit(fn -> Application.delete_env(:trailblazer, :code_think_prefill) end)
    :persistent_term.put(:examples_test_pid, self())
    on_exit(fn -> :persistent_term.erase(:examples_test_pid) end)
    parent = self()

    script([
      fn messages, _ ->
        # system, the task, text mode's "Reading is complete", the prefill
        [system, user | _] = messages
        prefill = List.last(messages)
        assert system.role == "system"
        refute user.content =~ "Similar past changes"
        refute user.content =~ "## Trail"
        assert prefill.role == "assistant"
        assert prefill.content =~ ~r/\A<think>## Similar past changes\n\nPAST CHANGE/
        assert String.ends_with?(prefill.content, "</think>")
        send(parent, {:prefill, prefill.content})
        # the server echoes the prefill at the head of the content
        reply(prefill.content <> @fix_tags)
      end,
      fn messages, _ ->
        refute List.last(messages).role == "assistant"
        reply("PASS")
      end
    ])

    report =
      Loop.run(
        task(repo, %{read_rounds: 0, edit_mode: :text, examples: true}),
        Keyword.put(opts, :examples, ExamplesAt)
      )

    assert report.status == :fixed
    assert_received {:prefill, _}
    assert git(repo, ["show", "#{report.commit}:lib/greeting.ex"]) =~ "Hello, "
  end

  test "with code_think_prefill, a tool round carries the prefilled thinking in history and prefills empty after",
       %{repo: repo, opts: opts} do
    Application.put_env(:trailblazer, :code_think_prefill, true)
    on_exit(fn -> Application.delete_env(:trailblazer, :code_think_prefill) end)

    script([
      fn messages, _ ->
        assert %{role: "assistant", content: "<think>" <> _} = List.last(messages)
        # streamed: no echo
        reply("", %{
          tool_calls: [%{id: "r1", name: "read", arguments: ~s({"path":"lib/greeting.ex"})}]
        })
      end,
      fn messages, _ ->
        assert List.last(messages) == %{role: "assistant", content: "<think></think>"}

        earlier =
          Enum.find(messages, &(&1[:role] == "assistant" and &1[:tool_calls] not in [nil, []]))

        assert earlier.content =~ ~r/\A<think><\/think><think>.*## Trail.*<\/think>\z/s
        assert Enum.count(messages, &(&1[:role] == "assistant")) == 2
        reply(@fix_tags)
      end,
      reply("PASS")
    ])

    assert Loop.run(task(repo, %{read_rounds: 1, edit_mode: :text}), opts).status == :fixed
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
end
