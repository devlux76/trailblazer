defmodule Trailblazer.WatcherNativeTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Watcher

  setup do
    parent = self()

    start = fn dirs ->
      pid = spawn(fn -> receive do: (:done -> :ok) end)
      send(parent, {:started, pid, dirs})
      {:ok, pid}
    end

    opts = [start_watcher: start, subscribe_watcher: fn _ -> :ok end]
    watcher = start_supervised!({Watcher, name: nil})
    %{watcher: watcher, opts: opts}
  end

  defp member(parent) do
    spawn(fn -> relay(parent) end)
  end

  defp relay(parent) do
    receive do
      message ->
        send(parent, {:member, self(), message})
        relay(parent)
    end
  end

  test "failed startup and a stopped backend are observable", ctx do
    parent = self()
    broken = scratch_repo()
    failure = Keyword.put(ctx.opts, :start_watcher, fn _ -> {:error, :too_many_open_files} end)
    assert {:on_request, reason} = Watcher.add(broken, self(), failure, ctx.watcher)
    assert reason =~ "too_many_open_files"
    assert_receive {:watcher_status, :on_request, ^reason}
    assert Enum.any?(Trailblazer.Anomaly.list(), &(&1.subject == broken))
    working = scratch_repo()
    assert {:events, nil} = Watcher.add(working, parent, ctx.opts, ctx.watcher)
    assert_receive {:started, pid, _}
    send(ctx.watcher, {:file_event, pid, :stop})
    assert_receive {:watcher_status, :on_request, stopped}
    assert stopped =~ "stopped"
  end

  defp script(body) do
    dir = tmp_path("native")

    File.mkdir_p!(dir)
    path = Path.join(dir, "fake-inotify")
    File.write!(path, "#!/bin/sh\n" <> body.(dir))
    File.chmod!(path, 0o755)
    {dir, path}
  end

  test "native readiness closes the startup gap before rescanning", ctx do
    repo = scratch_repo()
    git_dir = Path.join(repo, ".git")

    {dir, executable} =
      script(fn dir ->
        "IFS= read -r ready < '#{dir}/gate'\nprintf 'Watches established.\\n'\nexec /bin/cat < '#{dir}/events'\n"
      end)

    {_, 0} = System.cmd("mkfifo", [Path.join(dir, "gate"), Path.join(dir, "events")])

    assert {:starting, nil} =
             Watcher.add(repo, self(), [watcher_executable: executable], ctx.watcher)

    refute_receive {:watcher_resync, _}, 20
    File.write!(Path.join(dir, "gate"), "ready\n")
    assert_receive {:watcher_status, :events, nil}
    assert_receive {:watcher_resync, backend}

    File.write!(
      Path.join(dir, "events"),
      git_dir <>
        "/" <>
        <<1>> <>
        "MODIFY" <>
        <<1>> <>
        "index\n" <>
        <<1>> <> "Q_OVERFLOW" <> <<1>> <> "\n"
    )

    assert_receive {:git_state, ^git_dir}
    assert_receive {:watcher_resync, ^backend}
    assert_receive {:watcher_status, :on_request, _}
  end

  test "native startup stderr explains why live updates are off", ctx do
    Trailblazer.Events.subscribe(:anomaly)
    repo = scratch_repo()

    {_, executable} =
      script(fn _ -> "echo 'Could not initialize inotify: Too many open files' >&2\nexit 1\n" end)

    assert {:starting, nil} =
             Watcher.add(repo, self(), [watcher_executable: executable], ctx.watcher)

    assert_receive {:watcher_status, :on_request, reason}
    assert reason =~ "Too many open files"

    assert_receive {:trailblazer_event, :anomaly,
                    %{subject: subject, evidence: %{capacity: capacity}}}

    assert subject == repo
    assert capacity.max_user_watches > 0
    assert capacity.max_user_instances > 0
    assert capacity.requested_directories == 1
  end

  test "subscribe failure closes the newly started worker", ctx do
    opts = Keyword.put(ctx.opts, :subscribe_watcher, fn _ -> exit(:subscribe_failed) end)
    assert {:on_request, reason} = Watcher.add(scratch_repo(), self(), opts, ctx.watcher)
    assert reason =~ "subscribe_failed"
    assert_receive {:started, pid, _}
    refute Process.alive?(pid)
  end

  test "native reconfiguration waits for the previous child to exit", ctx do
    {dir, executable} =
      script(fn dir ->
        "echo $$ > '#{dir}/child'\nprintf 'Watches established.\\n'\nexec /bin/cat < '#{dir}/events'\n"
      end)

    {_, 0} = System.cmd("mkfifo", [Path.join(dir, "events")])

    assert {:starting, nil} =
             Watcher.add(scratch_repo(), self(), [watcher_executable: executable], ctx.watcher)

    assert_receive {:watcher_status, :events, nil}
    child = File.read!(Path.join(dir, "child")) |> String.trim()
    # The replacement fake worker starts only after the OS child is reaped.
    parent = self()

    opts =
      Keyword.put(ctx.opts, :start_watcher, fn _ ->
        send(parent, {:previous_child_alive, File.exists?("/proc/#{child}")})
        {:error, :replacement_marker}
      end)

    assert {:on_request, _} =
             Watcher.add(scratch_repo(), self(), opts, ctx.watcher)

    assert_receive {:previous_child_alive, false}
  end

  test "missing native readiness fires one startup backstop and degrades visibly", ctx do
    previous = Application.fetch_env(:trailblazer, :backstop_watcher_ms)
    Application.put_env(:trailblazer, :backstop_watcher_ms, 100)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:trailblazer, :backstop_watcher_ms, value)
        :error -> Application.delete_env(:trailblazer, :backstop_watcher_ms)
      end
    end)

    {dir, executable} = script(fn dir -> "IFS= read -r never < '#{dir}/gate'\n" end)
    {_, 0} = System.cmd("mkfifo", [Path.join(dir, "gate")])
    repo = scratch_repo()

    assert {:starting, nil} =
             Watcher.add(repo, self(), [watcher_executable: executable], ctx.watcher)

    assert_receive {:watcher_status, :on_request, reason}, 5000
    assert reason =~ "startup_backstop"

    assert Enum.any?(
             Trailblazer.Anomaly.list(),
             &(&1.kind == "watcher_start" and &1.subject =~ repo)
           )
  end

  test "queued additions replace the native watch list once", ctx do
    a = member(self())
    b = member(self())
    on_exit(fn -> for pid <- [a, b], do: Process.exit(pid, :kill) end)
    one = scratch_repo()
    two = scratch_repo()
    :sys.suspend(ctx.watcher)
    first = :gen_server.send_request(ctx.watcher, {:add, one, a, ctx.opts})
    second = :gen_server.send_request(ctx.watcher, {:add, two, b, ctx.opts})
    :sys.resume(ctx.watcher)
    assert {:reply, {:events, nil}} = :gen_server.wait_response(first, :infinity)
    assert {:reply, {:events, nil}} = :gen_server.wait_response(second, :infinity)
    assert_receive {:started, _, dirs}
    assert Enum.sort(dirs) == Enum.sort([Path.join(one, ".git"), Path.join(two, ".git")])
    refute_receive {:started, _, _}, 20
  end

  test "a malformed native record after readiness requests a rescan", ctx do
    repo = scratch_repo()

    {dir, executable} =
      script(fn dir ->
        "printf 'Watches established.\\n'\nexec /bin/cat < '#{dir}/events'\n"
      end)

    {_, 0} = System.cmd("mkfifo", [Path.join(dir, "events")])

    assert {:starting, nil} =
             Watcher.add(repo, self(), [watcher_executable: executable], ctx.watcher)

    assert_receive {:watcher_status, :events, nil}
    assert_receive {:watcher_resync, backend}
    File.write!(Path.join(dir, "events"), "truncated newline filename\n")
    assert_receive {:watcher_resync, ^backend}
  end

  defp scratch_repo() do
    repo = tmp_path("repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "a.txt"), "a\n")
    commit!(repo, "one")
    repo
  end

  defp tmp_path(kind) do
    path =
      Path.join(
        System.tmp_dir!(),
        "trailblazer-watch-#{kind}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp commit!(dir, message) do
    git!(dir, ["add", "-A"])
    git!(dir, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message])
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
