defmodule Trailblazer.Watcher.Inotify do
  @moduledoc """
  Inotify worker with an explicit native-ready event and captured stderr.
  Starting a BEAM worker does not prove inotify installed its watches. Begin
  only after subscription; report readiness after `Watches established.` and
  retain startup diagnostics if the child exits. Closing the Port's stdin
  stops its child even when there are no filesystem events.

  The watches are non-recursive and cost one kernel watch each (design §13.7,
  J26): the directories are repositories' git directories, and git's writes of
  `index`, `HEAD` and friends land directly in them.
  """
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, timeout: :infinity)

  @impl true
  def init(opts) do
    if executable = opts[:executable] || System.find_executable("inotifywait") do
      send(opts[:owner], {:watcher_backend, self(), self()})

      {:ok,
       %{
         opts: Keyword.put(opts, :executable, executable),
         port: nil,
         ready: false,
         stopping: false,
         diagnostics: "",
         partial: ""
       }}
    else
      {:stop, :inotifywait_missing}
    end
  end

  @impl true
  def handle_info(:shutdown, %{port: nil} = s), do: {:stop, :normal, s}

  def handle_info(:shutdown, s) do
    Port.command(s.port, "\n")
    {:noreply, %{s | stopping: true}}
  end

  def handle_info(:begin, %{port: nil} = s) do
    executable = s.opts[:executable] || System.find_executable("inotifywait")
    # fd 3 preserves stdin for the guard: background shell jobs otherwise get
    # /dev/null. The main shell waits for child exit; the guard waits for EOF.
    script =
      "exec 3<&0; \"$0\" \"$@\" & child=$!; (read -r ignored <&3; kill -KILL \"$child\" 2>/dev/null) & guard=$!; wait \"$child\"; result=$?; kill \"$guard\" 2>/dev/null; wait \"$guard\" 2>/dev/null; exit \"$result\""

    args =
      [
        "-c",
        script,
        executable,
        "-m",
        "--format",
        "%w" <> <<1>> <> "%e" <> <<1>> <> "%f",
        "-e",
        "close_write,moved_to,create,delete",
        "--"
      ] ++ s.opts[:dirs]

    port =
      Port.open(
        {:spawn_executable, ~c"/bin/sh"},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, 16_384},
          env: [{~c"LC_ALL", ~c"C"}],
          args: args
        ]
      )

    {:noreply, %{s | port: port}}
  end

  def handle_info({port, {:data, {kind, text}}}, %{port: port} = s) do
    text = s.partial <> text

    if kind == :noeol do
      {:noreply, %{s | partial: text}}
    else
      {:noreply, line(text, %{s | partial: ""})}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = s) do
    unless s.stopping do
      reason = %{exit: code, diagnostic: s.diagnostics, ready: s.ready}

      reason =
        if capacity_failure?(s.diagnostics),
          do: Map.put(reason, :capacity, capacity(s.opts[:dirs])),
          else: reason

      emit(s, {:error, reason})
    end

    {:stop, :normal, s}
  end

  defp line("Watches established.", %{ready: false} = s) do
    emit(s, :ready)
    %{s | ready: true}
  end

  defp line(text, s) do
    case String.split(text, <<1>>) do
      [dir, flags, name] ->
        flags = String.split(flags, ",")

        if "Q_OVERFLOW" in flags,
          do: emit(s, :overflow),
          else: emit(s, {Path.join(dir, name), Enum.map(flags, &flag/1)})

        s

      _ ->
        # A newline or separator in a filename can split a native record.
        # Readiness diagnostics are useful; lost records require a rescan.
        if s.ready, do: emit(s, :overflow)
        diagnostic = s.diagnostics <> text <> "\n"

        %{
          s
          | diagnostics: String.slice(diagnostic, max(String.length(diagnostic) - 2000, 0), 2000)
        }
    end
  end

  # One non-recursive watch per git directory (design §13.7): a commit, checkout,
  # add, reset or branch switch rewrites a file directly in it.
  defp capacity_failure?(diagnostic),
    do:
      Enum.any?(
        ["No space left", "upper limit", "Too many open files"],
        &String.contains?(diagnostic, &1)
      )

  defp capacity(dirs) do
    %{
      max_user_watches: kernel_limit("max_user_watches"),
      max_user_instances: kernel_limit("max_user_instances"),
      requested_directories: length(dirs)
    }
  end

  defp kernel_limit(name) do
    case File.read("/proc/sys/fs/inotify/" <> name) do
      {:ok, text} -> String.trim(text) |> String.to_integer()
      _ -> nil
    end
  end

  defp flag("CREATE"), do: :created
  defp flag("DELETE"), do: :deleted
  defp flag("MOVED_TO"), do: :moved_to
  defp flag("MOVED_FROM"), do: :moved_from
  defp flag("ISDIR"), do: :isdir
  defp flag("ATTRIB"), do: :attribute
  defp flag(_), do: :modified
  defp emit(s, event), do: send(s.opts[:owner], {:file_event, self(), event})
end
