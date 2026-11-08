defmodule Trailblazer.LoopTest.Review do
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
        refute user =~ "CHECK_MUTATION_MUST_NOT_BE_CONTEXT"
        reply(@correct)
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
        reply(@correct)
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
      reply(@exclaim),
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
    assert reviewer_opts[:model_url] == "http://127.0.0.1:8094/v1"
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
end
