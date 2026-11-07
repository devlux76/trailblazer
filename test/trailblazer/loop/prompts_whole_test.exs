defmodule Trailblazer.Loop.PromptsWholeTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Loop.Prompts

  test "whole-file prompt: request once, no host bookkeeping, plain source, usages" do
    plan = "Implementation plan: change line 28 to parse with multiaddr."

    task = %{
      request:
        "F41 fix bug:c581381\n\n#{plan}\nCheck: bun test\nCompiler gate: bun run typecheck. Hard15min per context.\n\nCurrent checkpoints:\nplanner note (trailblazer) #47: accepted\nCurrent planner card vortex:c581381. Elixir owns execution.",
      design: plan,
      edit_mode: :text
    }

    [system, user] =
      Prompts.coder(task, "trail text", [{"src/a.ts", 2}], nil, %{
        whole: true,
        sources: [{"src/a.ts", "one\ntwo\n"}],
        usages: "import { multiaddr } from '@multiformats/multiaddr'"
      })

    assert system.content =~ "COMPLETE"
    body = user.content
    assert length(String.split(body, plan)) == 2
    refute body =~ "## Design"
    refute body =~ "Compiler gate"
    refute body =~ "Elixir owns"
    refute body =~ "planner note"
    assert body =~ "import { multiaddr } from '@multiformats/multiaddr'"
    assert body =~ "one\ntwo"
    refute body =~ "1| one"

    # a long file is numbered (changed by <edit> range, not retyped)
    long = Enum.map_join(1..151, "", &"l#{&1}\n")

    [system, user] =
      Prompts.coder(task, "trail", [{"src/b.py", 151}], nil, %{
        whole: true,
        sources: [{"src/b.py", long}]
      })

    assert system.content =~ "numbered lines is long"
    assert user.content =~ "151| l151"
  end

  test "tag mode prompt is unchanged by the whole-file helpers" do
    [_s, user] =
      Prompts.coder(
        %{request: "r\nCompiler gate: x", design: "d", edit_mode: :text},
        "t",
        [],
        nil,
        %{
          sources: [{"a.ts", "one\n"}]
        }
      )

    assert user.content =~ "Compiler gate"
    assert user.content =~ "## Design"
    assert user.content =~ "1| one"
  end

  test "reviewer: complete changed files, lean request, the plan wins and the check passed" do
    task = %{
      request: "old body: change contact.ts and tests\nCompiler gate: x\nElixir owns execution.",
      design: "Implementation plan: source already in; add two tests only."
    }

    [system, user] =
      Prompts.reviewer(task, "+++ b/a.test.ts\n+test()", [], [
        {"a.test.ts", "const peer = 1\ntest()\n"}
      ])

    assert system.content =~ "already run and passed"
    assert user.content =~ "Changed files after the change (complete)"
    assert user.content =~ "const peer = 1"
    refute user.content =~ "Compiler gate"
    assert user.content =~ "add two tests only"
  end

  test "whole-file trail: named files kept, others only within the budget, order kept" do
    big = String.duplicate("x", 2_500)

    trail =
      Enum.join(
        [
          "src/a.ts:1-3\nfunction a",
          "src/other.ts:1-9\n" <> big,
          "src/a.test.ts:5-5\nconst addr",
          "src/third.ts:1-2\n" <> big
        ],
        "\n\n"
      )

    lean = Prompts.lean_trail(trail, %{sources: [{"src/a.ts", ""}, {"src/a.test.ts", ""}]})
    assert lean =~ "function a"
    assert lean =~ "const addr"
    assert lean =~ "src/other.ts"
    refute lean =~ "src/third.ts"

    assert String.split(lean, "\n\n") |> Enum.map(&hd(String.split(&1, ":"))) ==
             ["src/a.ts", "src/other.ts", "src/a.test.ts"]
  end

  test "review verdict: only what follows the last </think> counts" do
    leaked = "FAIL: the diff is missing a test - wait, it is present.\nSo PASS.</think>\nPASS"
    assert Prompts.review_verdict(leaked) == :pass

    assert {:fail, "x is wrong"} =
             Prompts.review_verdict("<think>PASS?</think>\nFAIL: x is wrong")

    assert Prompts.review_verdict("PASS") == :pass
  end
end
