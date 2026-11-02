# `mix test` runs against a temporary state directory of this run's own
# (config/config.exs), so nothing here reads or writes the real one. Live tests,
# which need the embedder and Qdrant, are left out by default.
# Wait for events with room for a loaded host to schedule their producers;
# the default 100 ms failed on correct parallel worktree/case-event paths.
#
# Tests tagged :host_inotify start the real inotifywait. When this host cannot
# give it an instance (the user's inotify instances are all in use, or
# inotifywait is missing) they are left out with a notice instead of timing out.
host_inotify? =
  case System.find_executable("inotifywait") do
    nil ->
      false

    exe ->
      probe = Path.join(System.tmp_dir!(), "trailblazer-inotify-probe-#{System.pid()}")
      File.mkdir_p!(probe)

      try do
        # -t 1 with no events exits 2; a failed setup exits 1.
        {_out, status} = System.cmd(exe, ["-q", "-t", "1", probe], stderr_to_stdout: true)
        status in [0, 2]
      after
        File.rm_rf!(probe)
      end
  end

unless host_inotify? do
  IO.puts("test_helper: no inotify instance available; excluding :host_inotify tests")
end

ExUnit.start(
  exclude: [:live, :vortex_integration] ++ if(host_inotify?, do: [], else: [:host_inotify]),
  capture_log: true,
  assert_receive_timeout: 5000
)

# unique_integer is VM-local: parallel worktrees must not share fixture paths.
suite_tmp =
  Path.join(System.tmp_dir!(), "trailblazer-suite-#{System.pid()}-#{System.os_time(:nanosecond)}")

File.mkdir_p!(suite_tmp)
System.put_env("TMPDIR", suite_tmp)
ExUnit.after_suite(fn _ -> File.rm_rf!(suite_tmp) end)

# Every run leaves its state directory behind. Remove the ones older than a day,
# which no run in flight can be using, and never this run's.
current = Path.expand(Trailblazer.Config.get(:state_dir))
cutoff = System.os_time(:second) - 86_400

Path.join(Path.dirname(current), "trailblazer_test_*")
|> Path.wildcard()
|> Enum.reject(&(&1 == current))
|> Enum.filter(fn path ->
  case File.stat(path, time: :posix) do
    {:ok, %File.Stat{mtime: mtime}} -> mtime < cutoff
    {:error, _reason} -> false
  end
end)
|> Enum.each(&File.rm_rf!/1)
