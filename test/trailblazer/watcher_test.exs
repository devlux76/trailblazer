defmodule Trailblazer.WatcherTest do
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

  test "one current watcher restarts on membership change and rescans every member", ctx do
    a = member(self())
    b = member(self())
    c = member(self())
    on_exit(fn -> for pid <- [a, b, c], do: Process.exit(pid, :kill) end)
    one = scratch_repo()
    two = scratch_repo()
    one_dir = Path.join(one, ".git")
    two_dir = Path.join(two, ".git")

    assert {:events, nil} = Watcher.add(one, a, ctx.opts, ctx.watcher)
    assert_receive {:started, first, [^one_dir]}
    ref = Process.monitor(first)

    # A second member of the same repository is the same watch.
    assert {:events, nil} = Watcher.add(one, b, ctx.opts, ctx.watcher)
    assert_receive {:DOWN, ^ref, :process, ^first, _}
    assert_receive {:started, second, [^one_dir]}
    assert_receive {:member, ^a, {:watcher_resync, ^second}}
    assert_receive {:member, ^b, {:watcher_resync, ^second}}

    send(ctx.watcher, {:file_event, second, {Path.join(one_dir, "index"), [:modified]}})
    assert_receive {:member, ^a, {:git_state, ^one_dir}}
    assert_receive {:member, ^b, {:git_state, ^one_dir}}

    # Another repository's git directory, and git's other files, are not ours.
    send(ctx.watcher, {:file_event, second, {Path.join(two_dir, "index"), [:modified]}})
    refute_receive {:member, ^a, {:git_state, _}}, 20

    send(ctx.watcher, {:file_event, second, {Path.join(one_dir, "FETCH_HEAD"), [:modified]}})
    refute_receive {:member, ^a, {:git_state, _}}, 20

    assert {:events, nil} = Watcher.add(two, c, ctx.opts, ctx.watcher)
    assert_receive {:started, third, dirs}
    assert Enum.sort(dirs) == Enum.sort([one_dir, two_dir])
    assert_receive {:member, ^a, {:watcher_resync, ^third}}
    assert_receive {:member, ^b, {:watcher_resync, ^third}}
    assert_receive {:member, ^c, {:watcher_resync, ^third}}

    # A late event from the retired generation cannot claim current coverage.
    send(ctx.watcher, {:file_event, second, {Path.join(two_dir, "HEAD"), [:modified]}})
    refute_receive {:member, ^c, {:git_state, _}}, 20

    ref = Process.monitor(third)
    Process.exit(c, :kill)
    assert_receive {:DOWN, ^ref, :process, ^third, _}
    assert_receive {:started, _, [^one_dir]}
  end

  test "the native worker is started with exactly the watched git directories", ctx do
    one = scratch_repo()
    two = scratch_repo()
    a = member(self())
    b = member(self())
    on_exit(fn -> for pid <- [a, b], do: Process.exit(pid, :kill) end)

    assert {:events, nil} = Watcher.add(one, a, ctx.opts, ctx.watcher)
    assert_receive {:started, _, [dir]}
    assert dir == Path.join(one, ".git")

    assert {:events, nil} = Watcher.add(two, b, ctx.opts, ctx.watcher)
    assert_receive {:started, _, dirs}
    assert Enum.sort(dirs) == Enum.sort([Path.join(one, ".git"), Path.join(two, ".git")])
    refute_receive {:started, _, _}, 20
  end

  @tag :host_inotify
  test "a commit tells its member that git state moved; an unstaged edit does not", ctx do
    repo = scratch_repo()
    git_dir = Path.join(repo, ".git")
    # A second repository is this test's barrier: one inotify stream reports
    # events in the order they happened.
    barrier = scratch_repo()
    barrier_dir = Path.join(barrier, ".git")
    barrier_member = member(self())
    on_exit(fn -> Process.exit(barrier_member, :kill) end)

    assert {:starting, nil} = Watcher.add(repo, self(), [], ctx.watcher)
    assert {:starting, nil} = Watcher.add(barrier, barrier_member, [], ctx.watcher)
    assert_receive {:watcher_status, :events, nil}
    assert_receive {:watcher_resync, _}
    assert_receive {:member, ^barrier_member, {:watcher_status, :events, nil}}
    assert_receive {:member, ^barrier_member, {:watcher_resync, _}}

    File.write!(Path.join(repo, "b.txt"), "b\n")
    commit!(repo, "two")
    assert_receive {:git_state, ^git_dir}

    File.write!(Path.join(barrier_dir, "ORIG_HEAD"), "barrier")
    assert_receive {:member, ^barrier_member, {:git_state, ^barrier_dir}}
    # The commit's events are all in the mailbox by now; take what is left of
    # them, so the negative check below cannot fail on one of them.
    take(git_dir)

    File.write!(Path.join(repo, "a.txt"), "edited\n")
    refute_receive {:git_state, _}, 100
  end

  @tag :host_inotify
  test "a linked worktree watches its own git directory", ctx do
    repo = scratch_repo()
    linked = tmp_path("linked")
    git!(repo, ["worktree", "add", "-q", "-b", "side", linked])
    linked_dir = Path.join([repo, ".git", "worktrees", Path.basename(linked)])

    main = member(self())
    side = member(self())
    on_exit(fn -> for pid <- [main, side], do: Process.exit(pid, :kill) end)

    assert {:starting, nil} = Watcher.add(repo, main, [], ctx.watcher)
    assert_receive {:member, ^main, {:watcher_status, :events, nil}}
    assert_receive {:member, ^main, {:watcher_resync, _}}

    assert {:starting, nil} = Watcher.add(linked, side, [], ctx.watcher)
    assert_receive {:member, ^side, {:watcher_status, :events, nil}}
    assert_receive {:member, ^side, {:watcher_resync, _}}

    File.write!(Path.join(linked, "side.txt"), "s\n")
    commit!(linked, "side one")

    assert_receive {:member, ^side, {:git_state, ^linked_dir}}
    # The commit's own refs live in the shared git directory, which nobody's
    # non-recursive watch covers.
    refute_receive {:member, ^main, {:git_state, _}}, 100
  end

  # Shared fate (2026-10-23): a removed linked worktree's git directory stayed
  # in the shared watch list, inotifywait refused to start, and every
  # repository fell back to on-request reconciliation.
  test "a member whose git directory vanished gets no watch; the others keep theirs", ctx do
    repo = scratch_repo()
    other = scratch_repo()
    linked = tmp_path("linked")
    git!(repo, ["worktree", "add", "-q", "-b", "gone", linked])
    [a, b, c] = for _ <- 1..3, do: member(self())
    on_exit(fn -> for pid <- [a, b, c], do: Process.exit(pid, :kill) end)

    assert {:events, nil} = Watcher.add(repo, a, ctx.opts, ctx.watcher)
    assert {:events, nil} = Watcher.add(linked, b, ctx.opts, ctx.watcher)
    git!(repo, ["worktree", "remove", "--force", linked])

    assert {:events, nil} = Watcher.add(other, c, ctx.opts, ctx.watcher)
    expected = Enum.sort([Path.join(repo, ".git"), Path.join(other, ".git")])
    assert_receive {:started, _, ^expected}
  end

  @tag :host_inotify
  test "a git directory that vanishes as the native watcher starts is dropped, not fatal",
       ctx do
    repo = scratch_repo()
    linked = tmp_path("linked")
    git!(repo, ["worktree", "add", "-q", "-b", "racing", linked])
    linked_dir = Path.join([repo, ".git", "worktrees", Path.basename(linked)])

    # The first start with the linked directory loses the race: it goes away
    # under inotifywait, which then refuses every directory.
    {dir, executable} =
      script(fn dir ->
        """
        case " $* " in *' #{linked_dir} '*) [ -e '#{dir}/raced' ] || { touch '#{dir}/raced'; rm -rf '#{linked_dir}'; } ;; esac
        seen=
        for d in "$@"; do
          if [ -n "$seen" ] && [ ! -d "$d" ]; then echo "Couldn't watch $d: No such file or directory" >&2; exit 1; fi
          [ "$d" = -- ] && seen=1
        done
        printf 'Watches established.\\n'
        exec /bin/cat
        """
      end)

    main = member(self())
    side = member(self())
    on_exit(fn -> for pid <- [main, side], do: Process.exit(pid, :kill) end)
    opts = [watcher_executable: executable]

    assert {:starting, nil} = Watcher.add(repo, main, opts, ctx.watcher)
    assert_receive {:member, ^main, {:watcher_status, :events, nil}}
    assert {:starting, nil} = Watcher.add(linked, side, opts, ctx.watcher)
    assert_receive {:member, ^main, {:watcher_status, :events, nil}}, 2000
    assert File.exists?(Path.join(dir, "raced"))
    refute_received {:member, ^main, {:watcher_status, :on_request, _}}
    refute Enum.any?(Trailblazer.Anomaly.list(), &(&1.subject == repo))
  end

  test "a directory that is not a work tree is enrolled with no watch", ctx do
    plain = tmp_path("plain")
    File.mkdir_p!(plain)

    assert {:off, nil} = Watcher.add(plain, self(), ctx.opts, ctx.watcher)
    refute_receive {:started, _, _}, 20
    assert :sys.get_state(ctx.watcher).watcher == nil
    refute Enum.any?(Trailblazer.Anomaly.list(), &(&1.subject == plain))
    refute_receive {:watcher_status, _, _}, 20
  end

  @tag :host_inotify
  test "only git's own state files are routed", ctx do
    repo = scratch_repo()
    git_dir = Path.join(repo, ".git")

    assert {:starting, nil} = Watcher.add(repo, self(), [], ctx.watcher)
    assert_receive {:watcher_status, :events, nil}
    assert_receive {:watcher_resync, _}

    for name <- ["FETCH_HEAD", "COMMIT_EDITMSG", "index.lock"] do
      File.write!(Path.join(git_dir, name), "ignored")
    end

    refute_receive {:git_state, _}, 100
    # A state file in that same directory does arrive: the watch is alive.
    File.write!(Path.join(git_dir, "ORIG_HEAD"), "ignored")
    assert_receive {:git_state, ^git_dir}
  end

  @tag :host_inotify
  test "one kernel watch per repository, not one per directory", ctx do
    one = scratch_repo()
    two = scratch_repo()
    git!(one, ["worktree", "add", "-q", "-b", "side", tmp_path("side")])
    a = member(self())
    b = member(self())
    on_exit(fn -> for pid <- [a, b], do: Process.exit(pid, :kill) end)

    assert {:starting, nil} = Watcher.add(one, a, [], ctx.watcher)
    assert_receive {:member, ^a, {:watcher_status, :events, nil}}
    assert_receive {:member, ^a, {:watcher_resync, _}}

    assert {:starting, nil} = Watcher.add(two, b, [], ctx.watcher)
    assert_receive {:member, ^b, {:watcher_status, :events, nil}}
    assert_receive {:member, ^b, {:watcher_resync, backend}}

    # Two repositories, each with directories under its git directory, cost
    # two kernel watches between them.
    assert length(watches(backend)) == 2
  end

  defp script(body) do
    dir = tmp_path("native")

    File.mkdir_p!(dir)
    path = Path.join(dir, "fake-inotify")
    File.write!(path, "#!/bin/sh\n" <> body.(dir))
    File.chmod!(path, 0o755)
    {dir, path}
  end

  # Takes what the Watcher has already forwarded, so a later refute cannot fail
  # on an event an earlier action caused.
  defp take(git_dir) do
    receive do
      {:git_state, ^git_dir} -> take(git_dir)
    after
      0 -> :ok
    end
  end

  # The inotify watch descriptors the worker holds: one per watched directory.
  defp watches(backend) do
    %{port: port} = :sys.get_state(backend)
    {:os_pid, shell} = Port.info(port, :os_pid)

    native =
      "/proc/#{shell}/task/#{shell}/children"
      |> File.read!()
      |> String.split()
      |> Enum.find(fn pid ->
        case File.read("/proc/#{pid}/comm") do
          {:ok, comm} -> String.trim(comm) == "inotifywait"
          _ -> false
        end
      end)

    assert native, "no inotifywait process under #{inspect(shell)}"

    for path <- Path.wildcard("/proc/#{native}/fdinfo/*"),
        line <- File.read!(path) |> String.split("\n"),
        String.starts_with?(line, "inotify wd:"),
        do: line
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
