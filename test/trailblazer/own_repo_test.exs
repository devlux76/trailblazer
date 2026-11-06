defmodule Trailblazer.OwnRepoTest do
  use ExUnit.Case, async: false
  import Plug.Test
  alias Trailblazer.{API, Indexer, Store}
  alias Trailblazer.Loop.{Workspace, Runner, CaseRecord}

  setup do
    dir = Path.join(System.tmp_dir!(), "trailblazer-own-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    clone = Path.join(dir, "clone")

    {_, 0} =
      System.cmd(
        "git",
        ["clone", "--quiet", "--no-checkout", "--no-hardlinks", File.cwd!(), clone],
        stderr_to_stdout: true
      )

    alias_path = Path.join(dir, "alias")
    File.ln_s!(clone, alias_path)

    on_exit(fn ->
      paths = [clone, File.cwd!(), Path.expand("test/fixtures/mini")]

      for repo <- paths do
        if pid = Indexer.whereis(repo), do: GenServer.stop(pid)
        # collections are keyed by the suite's own state dir: never prod's
        Trailblazer.Vectors.drop(repo)
      end

      for %{id: id, path: path} <- Store.watched_repos(),
          path in paths,
          do: Store.set_watched(id, false)

      File.rm_rf!(dir)
    end)

    %{clone: clone, alias_path: alias_path}
  end

  test "identity covers worktrees, subdirectories, clones and aliases", ctx do
    assert Workspace.own_repo?(File.cwd!())
    assert Workspace.own_repo?(Path.expand("test/fixtures/mini"))
    assert Workspace.own_repo?(ctx.clone)
    assert Workspace.own_repo?(ctx.alias_path)
    refute Workspace.own_repo?(System.tmp_dir!())
  end

  test "identity survives a history rewrite: an unrelated root with our mix.exs is refused" do
    dir = Path.join(System.tmp_dir!(), "tb-rewrite-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      File.cp!("mix.exs", Path.join(dir, "mix.exs"))

      git = fn args ->
        {_, 0} = System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args, cd: dir)
      end

      git.(["init", "-q"])
      git.(["add", "mix.exs"])
      git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "new root"])
      assert Workspace.own_repo?(dir)
      assert {:error, :own_repo} = Workspace.open(dir, "rewrite-case")
    after
      File.rm_rf!(dir)
    end
  end

  test "run is refused before a case, preparation or worker exists", ctx do
    parent = self()

    runner =
      start_supervised!(
        {Runner,
         name: nil,
         prepare: fn _ ->
           send(parent, :prepared)
           :ok
         end,
         run: fn _, _ -> send(parent, :ran) end}
      )

    opts = API.init(token: "test", runner: runner)
    before_cases = CaseRecord.open_cases()

    for repo <- [File.cwd!(), Path.expand("test/fixtures/mini"), ctx.clone, ctx.alias_path] do
      assert {:error, :own_repo} = Runner.submit(%{repo: repo, request: "change"}, runner)
      response = request(opts, "run", %{repo: repo, request: "change"})
      assert response.status == 400

      assert Jason.decode!(response.resp_body) == %{
               "error" => "Trailblazer does not work on its own repository"
             }
    end

    assert CaseRecord.open_cases() == before_cases
    refute_received :prepared
    refute_received :ran
  end

  test "own roots may be watched, so a fix to Trailblazer has its graph (G5)", ctx do
    # Empty fake listings keep the test from indexing real source.
    opts = [filesystem: false, embedding: :paused, list_files: fn _ -> [] end]

    for repo <- [File.cwd!(), ctx.clone] do
      assert {:ok, _} = Indexer.watch(repo, opts)
      assert Indexer.watched?(repo)
    end

    fixture = Path.expand("test/fixtures/mini")
    assert {:ok, _} = Indexer.watch(fixture, opts)
    api = API.init(token: "test", indexer_opts: opts)
    assert request(api, "watch", %{repo: ctx.alias_path}).status == 200
  end

  defp request(opts, operation, body) do
    conn(:post, "/" <> operation, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer test")
    |> API.call(opts)
  end
end
