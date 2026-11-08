defmodule Trailblazer.Planner.BoardRetryTest do
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

  defp read(config, opts \\ []) do
    Board.read(config, Keyword.put_new(opts, :self, "/nonexistent"))
  end

  test "a failed card is offered back once, after fresh work of its priority", ctx do
    blocked = fn ref, assignments ->
      %{
        "ref" => ref,
        "column" => "blocked",
        "title" => ref,
        "labels" => @ready,
        "body" => "b",
        "recent" => [],
        "assignments" => assignments,
        "claim" => %{
          "actor" => "trailblazer",
          "state" => "blocked",
          "notes" => [%{"n" => 3, "action" => "block", "text" => "timeout"}]
        }
      }
    end

    shows = %{
      "probe:fresh1" => %{
        "ref" => "probe:fresh1",
        "column" => "todo",
        "title" => "fresh",
        "labels" => @ready,
        "body" => "b",
        "recent" => [],
        "claim" => nil
      },
      "probe:aaaa01" => blocked.("probe:aaaa01", 1),
      "probe:aaaa02" => blocked.("probe:aaaa02", 2)
    }

    run = fn
      ["board", "--repo", "probe", "--column", "todo" | _] ->
        %{status: :pass, output_tail: Jason.encode!(%{"cards" => [["probe:fresh1", nil, "p2"]]})}

      ["board", "--repo", "probe", "--column", "blocked" | _] ->
        rows = [["probe:aaaa01", "trailblazer", "p2"], ["probe:aaaa02", "trailblazer", "p2"]]
        %{status: :pass, output_tail: Jason.encode!(%{"cards" => rows})}

      ["show", ref] ->
        %{status: :pass, output_tail: Jason.encode!(shows[ref])}
    end

    config = config(ctx, %{ctx.repo => ["make check"]})
    assert {:ok, %{cards: cards}} = read(config, run: run)
    # the twice-assigned card stays blocked; the once-failed one follows fresh work
    assert Enum.map(cards, & &1.ref) == ["probe:fresh1", "probe:aaaa01"]
    assert %{"failed" => true, "failures" => 1, "failure" => "timeout"} = List.last(cards).context
  end

  test "a failed card released but not assigned is blocked again with its reason", ctx do
    parent = self()

    run = fn
      ["--actor", "trailblazer", "assign" | _] ->
        %{status: :fail, exit: 1, output_tail: "trailblazer already has active work"}

      args ->
        send(parent, {:ran, args})
        %{status: :pass, output_tail: "{}"}
    end

    card = %{
      ref: "probe:abc123",
      check: "make check",
      repo: ctx.repo,
      context: %{"failed" => true, "failure" => "2 attempts failed"}
    }

    assert {:error, {:planner, "trailblazer already has active work"}} =
             Board.assign(config(ctx, %{}), card, run: run)

    assert_receive {:ran, ["--actor", "trailblazer", "release", "probe:abc123", _]}

    assert_receive {:ran,
                    ["--actor", "trailblazer", "block", "probe:abc123", "2 attempts failed"]}
  end

  test "assigning a failed card releases Trailblazer's block first", ctx do
    parent = self()

    run = fn args ->
      send(parent, {:ran, args})
      %{status: :pass, output_tail: "{}"}
    end

    card = %{
      ref: "probe:abc123",
      check: "make check",
      repo: ctx.repo,
      context: %{"failed" => true, "failure" => "timeout"}
    }

    assert :ok = Board.assign(config(ctx, %{}), card, run: run)
    assert_receive {:ran, ["--actor", "trailblazer", "release", "probe:abc123", _]}
    assert_receive {:ran, ["--actor", "trailblazer", "assign", "probe:abc123" | _]}

    refusing = fn
      ["--actor", "trailblazer", "release" | _] -> %{status: :fail, exit: 1, output_tail: "no"}
      _ -> flunk("must not assign when the release failed")
    end

    assert {:error, {:planner, "no"}} = Board.assign(config(ctx, %{}), card, run: refusing)
  end

  test "a garbage or failing planner reply is an error, not a card", ctx do
    config = config(ctx, %{ctx.repo => ["make check"]})

    assert {:error, {:planner, "not json"}} =
             read(config, run: fn _args -> %{status: :pass, output_tail: "not json"} end)

    assert {:error, {:planner, _}} =
             read(config, run: fn _args -> %{status: :fail, exit: 2, output_tail: "boom"} end)
  end

  test "a failing board read of one repository stops the whole read", ctx do
    twin = Path.join(ctx.dir, "twin")
    File.mkdir_p!(twin)
    File.write!(Path.join(ctx.dir, "repos"), ctx.repo <> "\n" <> twin <> "\n")

    config = config(ctx, %{ctx.repo => ["make check"], twin => ["make check"]})

    # "twin" is not a repository the planner knows: its board read fails
    assert {:error, {:planner, _}} = read(config)
  end
end
