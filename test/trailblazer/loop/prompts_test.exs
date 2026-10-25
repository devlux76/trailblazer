defmodule Trailblazer.Loop.PromptsTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Loop.{Edits, Prompts}

  @task %{
    request: "Greet with a comma",
    design: ["docs/design.md:3-9 Greetings are polite."],
    from: "cli"
  }

  test "the coder prompt's own example is a block Edits parses" do
    assert {:ok, [%{path: "lib/greeting.ex", search: search, replace: replace}]} =
             Edits.parse(Prompts.coder_system())

    assert search =~ "Hello "
    assert replace =~ "Hello, "
  end

  test "the prompts are short (design §10: every token is one the trail cannot use)" do
    for text <- [Prompts.coder_system(), Prompts.reviewer_system()] do
      assert div(String.length(text), 4) < 600
    end
  end

  test "an attempt's messages hold the request, design, trail, files and the last failure" do
    [system, user] =
      Prompts.coder(
        @task,
        "lib/greeting.ex:1-3\n  def hello",
        [{"lib/greeting.ex", "x\n"}],
        "check failed: 1 test"
      )

    assert system.role == "system" and user.role == "user"

    for part <- [
          "## Request",
          "Greet with a comma",
          "## Design",
          "polite",
          "## Trail",
          "## Files",
          "lib/greeting.ex\n```elixir\nx\n```",
          "## The last attempt failed",
          "1 test"
        ] do
      assert user.content =~ part
    end

    [_, first] = Prompts.coder(%{request: "r"}, "trail", [])
    refute first.content =~ "## Design"
    refute first.content =~ "failed"
  end

  test "A5: a file that holds a fence gets a longer one" do
    [_, user] = Prompts.coder(%{request: "r"}, "", [{"README.md", "```sh\nls\n```\n"}])
    assert user.content =~ "README.md\n````markdown\n```sh\nls\n```\n````"
  end

  test "the reviewer sees the request, the design and the diff, and nothing of the attempt" do
    [system, user] = Prompts.reviewer(@task, "--- a/x\n+++ b/x\n")
    assert system.content =~ "PASS"
    assert user.content =~ "```diff\n--- a/x"
    assert user.content =~ "polite"
  end

  test "coder and reviewer share installed evidence before retry-only feedback" do
    evidence = [
      {"node_modules/@babylonjs/core/Maths/math.scalar.d.ts",
       "export declare const Scalar: { Clamp(value: number): number; };"}
    ]

    [_, first] = Prompts.coder(@task, "", [], nil, %{evidence: evidence})
    [_, retry] = Prompts.coder(@task, "", [], "the check failed", %{evidence: evidence})
    [_, review] = Prompts.reviewer(@task, "diff", evidence)
    assert first.content =~ "## Installed dependency evidence"
    assert first.content =~ "Clamp(value: number)"
    assert review.content =~ "Clamp(value: number)"
    assert String.starts_with?(retry.content, first.content <> "\n\n## The last attempt failed")
  end

  test "D4: a review is read by its first line; anything else is unclear, not a pass" do
    assert Prompts.review_verdict("PASS") == :pass
    assert Prompts.review_verdict("\n**PASS**\n") == :pass

    assert Prompts.review_verdict("FAIL: lib/a.ex:3 renames x\nlib/b.ex:9 stray IO.inspect") ==
             {:fail, "lib/a.ex:3 renames x\nlib/b.ex:9 stray IO.inspect"}

    assert Prompts.review_verdict("FAIL\n- lib/a.ex:3 wrong") == {:fail, "- lib/a.ex:3 wrong"}
    assert {:unclear, _} = Prompts.review_verdict("Looks good to me, PASS")
    assert {:unclear, _} = Prompts.review_verdict("")
    assert {:unclear, _} = Prompts.review_verdict("PASSED? not sure")
  end

  test "the dossier follows design §7.5 and says what is missing" do
    text =
      Prompts.dossier(%{
        case: "20261018-170000-abcdef",
        request: "Greet with a comma",
        repo: "/home/mirai/projects/sojourney",
        branch: "trailblazer/20261018-170000-abcdef",
        worktree: "/state/worktrees/20261018-170000-abcdef",
        trail: "lib/greeting.ex:1-3",
        attempts: [%{n: 1, summary: "lib/greeting.ex", failure: "1 test failed"}, %{n: 2}],
        diagnosis: nil
      })

    for part <- [
          "case 20261018-170000-abcdef",
          "2 times",
          "Asked by cli",
          "### Attempt 1",
          "1 test failed",
          "### Attempt 2",
          "nothing applied",
          "## Diagnosis\n\n(not given)"
        ] do
      assert text =~ part
    end
  end
end
