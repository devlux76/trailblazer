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
end
