defmodule Trailblazer.Planner.PermissionNotifierTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Planner.PermissionNotifier

  setup do
    root = Path.join(System.tmp_dir!(), "permission-notify-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    script = Path.join(root, "route with space.py")
    record = Path.join(root, "observed.json")

    File.write!(script, """
    import json, os, sys
    with open(sys.argv[1], 'w') as f:
        json.dump({'args':sys.argv[3:], 'sentinel':os.environ.get('TB_NOTIFIER_SECRET'), 'fixed':os.environ.get('FIXED_ROUTE')}, f)
    print(sys.argv[2])
    """)

    route = %{
      "executable" => System.find_executable("python3"),
      "args" => [script, record, ~s({"delivery":"steered","turn_id":"turn-test"})],
      "cwd" => root,
      "env" => %{"FIXED_ROUTE" => "constant"},
      "timeout_ms" => 5000
    }

    request = %{
      "id" => "perm-" <> String.duplicate("a", 32),
      "binding" => String.duplicate("b", 64),
      "evidence_sha256" => String.duplicate("c", 64),
      "evidence" => %{"untrusted" => "DO-NOT-INCLUDE-ME"}
    }

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, route: route, request: request, record: record}
  end

  test "literal argv and fixed environment reach the route without interpreting shell text", c do
    marker = Path.join(c.root, "must-not-exist")
    hostile = "$(touch #{marker})\n'\"; # literal"
    route = Map.update!(c.route, "args", &(&1 ++ [hostile]))
    old = System.get_env("TB_NOTIFIER_SECRET")
    System.put_env("TB_NOTIFIER_SECRET", "never-in-child-or-evidence")

    on_exit(fn ->
      if old,
        do: System.put_env("TB_NOTIFIER_SECRET", old),
        else: System.delete_env("TB_NOTIFIER_SECRET")
    end)

    assert {:ok, result} = PermissionNotifier.notify(route, c.request, 0)
    assert result.delivery == :host_admitted
    assert result.turn_id == "turn-test"
    observed = c.record |> File.read!() |> Jason.decode!()
    assert [^hostile, message] = observed["args"]
    assert message =~ c.request["id"]
    assert message =~ c.request["binding"]
    refute message =~ "DO-NOT-INCLUDE-ME"
    assert observed["sentinel"] == nil
    assert observed["fixed"] == "constant"
    refute File.exists?(marker)
  end

  test "queued, malformed and generic success do not claim idle host admission", c do
    for {output, wanted} <- [
          {~s({"delivery":"queued"}), :queued},
          {~s({"delivery":"started","turn_id":"turn-new"}), :host_admitted},
          {~s({"delivery":"started"}), :unknown},
          {~s({"delivery":"delivered"}), :unknown},
          {~s({"ok":true}), :unknown},
          {"not-json", :unknown}
        ] do
      route = Map.put(c.route, "args", Enum.take(c.route["args"], 2) ++ [output])
      assert {:ok, %{delivery: ^wanted}} = PermissionNotifier.notify(route, c.request, 1)
    end
  end

  test "invalid routes and request identifiers refuse before running any command", c do
    for route <- [
          Map.put(c.route, "command", "arbitrary"),
          %{c.route | "executable" => "relative"},
          %{c.route | "timeout_ms" => 0},
          %{c.route | "timeout_ms" => 1.5},
          %{c.route | "env" => %{"BAD=NAME" => "value"}}
        ] do
      assert {:error, :invalid_notifier} = PermissionNotifier.notify(route, c.request, 0)
    end

    assert {:error, :invalid_notification} =
             PermissionNotifier.notify(c.route, %{c.request | "id" => "$(execute)"}, 0)

    assert {:error, :invalid_notification} = PermissionNotifier.notify(c.route, c.request, 2)
    refute File.exists?(c.record)
  end

  test "timeout is unknown delivery and kills the helper's process group", c do
    script = Path.join(c.root, "slow")

    File.write!(
      script,
      "#!/bin/sh\nsleep 60 & child=$!\nprintf '%s' \"$child\" > child.pid\nwait\n"
    )

    File.chmod!(script, 0o755)
    route = %{c.route | "executable" => script, "args" => [], "timeout_ms" => 1000}

    assert {:ok, %{delivery: :unknown, exit: nil}} =
             PermissionNotifier.notify(route, c.request, 0)

    pid = File.read!(Path.join(c.root, "child.pid")) |> String.to_integer()
    assert_dead(pid)
  end

  test "a nonzero helper exit is failure without exposing its output", c do
    script = Path.join(c.root, "fail")
    File.write!(script, "#!/bin/sh\nprintf credential-sentinel\nexit 7\n")
    File.chmod!(script, 0o755)
    route = %{c.route | "executable" => script, "args" => []}
    assert {:ok, result} = PermissionNotifier.notify(route, c.request, 0)
    assert result.delivery == :failure and result.exit == 7
    refute inspect(result) =~ "credential-sentinel"
  end

  defp assert_dead(pid, tries \\ 100)

  defp assert_dead(pid, tries) do
    case File.read("/proc/#{pid}/stat") do
      {:error, :enoent} ->
        :ok

      {:ok, text} ->
        if text =~ ") Z " do
          :ok
        else
          assert tries > 0
          Process.sleep(10)
          assert_dead(pid, tries - 1)
        end
    end
  end
end
