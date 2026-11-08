defmodule Trailblazer.Planner.BoardTest do
  # Board eligibility over the real planner CLI and a real temporary git-bug
  # repository: only an unclaimed todo card labelled dispatch:ready of an
  # admitted repository with exactly one admitted check, never Trailblazer
  # itself, is a candidate — a ready defect card is as eligible as a ready
  # task. The CLI runs through a wrapper that keeps the watched repositories
  # and planner state in a temporary directory, so nothing here touches live
  # state. Every repository's board is read separately, before any limit.
  use ExUnit.Case, async: false
  alias Trailblazer.Planner.Board

  @ready ["dispatch:ready"]

  setup do
    dir = Path.join(System.tmp_dir!(), "planner-board-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    repo = Path.join(dir, "probe")
    File.mkdir_p!(repo)

    git = fn args ->
      {out, 0} =
        System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
          cd: repo,
          stderr_to_stdout: true
        )

      out
    end

    git.(["init", "-q", "-b", "main"])
    git.(["bug", "user", "new", "-n", "t", "-e", "t@example.invalid", "--non-interactive"])

    # the planner watches repositories by listing paths, one per line
    File.write!(Path.join(dir, "repos"), repo <> "\n")

    planner = Path.join(dir, "planner")
    installed = Path.expand("~/.local/bin/planner")
    File.exists?(installed) || flunk("the installed planner CLI is missing")

    File.write!(planner, """
    #!/bin/sh
    exec #{installed} --repos-file #{dir}/repos --state-dir #{dir}/state "$@"
    """)

    File.chmod!(planner, 0o755)
    %{dir: dir, repo: repo, git: git, planner: planner}
  end

  defp config(ctx, repos, extra \\ %{}) do
    path = Path.join(ctx.dir, "trailblazer.json")

    extra = Map.put_new(extra, "planner", [ctx.planner])

    File.write!(path, Jason.encode!(Map.merge(%{"repos" => repos}, extra)))
    Board.load_config!(path)
  end

  # `git bug bug new` prints "<human-id> created"; the human id is the ref
  # the planner boards use. stderr noise from a cold git-bug cache may
  # precede it, so the id is found, not split off the head.
  defp card(ctx, title, labels, body \\ "body") do
    out = ctx.git.(["bug", "bug", "new", "-t", title, "-m", body, "--non-interactive"])
    [id] = Regex.run(~r/([0-9a-f]{7,}) created/, out, capture: [1]) || flunk(out)

    for label <- labels, do: ctx.git.(["bug", "bug", "label", "new", id, label])

    "probe:" <> id
  end

  defp read(config, opts \\ []) do
    Board.read(config, Keyword.put_new(opts, :self, "/nonexistent"))
  end

  test "an eligible card comes back with its ref, check, priority and a bounded context",
       ctx do
    ref = card(ctx, "fix the parser", @ready)
    config = config(ctx, %{ctx.repo => ["make check"]})

    assert {:ok, %{cards: [c], fingerprint: fp}} = read(config)
    assert c.ref == ref
    assert c.check == "make check"
    assert c.repo == ctx.repo
    assert c.context["title"] == "fix the parser"
    assert is_binary(c.context["body"])
    assert c.context["priority"] == "p2"
    assert c.context["check"] == "make check"
    assert c.context["recent"] == []
    assert is_binary(fp) and byte_size(fp) == 64

    # the fingerprint is stable while the board stands still
    assert {:ok, %{fingerprint: ^fp}} = read(config)
  end

  test "the context carries the routing facts the check reads", ctx do
    ref =
      card(ctx, "split the parser", @ready, """
      Reset it.

      Files: lib/parser.ex test/parser_test.exs
      Acceptance: make test passes
      Implementation plan: Extract parser reset and assert its behavior in parser_test.exs.
      """)

    config = config(ctx, %{ctx.repo => ["make check"]})

    assert {:ok, %{cards: [c]}} = read(config)
    assert c.ref == ref
    assert c.context["labels"] == @ready
    assert c.context["files"] == ["lib/parser.ex", "test/parser_test.exs"]
    assert c.context["route"] == "trailblazer"

    labelled = card(ctx, "needs research first", ["dispatch:research", "dispatch:ready"])
    assert {:ok, %{cards: cards}} = read(config)
    research = Enum.find(cards, &(&1.ref == labelled))
    assert research.context["route"] == "research"
    assert research.context["files"] == []

    body_ref =
      card(
        ctx,
        "half specified",
        @ready,
        "Files: lib/only.ex\nImplementation plan: Extract helper and test its behavior."
      )

    assert {:ok, %{cards: cards}} = read(config)
    tie = Enum.find(cards, &(&1.ref == body_ref))
    assert tie.context["route"] == "tie"
  end

  test "the fingerprint follows the card's priority, check and context", ctx do
    ref = card(ctx, "priority matters", @ready)
    id = String.replace_prefix(ref, "probe:", "")
    config = config(ctx, %{ctx.repo => ["make check"]})

    {:ok, %{fingerprint: p2}} = read(config)
    assert {:ok, %{cards: [c]}} = read(config)
    assert c.context["priority"] == "p2"

    ctx.git.(["bug", "bug", "label", "new", id, "priority:p1"])
    assert {:ok, %{cards: [c]}} = read(config)
    assert c.context["priority"] == "p1"
    {:ok, %{fingerprint: p1}} = read(config)
    assert p1 != p2

    config = config(ctx, %{ctx.repo => ["make other"]})
    {:ok, %{fingerprint: other}} = read(config)
    assert other != p1
  end

  test "a claimed card is not eligible", ctx do
    ref = card(ctx, "claimed work", @ready)
    config = config(ctx, %{ctx.repo => ["make check"]})

    {_, 0} = System.cmd(ctx.planner, ["--actor", "other", "start", ref, "--plan", "other"])

    assert {:ok, %{cards: []}} = read(config)
  end

  test "a closed card is not eligible", ctx do
    ref = card(ctx, "closed work", @ready)
    config = config(ctx, %{ctx.repo => ["make check"]})
    id = String.replace_prefix(ref, "probe:", "")
    ctx.git.(["bug", "bug", "status", "close", id])

    assert {:ok, %{cards: []}} = read(config)
  end

  test "a card without dispatch:ready is not eligible", ctx do
    card(ctx, "not ready", ["kind:task"])
    config = config(ctx, %{ctx.repo => ["make check"]})

    assert {:ok, %{cards: []}} = read(config)
  end

  test "a ready defect card is eligible", ctx do
    ref = card(ctx, "crash on start", ["kind:defect", "dispatch:ready"])
    config = config(ctx, %{ctx.repo => ["make check"]})

    assert {:ok, %{cards: [c]}} = read(config)
    assert c.ref == ref
  end

  test "a card of an unadmitted watched repository is not eligible", ctx do
    card(ctx, "elsewhere", @ready)
    # the repository is watched but not in the admitted map
    config = config(ctx, %{})

    assert {:ok, %{cards: []}} = read(config)
  end

  test "a repository with two admitted checks is not eligible", ctx do
    card(ctx, "ambiguous check", @ready)
    config = config(ctx, %{ctx.repo => ["make check", "make other"]})

    assert {:ok, %{cards: []}} = read(config)
  end

  test "a basename shared by two admitted repositories is never read", ctx do
    card(ctx, "ambiguous name", @ready)
    twin = Path.join(ctx.dir, "twin")
    File.mkdir_p!(Path.join(twin, "probe"))
    File.write!(Path.join(ctx.dir, "repos"), ctx.repo <> "\n" <> twin <> "\n")

    config = config(ctx, %{ctx.repo => ["make check"], (twin <> "/probe") => ["make check"]})
    assert {:ok, %{cards: []}} = read(config)
  end

  test "trailblazer's own repository is never eligible", ctx do
    card(ctx, "self work", @ready)
    config = config(ctx, %{ctx.repo => ["make check"]})

    assert {:ok, %{cards: []}} = read(config, self: ctx.repo)
  end

  test "more than eight ineligible cards do not starve the ready card", ctx do
    # priority:p1 sorts ahead of the ready card's default p2, so the ready
    # card is the last of ten on its repository's board
    for n <- 1..9, do: card(ctx, "waiting #{n}", ["kind:task", "priority:p1"])

    ready = card(ctx, "the ready one", @ready)
    config = config(ctx, %{ctx.repo => ["make check"]})

    assert {:ok, %{cards: [c]}} = read(config)
    assert c.ref == ready
  end

  test "at most eight short card contexts are returned", ctx do
    for n <- 1..10, do: card(ctx, "ready #{n}", @ready)
    config = config(ctx, %{ctx.repo => ["make check"]})

    assert {:ok, %{cards: cards}} = read(config)
    assert length(cards) == 8

    for c <- cards do
      assert c.context["ref"] == c.ref
      assert byte_size(Jason.encode!(c.context)) < 2_000
    end
  end

  test "a show reply larger than the check tail still yields the ready card", ctx do
    # the real CLI caps a body at 1800 and keeps three 900-char comments, so
    # this reply is about 4700 bytes — over Check's 4000-character tail
    ref = card(ctx, "huge card", @ready, String.duplicate("B", 3000))
    id = String.replace_prefix(ref, "probe:", "")

    for _ <- 1..3,
        do:
          ctx.git.([
            "bug",
            "bug",
            "comment",
            "new",
            id,
            "-m",
            String.duplicate("r", 1000),
            "--non-interactive"
          ])

    {raw, 0} = System.cmd(ctx.planner, ["show", ref], stderr_to_stdout: true)
    assert byte_size(raw) > 4000

    config = config(ctx, %{ctx.repo => ["make check"]})

    assert {:ok, %{cards: [c]}} = read(config)
    assert c.ref == ref
    assert byte_size(c.context["body"]) <= 400
    assert length(c.context["recent"]) == 3
    assert Enum.all?(c.context["recent"], &is_binary/1)
  end

  test "routing markers past the 400-character excerpt still reach the route, whole and bounded",
       ctx do
    # a frontier plan is long: its markers start well after the excerpt, and
    # the Acceptance line straddles the cut
    filler = String.duplicate("Context sentence about the defect. ", 10)

    body =
      filler <>
        "\nAcceptance: " <>
        String.duplicate("a", 100) <>
        " passes\nFiles: lib/parser.ex, test/parser_test.exs\nImplementation plan: 1. " <>
        String.duplicate("step ", 100)

    ref = card(ctx, "long planned card", @ready, body)
    config = config(ctx, %{ctx.repo => ["make check"]})

    assert {:ok, %{cards: [c]}} = read(config)
    assert c.ref == ref
    assert c.context["route"] == "trailblazer"
    assert c.context["files"] == ["lib/parser.ex", "test/parser_test.exs"]
    lines = String.split(c.context["body"], "\n")
    assert Enum.count(lines, &String.starts_with?(&1, "Acceptance:")) == 1
    assert ("Acceptance: " <> String.duplicate("a", 100) <> " passes") in lines
    assert Enum.any?(lines, &String.starts_with?(&1, "Implementation plan: 1. step"))
    assert byte_size(c.context["body"]) <= 400 + 3 * 201
  end

  test "a card Trailblazer blocked after a failed case comes back with the reason; others' blocks and released cards as they are",
       ctx do
    cli = fn args ->
      {out, 0} = System.cmd(ctx.planner, args, stderr_to_stdout: true)
      out
    end

    failed = card(ctx, "failed once", @ready)
    cli.(["--actor", "trailblazer", "start", failed, "--plan", "p"])

    cli.([
      "--actor",
      "trailblazer",
      "block",
      failed,
      "2 attempts failed: generation timeout (2)."
    ])

    theirs = card(ctx, "blocked by someone else", @ready)
    cli.(["--actor", "glm", "start", theirs, "--plan", "p"])
    cli.(["--actor", "glm", "block", theirs, "waiting for the operator"])

    released = card(ctx, "released", @ready)
    cli.(["--actor", "glm", "start", released, "--plan", "p"])
    cli.(["--actor", "glm", "release", released, "handing back"])

    config = config(ctx, %{ctx.repo => ["make check"]})
    assert {:ok, %{cards: cards}} = read(config)
    by_ref = Map.new(cards, &{&1.ref, &1})

    assert %{
             "failed" => true,
             "failures" => 1,
             "failure" => "2 attempts failed: generation timeout (2)."
           } =
             by_ref[failed].context

    refute Map.has_key?(by_ref, theirs)
    assert Map.has_key?(by_ref, released)
    refute Map.has_key?(by_ref[released].context, "failed")
  end
end
