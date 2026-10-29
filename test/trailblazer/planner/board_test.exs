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

    body_ref = card(ctx, "half specified", @ready, "Files: lib/only.ex\nImplementation plan: Extract helper and test its behavior.")
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

  test "assign runs the exact existing command for the admitted check", ctx do
    parent = self()

    run = fn args ->
      send(parent, {:assign_args, args})
      %{status: :pass, output_tail: "{}"}
    end

    info = %{ref: "probe:abc123", check: "make check", repo: ctx.repo, context: %{}}

    assert :ok = Board.assign(config(ctx, %{}), info, run: run)
    assert_receive {:assign_args, args}

    assert args == [
             "--actor",
             "trailblazer",
             "assign",
             "probe:abc123",
             "trailblazer",
             "--check",
             "make check"
           ]

    assert {:error, _} =
             Board.assign(config(ctx, %{}), info,
               run: fn _ -> %{status: :fail, exit: 1, output_tail: "already owned"} end
             )
  end

  describe "load_config!/1" do
    test "parses the admitted map and optional planner entry, canonicalising repositories",
         ctx do
      config = config(ctx, %{ctx.repo => ["make check"]}, %{"planner" => "/bin/echo"})

      {:ok, canonical} = Trailblazer.Files.canonical_path(ctx.repo)
      assert %{^canonical => ["make check"]} = config.repos
      assert config.planner == {"/bin/echo", []}
    end

    test "the planner entry may carry extra arguments", ctx do
      config = config(ctx, %{ctx.repo => ["c"]}, %{"planner" => ["/bin/echo", "--verbose"]})
      assert config.planner == {"/bin/echo", ["--verbose"]}
    end

    test "a missing planner entry defaults to the installed CLI", ctx do
      config = config(ctx, %{ctx.repo => ["c"]}, %{"planner" => nil})
      assert {"/" <> _rest, []} = config.planner
    end

    test "an invalid file is refused", ctx do
      path = Path.join(ctx.dir, "bad.json")

      File.write!(path, Jason.encode!(%{"repos" => %{"relative/path" => ["c"]}}))
      assert_raise ArgumentError, fn -> Board.load_config!(path) end

      File.write!(path, Jason.encode!(%{"repos" => %{"/tmp" => "not-a-list"}}))
      assert_raise ArgumentError, fn -> Board.load_config!(path) end

      File.write!(path, "not json")
      assert_raise ArgumentError, fn -> Board.load_config!(path) end
    end

    test "an optional research entry names the peer, actor and session", ctx do
      config =
        config(ctx, %{ctx.repo => ["c"]}, %{"research" => %{"peer" => "12D3KooTestPeer"}})

      assert config.research == %{
               peer: "12D3KooTestPeer",
               actor: "research",
               session: "trailblazer"
             }

      config =
        config(ctx, %{ctx.repo => ["c"]},
          %{"research" => %{"peer" => "12D3KooTestPeer", "actor" => "probe", "session" => "work"}}
        )

      assert config.research == %{peer: "12D3KooTestPeer", actor: "probe", session: "work"}
      assert config(ctx, %{ctx.repo => ["c"]}).research == nil
    end

    test "an invalid research entry is refused", ctx do
      for research <- [
            %{},
            %{"peer" => 7},
            %{"peer" => "p"},
            %{"peer" => "p", "actor" => 7},
            %{"peer" => "p", "actor" => "ok", "session" => 7},
            %{"peer" => "p", "extra" => true}
          ] do
        path = Path.join(ctx.dir, "bad.json")
        File.write!(path, Jason.encode!(%{"repos" => %{ctx.repo => ["c"]}, "research" => research}))
        assert_raise ArgumentError, ~r/research/, fn -> Board.load_config!(path) end
      end
    end
  end

  test "run/2 executes planner arguments through the injected runner", ctx do
    parent = self()

    assert %{status: :pass} =
             Board.run(config(ctx, %{}), ["show", "probe:abc"],
               run: fn args ->
                 send(parent, {:run_args, args})
                 %{status: :pass}
               end
             )

    assert_receive {:run_args, ["show", "probe:abc"]}
  end

  test "TRAILBLAZER_PLANNER_CONFIG loads the runtime config; unset means disabled", ctx do
    path = Path.join(ctx.dir, "trailblazer.json")
    File.write!(path, Jason.encode!(%{"repos" => %{ctx.repo => ["make check"]}}))

    System.put_env("TRAILBLAZER_PLANNER_CONFIG", path)
    Application.delete_env(:trailblazer, :planner)

    on_exit(fn ->
      System.delete_env("TRAILBLAZER_PLANNER_CONFIG")
      Application.delete_env(:trailblazer, :planner)
    end)

    assert %{repos: repos} = Trailblazer.Config.get(:planner)
    assert map_size(repos) == 1

    System.delete_env("TRAILBLAZER_PLANNER_CONFIG")
    Application.delete_env(:trailblazer, :planner)
    assert Trailblazer.Config.get(:planner) == nil
  end
end
