defmodule Trailblazer.Loop.CheckTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Loop.Check

  setup do
    root = Path.join(System.tmp_dir!(), "trailblazer-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "default commands follow project files and npm needs a test script", %{root: root} do
    assert Check.default(root) == nil
    File.write!(Path.join(root, "package.json"), ~s({"scripts":{"build":"x"}}))
    assert Check.default(root) == nil
    File.write!(Path.join(root, "package.json"), ~s({"scripts":{"test":"x"}}))
    assert Check.default(root) == "npm test"
    File.write!(Path.join(root, "bun.lock"), "")
    assert Check.default(root) == "bun test"
    File.write!(Path.join(root, "mix.exs"), "")
    assert Check.default(root) == "mix test"
  end

  test "runs trusted shell command in its own directory with stderr and exit code", %{root: root} do
    assert %{status: :pass, exit: 0, output_tail: out, ms: ms} =
             Check.run(root, "pwd; printf 'error' >&2", [])

    assert out =~ root
    assert out =~ "error"
    assert ms >= 0
    assert %{status: :fail, exit: 7} = Check.run(root, "exit 7", [])
  end

  test "large output is bounded to the last 4000 characters, including Unicode", %{root: root} do
    File.write!(Path.join(root, "output"), String.duplicate("🙂", 50_000) <> "END")
    assert %{status: :pass, output_tail: tail} = Check.run(root, "cat output", [])
    assert String.valid?(tail)
    assert String.length(tail) == 4000
    assert String.ends_with?(tail, "END")
  end

  test "timeout kills the process group including background children", %{root: root} do
    result =
      Check.run(root, "sleep 60 & child=$!; printf '%s' \"$child\" > child.pid; wait",
        timeout: 2000
      )

    assert result.status == :timeout
    assert result.exit == nil
    # B4: the timeout is the check's backstop, and its firing is an anomaly
    assert is_integer(result.anomaly)
    pid = File.read!(Path.join(root, "child.pid")) |> String.to_integer()
    # A dead process may briefly remain a zombie until the system reaps it.
    eventually(fn ->
      case File.read("/proc/#{pid}/stat") do
        {:error, :enoent} -> true
        {:ok, text} -> text =~ ") Z "
      end
    end)
  end

  test "continuous output cannot starve the timeout", %{root: root} do
    task = Task.async(fn -> Check.run(root, "yes x", timeout: 1000) end)
    result = Task.yield(task, 4000) || Task.shutdown(task, :brutal_kill)
    assert {:ok, %{status: :timeout, output_tail: tail}} = result
    assert tail != ""
    assert String.length(tail) <= 4000
  end

  test "check environment removes release/runtime flags and uses the configured tool PATH", %{
    root: root
  } do
    keys = ~w(RELEASE_TRAILBLAZER_TEST ROOTDIR BINDIR EMU PROGNAME MIX_ENV ERL_TRAILBLAZER_TEST)
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    prior_path = Application.fetch_env(:trailblazer, :check_path)

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      case prior_path do
        {:ok, value} -> Application.put_env(:trailblazer, :check_path, value)
        :error -> Application.delete_env(:trailblazer, :check_path)
      end
    end)

    for key <- keys, do: System.put_env(key, "drop-this-test-value")
    bin = Path.join(root, "tools")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "check-tool"), "#!/bin/sh\nprintf tool-ok\n")
    File.chmod!(Path.join(bin, "check-tool"), 0o755)
    path = bin <> ":/usr/bin:/bin"
    Application.put_env(:trailblazer, :check_path, path)

    command = ~S"""
    printf '%s\n' "$PATH"; check-tool; printf '\n'; env | grep -Ec '^(RELEASE_|ERL_|ROOTDIR=|BINDIR=|EMU=|PROGNAME=|MIX_ENV=)' || true
    """

    assert %{status: :pass, output_tail: output} = Check.run(root, command, [])
    assert output == path <> "\ntool-ok\n0\n"
  end

  test "caller death also kills a running check", %{root: root} do
    caller =
      spawn(fn ->
        Check.run(root, "sleep 60 & child=$!; printf '%s' \"$child\" > caller-child.pid; wait",
          timeout: 60_000
        )
      end)

    pid_file = Path.join(root, "caller-child.pid")
    eventually(fn -> File.exists?(pid_file) end)
    pid = File.read!(pid_file) |> String.to_integer()
    Process.exit(caller, :kill)

    eventually(fn ->
      case File.read("/proc/#{pid}/stat") do
        {:error, :enoent} -> true
        {:ok, text} -> text =~ ") Z "
      end
    end)
  end

  test "invalid output bytes are repaired and Python/Rust/Go defaults are detected", %{root: root} do
    File.write!(Path.join(root, "bytes"), <<255, 65>>)
    assert %{status: :pass, output_tail: "�A"} = Check.run(root, "cat bytes", [])

    for {file, text, cmd} <- [
          {"pyproject.toml", "[tool.pytest.ini_options]", "pytest"},
          {"Cargo.toml", "", "cargo test"},
          {"go.mod", "", "go test ./..."}
        ] do
      File.write!(Path.join(root, file), text)
      assert Check.default(root) == cmd
      File.rm!(Path.join(root, file))
    end
  end

  # The one wait in the tests on something that sends no message: the kernel
  # reaping a killed process, a shell writing a file (design §13.2, rule 8).
  defp eventually(fun, left \\ 500)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, left) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, left - 1)
        )
  end

  test "an expired shared deadline never starts another command", %{root: root} do
    result =
      Check.run(root, "touch should-not-exist",
        timeout: 1000,
        deadline_at: System.os_time(:millisecond) - 1
      )

    assert result.status == :timeout
    refute File.exists?(Path.join(root, "should-not-exist"))
  end

  test "commands share an absolute deadline rather than renewing their allowance", %{root: root} do
    deadline = System.os_time(:millisecond) + 300
    assert Check.run(root, "sleep 0.15", timeout: 1000, deadline_at: deadline).status == :pass

    result =
      Check.run(root, "sleep 1; touch should-not-exist", timeout: 1000, deadline_at: deadline)

    assert result.status == :timeout
    refute File.exists?(Path.join(root, "should-not-exist"))
  end
end
