defmodule Trailblazer.Planner.BoardConfigTest do
  # Board eligibility over the real planner CLI and a real temporary git-bug
  # repository: only an unclaimed todo card labelled dispatch:ready of an
  # admitted repository with exactly one admitted check, never Trailblazer
  # itself, is a candidate — a ready defect card is as eligible as a ready
  # task. The CLI runs through a wrapper that keeps the watched repositories
  # and planner state in a temporary directory, so nothing here touches live
  # state. Every repository's board is read separately, before any limit.
  use ExUnit.Case, async: false
  alias Trailblazer.Planner.Board

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

    # the card's Files: go along, one --file each, in order
    filed = %{info | context: %{"files" => ["lib/parser.ex", "test/parser_test.exs"]}}
    assert :ok = Board.assign(config(ctx, %{}), filed, run: run)
    assert_receive {:assign_args, filed_args}

    assert Enum.take(filed_args, -2) == ["--file=lib/parser.ex", "--file=test/parser_test.exs"]
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
        config(ctx, %{ctx.repo => ["c"]}, %{
          "research" => %{"peer" => "12D3KooTestPeer", "actor" => "probe", "session" => "work"}
        })

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

        File.write!(
          path,
          Jason.encode!(%{"repos" => %{ctx.repo => ["c"]}, "research" => research})
        )

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

  test "explicit settings load reads planner config; reloading an unset path disables it", ctx do
    previous = Application.get_env(:trailblazer, :runtime_settings)
    path = Path.join(ctx.dir, "trailblazer.json")
    File.write!(path, Jason.encode!(%{"repos" => %{ctx.repo => ["make check"]}}))

    System.put_env("TRAILBLAZER_PLANNER_CONFIG", path)
    Application.delete_env(:trailblazer, :planner)

    on_exit(fn ->
      System.delete_env("TRAILBLAZER_PLANNER_CONFIG")
      Application.delete_env(:trailblazer, :planner)

      if previous,
        do: Application.put_env(:trailblazer, :runtime_settings, previous),
        else: Application.delete_env(:trailblazer, :runtime_settings)
    end)

    assert :ok = Trailblazer.Config.load_runtime_settings()
    assert %{repos: repos} = Trailblazer.Config.get(:planner)
    assert map_size(repos) == 1

    System.delete_env("TRAILBLAZER_PLANNER_CONFIG")
    Application.delete_env(:trailblazer, :planner)
    assert :ok = Trailblazer.Config.load_runtime_settings()
    assert Trailblazer.Config.get(:planner) == nil
  end
end
