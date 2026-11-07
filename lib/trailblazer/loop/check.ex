defmodule Trailblazer.Loop.Check do
  @moduledoc """
  A trusted check command in a worktree, in its own process group, with a
  bounded Unicode output tail. The check runs for as long as it takes; its one
  backstop (`opts[:timeout]`, else `backstop_check_ms`, design §13.2) or the
  caller's death kills the whole group. A backstop that fires gives status
  `:timeout` with the anomaly's id; a check that ends as it fires is late and
  the backstop's outcome stands (J4).
  """
  alias Trailblazer.{Backstop, Config}
  @limit 4000
  # A failing run keeps the excerpt around its FIRST failure ahead of the tail:
  # cascading failures otherwise push the root-cause assertion out (bug:9ae2ace).
  @excerpt_before 1_200
  @excerpt_after 1_300
  @failure ~r/(?:^|\n)[ \t]*(?:error:|\(fail\)|✗|FAIL\b|FAILED\b|E {3}|--- FAIL|\d+\) test |thread '.*' panicked|panicked at|AssertionError|Traceback)/u
  # setsid's child identifies its real process group and waits for permission
  # to start. A startup timeout can close stdin without ever running the check.
  @launch ~S(printf '%s %s\n' "$1" "$$"; IFS= read -r go || exit 125; exec sh -c "$2" </dev/null)

  def default(repo) do
    cond do
      File.regular?(Path.join(repo, "mix.exs")) ->
        "mix test"

      File.regular?(Path.join(repo, "bun.lock")) or File.regular?(Path.join(repo, "bun.lockb")) ->
        "bun test"

      npm_test?(repo) ->
        "npm test"

      pytest?(repo) ->
        "pytest"

      File.regular?(Path.join(repo, "Cargo.toml")) ->
        "cargo test"

      File.regular?(Path.join(repo, "go.mod")) ->
        "go test ./..."

      true ->
        nil
    end
  end

  def run(worktree, command, opts \\ [])
  def run(%{path: path}, command, opts), do: run(path, command, opts)

  def run(path, command, opts) do
    limit = Keyword.get(opts, :timeout, Config.get(:backstop_check_ms))
    deadline = Keyword.get(opts, :deadline_at, System.os_time(:millisecond) + limit)
    remaining = min(limit, deadline - System.os_time(:millisecond))

    if remaining <= 0 do
      %{
        status: :timeout,
        exit: nil,
        output_tail: "Verification budget exhausted; command not started.",
        ms: 0
      }
    else
      run_bounded(path, command, Keyword.put(opts, :timeout, remaining))
    end
  end

  defp run_bounded(path, command, opts) do
    caller = self()
    token = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        owner = Process.monitor(caller)
        limit = Keyword.get(opts, :timeout, Config.get(:backstop_check_ms))
        result = execute(path, command, limit, owner)
        send(caller, {:check_result, token, result})
      end)

    receive do
      {:check_result, ^token, result} ->
        Process.demonitor(ref, [:flush])
        Trailblazer.Loop.SilentCheck.annotate(result, path, command)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        %{
          status: :fail,
          exit: nil,
          output_tail: String.slice(inspect(reason), -@limit, @limit),
          ms: 0
        }
    end
  end

  defp execute(path, command, limit, owner) do
    Process.flag(:trap_exit, true)
    started = now()
    marker = "trailblazer-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("setsid")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          {:cd, path},
          {:env, environment()},
          {:args, ["--fork", "--wait", "sh", "-c", @launch, "check", marker, command]}
        ]
      )

    s = %{
      port: port,
      group: nil,
      header: "",
      tail: "",
      pre: "",
      first: nil,
      pending: "",
      marker: marker,
      owner: owner,
      started: started,
      backstop:
        Backstop.arm(:check, command, {:ms, limit}, fn -> %{path: path, command: command} end)
    }

    collect(s)
  rescue
    e ->
      %{
        status: :fail,
        exit: nil,
        output_tail: String.slice(Exception.message(e), -@limit, @limit),
        ms: 0
      }
  end

  # A command that writes without pause keeps Port data ahead of everything
  # else in the mailbox, and one receive takes the first message that matches.
  # The backstop and the caller's death are looked for first, on their own.
  defp collect(s) do
    port = s.port
    owner = s.owner
    backstop = s.backstop

    receive do
      {:backstop, ^backstop, id} -> backstop_fired(s, id)
      {:DOWN, ^owner, :process, _, _} -> owner_down(s)
    after
      0 ->
        receive do
          {^port, {:data, data}} ->
            collect(data(s, data))

          {^port, {:exit_status, code}} ->
            ended(s, if(code == 0, do: :pass, else: :fail), code)

          {:DOWN, ^owner, :process, _, _} ->
            owner_down(s)

          {:EXIT, ^port, _} ->
            ended(s, :fail, nil)

          {:backstop, ^backstop, id} ->
            backstop_fired(s, id)
        end
    end
  end

  defp owner_down(s) do
    stop(s)
    ended(s, :fail, nil)
  end

  defp backstop_fired(s, id) do
    stop(s)
    Map.put(result(s, :timeout, nil), :anomaly, id)
  end

  # J5: the check ended; if its backstop fired in the same moment, the
  # backstop's outcome stands
  defp ended(s, status, code) do
    case Backstop.disarm(s.backstop) do
      :ok ->
        result(s, status, code)

      :fired ->
        backstop = s.backstop

        receive do
          {:backstop, ^backstop, id} ->
            Map.merge(result(s, :timeout, nil), %{anomaly: id, late: status})
        end
    end
  end

  defp data(%{group: nil} = s, data) do
    header = s.header <> data

    case :binary.split(header, "\n") do
      [line, rest] ->
        [marker, pid] = String.split(line, " ")
        true = marker == s.marker
        group = String.to_integer(pid)
        Port.command(s.port, "\n")
        data(%{s | group: group, header: ""}, rest)

      _ ->
        %{s | header: header}
    end
  end

  defp data(s, bytes) do
    {valid, pending} = decode(s.pending <> bytes)

    %{
      s
      | tail: String.slice(s.tail <> valid, -@limit, @limit),
        pending: pending
    }
    |> capture(valid)
  end

  defp decode(bytes) do
    case :unicode.characters_to_binary(bytes) do
      text when is_binary(text) ->
        {text, ""}

      {:incomplete, text, rest} ->
        {text, rest}

      {:error, text, <<_, rest::binary>>} ->
        {after_error, pending} = decode(rest)
        {text <> "�" <> after_error, pending}
    end
  end

  defp stop(s) do
    if s.group, do: System.cmd("kill", ["-KILL", "--", "-#{s.group}"], stderr_to_stdout: true)
    # Close the launcher's pipes too; before the handshake EOF prevents exec.
    if Port.info(s.port), do: Port.close(s.port)
    :ok
  end

  defp result(s, status, code) do
    tail = s.tail <> if(s.pending == "", do: "", else: "�")

    %{
      status: status,
      exit: code,
      output_tail: output(status, first_text(s.first), tail),
      ms: now() - s.started
    }
  end

  # Streams the excerpt around the first failure marker: a rolling window of
  # text before it, then a bounded window after. Every piece is valid text
  # (regex offsets fall on character boundaries), however late the failure.
  defp capture(%{first: {:done, _}} = s, _valid), do: s

  defp capture(%{first: {:open, text, need}} = s, valid) do
    taken = String.slice(valid, 0, need)
    left = need - String.length(taken)
    %{s | first: if(left > 0, do: {:open, text <> taken, left}, else: {:done, text <> taken})}
  end

  defp capture(%{first: nil} = s, valid) do
    seen = s.pre <> valid

    case Regex.run(@failure, seen, return: :index) do
      [{at, _} | _] ->
        before = seen |> binary_part(0, at) |> String.slice(-@excerpt_before, @excerpt_before)
        rest = binary_part(seen, at, byte_size(seen) - at)
        capture(%{s | pre: "", first: {:open, before, @excerpt_after}}, rest)

      nil ->
        %{s | pre: String.slice(seen, -@excerpt_before, @excerpt_before)}
    end
  end

  defp first_text(nil), do: nil
  defp first_text({:done, text}), do: text
  defp first_text({:open, text, _}), do: text

  @doc false
  # The tail, preceded on failure by the first failure's excerpt when the tail
  # no longer contains it. At most @limit characters plus two short labels.
  def output(:pass, _first, tail), do: String.slice(tail, -@limit, @limit)
  def output(_status, nil, tail), do: String.slice(tail, -@limit, @limit)

  def output(_status, first, tail) do
    tail = String.slice(tail, -@limit, @limit)

    if String.contains?(tail, String.trim(first)) do
      tail
    else
      kept = String.slice(tail, -(@limit - String.length(first)), @limit)
      "[first failure]\n" <> first <> "\n[... output elided ...]\n" <> kept
    end
  end

  defp npm_test?(repo) do
    with {:ok, text} <- File.read(Path.join(repo, "package.json")),
         {:ok, %{"scripts" => %{"test" => cmd}}} when is_binary(cmd) and cmd != "" <-
           Jason.decode(text),
         do: true,
         else: (_ -> false)
  end

  defp pytest?(repo) do
    File.regular?(Path.join(repo, "pytest.ini")) or
      Enum.any?(
        [
          {"pyproject.toml", "[tool.pytest.ini_options]"},
          {"setup.cfg", "[tool:pytest]"},
          {"tox.ini", "[pytest]"}
        ],
        fn {file, section} ->
          case File.read(Path.join(repo, file)) do
            {:ok, text} -> String.contains?(text, section)
            _ -> false
          end
        end
      )
  end

  defp environment do
    removed =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(fn key ->
        String.starts_with?(key, ["RELEASE_", "ERL_"]) or
          key in ~w(ROOTDIR BINDIR EMU PROGNAME MIX_ENV)
      end)

    Enum.map(removed, &{String.to_charlist(&1), false}) ++
      [{~c"PATH", String.to_charlist(Config.get(:check_path))}]
  end

  defp now, do: System.monotonic_time(:millisecond)
end
