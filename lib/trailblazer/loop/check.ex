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
  @prefix_limit 65_536
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
        result

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
      prefix: "",
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

    prefix =
      if byte_size(s.prefix) < @prefix_limit,
        do: binary_part(s.prefix <> valid, 0, min(byte_size(s.prefix <> valid), @prefix_limit)),
        else: s.prefix

    %{s | tail: String.slice(s.tail <> valid, -@limit, @limit), prefix: prefix, pending: pending}
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
      output_tail: output(status, s.prefix, tail),
      ms: now() - s.started
    }
  end

  @doc false
  # The tail, preceded on failure by the first failure's excerpt when the tail
  # no longer contains it. Never longer than @limit plus the elision marker.
  def output(:pass, _prefix, tail), do: String.slice(tail, -@limit, @limit)

  def output(_status, prefix, tail) do
    tail = String.slice(tail, -@limit, @limit)

    with [{at, _} | _] <- Regex.run(@failure, prefix, return: :index),
         from = max(at - @excerpt_before, 0),
         excerpt =
           prefix
           |> binary_part(from, min(byte_size(prefix) - from, @excerpt_before + @excerpt_after))
           |> valid_text(),
         false <- String.contains?(tail, String.trim(excerpt)) do
      kept = String.slice(tail, -(@limit - String.length(excerpt)), @limit)
      "[first failure]\n" <> excerpt <> "\n[... output elided ...]\n" <> kept
    else
      _ -> tail
    end
  end

  # A byte cut can split a UTF-8 sequence at either end; drop the partial bytes.
  defp valid_text(<<b, rest::binary>>) when b in 0x80..0xBF, do: valid_text(rest)

  defp valid_text(bin) do
    case :unicode.characters_to_binary(bin) do
      text when is_binary(text) -> text
      {_, text, _} -> text
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
