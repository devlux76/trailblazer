defmodule Trailblazer.LoopTest.NativeReplay do
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

  @check "grep -q 'Hello, ' lib/greeting.ex"

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

  # A case that applied one native submit_edits call and then failed in the
  # artifact stage (no check, no review), as recorded by the coder run.
  defp saved_native_reply(repo, policy, options \\ []) do
    {:ok, id} = CaseRecord.open(task(repo, %{artifacts: policy}))

    CaseRecord.event(id, :attempt, %{
      stage: :workspace,
      base: String.trim(git(repo, ["rev-parse", "HEAD"]))
    })

    {:ok, data} = submitted([greeting_block()])
    data = Map.merge(data, %{role: :coder, finish_reason: "tool_calls"})
    data = Map.merge(data, Keyword.get(options, :reply, %{}))
    CaseRecord.event(id, :reply, data)

    CaseRecord.event(id, :edit, %{
      status: :applied,
      blocks: Keyword.get(options, :blocks, [greeting_block()])
    })

    if Keyword.get(options, :error, true),
      do:
        CaseRecord.event(id, :error, %{
          stage: Keyword.get(options, :stage, :artifacts),
          reason: :outside_outputs
        })

    if Keyword.get(options, :check, false), do: CaseRecord.event(id, :check, %{status: :fail})
    CaseRecord.close(id, %{status: :failed, summary: "preparation refused"})
    id
  end

  test "native artifact-failure replay regenerates and reviews without coding inference", %{
    repo: repo,
    opts: opts
  } do
    policy = artifact_policy(repo, "mkdir -p dist && cp lib/greeting.ex dist/greeting.ex")
    source = saved_native_reply(repo, policy)
    script([reply("PASS")])
    report = Loop.run(task(repo, %{artifacts: policy, replay_reply_from: source}), opts)
    assert report.status == :fixed
    assert report.cost.model_calls == 1
    assert git(repo, ["show", "#{report.commit}:dist/greeting.ex"]) =~ "Hello, "
    event = Enum.find(CaseRecord.get(report.case).events, &(&1.data["replayed_from"] == source))
    assert byte_size(event.data["source_reply_sha256"]) == 64

    refute event.data["source_reply_sha256"] ==
             Base.encode16(:crypto.hash(:sha256, ""), case: :lower)

    assert CaseRecord.get(source).status == "failed"
    assert_received {:asked, [_, %{content: review}], options}
    assert options[:tools] == nil
    assert review =~ "Diff"
    refute_received {:asked, _, _}
  end

  test "native replay refuses malformed or unrelated source replies before model calls", %{
    repo: repo,
    opts: opts
  } do
    policy = artifact_policy(repo, "mkdir -p dist && cp lib/greeting.ex dist/greeting.ex")

    call = %{
      id: "edit1",
      name: "submit_edits",
      arguments: Jason.encode!(%{blocks: [greeting_block()]})
    }

    for invalid <- [
          [reply: %{finish_reason: "length"}],
          [reply: %{partial: true}],
          [reply: %{partial: "false"}],
          [reply: %{finish_reason: "stop"}],
          [reply: %{tool_calls: []}],
          [reply: %{tool_calls: [call, call]}],
          [reply: %{tool_calls: [%{call | name: "read"}]}],
          [reply: %{tool_calls: [Map.put(call, :extra, true)]}],
          [reply: %{tool_calls: [%{call | id: ""}]}],
          [reply: %{tool_calls: [%{call | arguments: "{"}]}],
          [reply: %{tool_calls: [%{call | arguments: ~s({"blocks":[],"shell":"true"})}]}],
          [blocks: []],
          [stage: :check],
          [error: false],
          [check: true]
        ] do
      source = saved_native_reply(repo, policy, invalid)
      script([])
      report = Loop.run(task(repo, %{artifacts: policy, replay_reply_from: source}), opts)
      assert report.status == :failed, inspect(invalid)
      assert report.cost.model_calls == 0, inspect(invalid)
      assert report.files == []
      assert report.summary =~ "recorded reply cannot be replayed", inspect(invalid)
    end

    refute_received {:asked, _, _}
  end

  test "native replay retains exact peer check policy and base gates", %{repo: repo, opts: opts} do
    policy = artifact_policy(repo, "mkdir -p dist && cp lib/greeting.ex dist/greeting.ex")
    source = saved_native_reply(repo, policy)
    changed = artifact_policy(repo, "true")

    for extra <- [%{from: "other"}, %{check: "false"}, %{artifacts: changed}] do
      report =
        Loop.run(
          task(repo, Map.merge(%{artifacts: policy, replay_reply_from: source}, extra)),
          opts
        )

      assert report.status == :failed
      assert report.cost.model_calls == 0
    end

    git(repo, [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "commit",
      "--allow-empty",
      "-qm",
      "new base"
    ])

    report = Loop.run(task(repo, %{artifacts: policy, replay_reply_from: source}), opts)
    assert report.status == :failed
    assert report.cost.model_calls == 0
  end
end
