defmodule Trailblazer.Vortex.IntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :vortex_integration
  @moduletag timeout: 60_000
  alias Trailblazer.Vortex.{Bridge, Protocol, Store, Transport}
  alias Trailblazer.Loop.{Runner, CaseRecord}
  alias Trailblazer.Loop

  defmodule Script do
    def chat(_, _) do
      [next | rest] = Process.get(:vortex_script)
      Process.put(:vortex_script, rest)

      if next == :hang do
        send(Process.get(:vortex_parent), {:model_waiting, self()})
        receive do: (:never -> :ok)
      end

      {:ok,
       %{
         content: next,
         reasoning: "",
         tool_calls: [],
         usage: %{prompt_tokens: 1, completion_tokens: 1},
         ms: 0,
         finish_reason: "stop"
       }}
    end
  end

  @fix """
  Repair the greeting.
  lib/greeting.ex
  ```elixir
  <<<<<<< SEARCH
    def hello(name), do: "Hello " <> name
  =======
    def hello(name), do: "Hello, " <> name
  >>>>>>> REPLACE
  ```
  """

  test "real VORTEX, SQLite and Loop: deferred intake, success, three failures and frontier claim" do
    root = Path.join(System.tmp_dir!(), "vortex-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    Trailblazer.CaseStore.transaction(fn conn ->
      for table <- ~w(vortex_outbox vortex_request) do
        Exqlite.query!(conn, "DELETE FROM #{table}", [], timeout: :infinity)
      end
    end)

    caller = service(root, "caller")
    app = service(root, "app")
    frontier = service(root, "frontier")
    caller_room = pair(caller, app)
    frontier_room = pair(frontier, app)
    repo = Path.join(root, "repo")
    File.mkdir_p!(Path.join(repo, "lib"))
    File.mkdir_p!(Path.join(repo, "test"))
    original = "defmodule Greeting do\n  def hello(name), do: \"Hello \" <> name\nend\n"
    File.write!(Path.join(repo, "lib/greeting.ex"), original)

    File.write!(
      Path.join(repo, "test/greeting_test.exs"),
      "ExUnit.start()\nCode.require_file(\"lib/greeting.ex\")\ndefmodule GreetingTest do\n  use ExUnit.Case\n  test \"comma\", do: assert(Greeting.hello(\"Ada\") == \"Hello, Ada\")\nend\n"
    )

    git(repo, ["init", "-q", "-b", "main"])
    git(repo, ["add", "."])
    git(repo, ["-c", "user.name=test", "-c", "user.email=test@test", "commit", "-qm", "fixture"])
    check = "elixir test/greeting_test.exs"

    peers = %{
      caller.peer => %{room: caller_room, role: :caller, repos: %{repo => [check]}},
      frontier.peer => %{room: frontier_room, role: :frontier, repos: %{}}
    }

    parent = self()

    run = fn task, opts ->
      Process.put(:vortex_parent, parent)

      Process.put(
        :vortex_script,
        case task.request do
          "fail" -> ["no blocks", "no blocks", "no blocks"]
          "interrupt" -> [:hang]
          _ -> [@fix, "PASS"]
        end
      )

      report =
        Loop.run(
          task,
          Keyword.merge(opts,
            model: Script,
            trail: fn _, _, _ -> %{text: "fixture trail", notes: []} end,
            gate: false
          )
        )

      send(parent, {:report, report})
      report
    end

    runner = start_supervised!({Runner, name: nil, prepare: fn _ -> :ok end, run: run})
    {:ok, grant} = Agent.start_link(fn -> false end)

    resource =
      {fn id -> if Agent.get(grant, & &1), do: {:ok, id}, else: :blocked end,
       fn id ->
         send(parent, {:released, id})
         :ok
       end}

    opts = [
      name: nil,
      peers: peers,
      endpoint: app.endpoint,
      owner_peer: app.peer,
      runner: runner,
      resource: resource
    ]

    bridge = start_supervised!({Bridge, opts})
    send_task(caller, caller_room, "success", repo, check)
    wait_message(app)
    assert :ok = Bridge.pump(bridge)
    accepted = receive_type(caller, "accepted")
    id = accepted["payload"]["case"]
    assert Store.get(id).state == "waiting_resource"
    refute_received {:report, _}
    wait_resource(bridge)
    # Request acknowledgment and waiting state survive an application bridge restart.
    stop_supervised!(Bridge)
    bridge = start_supervised!({Bridge, opts}, id: :restored_bridge)
    assert :ok = Bridge.pump(bridge)
    assert Store.get(id).state == "waiting_resource"
    wait_resource(bridge)
    # Duplicate real transport delivery creates the same durable case.
    send_task(caller, caller_room, "success", repo, check)
    wait_message(app)
    :ok = Bridge.pump(bridge)
    assert Enum.count(Store.ids(), &(&1 == id)) == 1
    Agent.update(grant, fn _ -> true end)
    :ok = Bridge.pump(bridge)
    assert_receive {:report, %{status: :fixed, attempts: 1, case: ^id}}, 15_000
    assert_receive {:released, lease}, 5000
    assert String.starts_with?(lease, id <> ":")
    :ok = Bridge.pump(bridge)
    report = receive_type(caller, "report")
    assert report["payload"]["status"] == "fixed"

    send_envelope(
      caller,
      caller_room,
      Protocol.envelope("receipt", "receipt-success", "success", %{"message_id" => report["id"]})
    )

    wait_message(app)
    :ok = Bridge.pump(bridge)
    refute Enum.any?(Store.outbox(), &(&1.id == report["id"]))
    assert File.read!(Path.join(repo, "lib/greeting.ex")) == original
    assert git(repo, ["branch", "--show-current"]) == "main\n"

    send_task(caller, caller_room, "fail", repo, check)
    wait_message(app)
    :ok = Bridge.pump(bridge)
    assert_receive {:report, %{status: :failed, attempts: 3, case: failed}}, 15_000
    assert_receive {:released, failed_lease}, 5000
    assert String.starts_with?(failed_lease, failed <> ":")
    :ok = Bridge.pump(bridge)
    escalation = receive_type(frontier, "escalation")
    assert escalation["payload"]["case"] == failed
    assert escalation["payload"]["attempts"] == 3
    assert escalation["payload"]["dossier"] =~ "3"
    assert escalation["payload"]["trail"] == "fixture trail"

    send_envelope(
      frontier,
      frontier_room,
      Protocol.envelope("receipt", "receipt-fail", "fail", %{"message_id" => escalation["id"]})
    )

    wait_message(app)
    :ok = Bridge.pump(bridge)
    assert Store.get(failed).state == "waiting_frontier"

    send_envelope(
      frontier,
      frontier_room,
      Protocol.envelope("claim", "claim-fail", "fail", %{"case" => failed})
    )

    wait_message(app)
    :ok = Bridge.pump(bridge)
    assert Store.get(failed).state == "claimed"
    acknowledgment = receive_type(frontier, "receipt")
    assert acknowledgment["payload"]["message_id"] == "claim-fail"
    # No fourth call and no automatic modification of the caller's checkout.
    refute_received {:report, _}
    assert File.read!(Path.join(repo, "lib/greeting.ex")) == original
    assert length(Enum.filter(CaseRecord.get(failed).events, &(&1.kind == "reply"))) == 3
    assert Store.holds() == []

    # Stop a genuinely running Loop while its scripted model is blocked.
    # Recovery keeps the trail and escalates; it never replays the attempt.
    send_task(caller, caller_room, "interrupt", repo, check)
    wait_message(app)
    :ok = Bridge.pump(bridge)
    assert_receive {:model_waiting, worker}, 5000
    interrupted = Bridge.status(bridge).active
    ref = Process.monitor(worker)
    stop_supervised!(:restored_bridge)
    stop_supervised!(Runner)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}

    recovered_runner =
      start_supervised!({Runner, name: nil, recover: true}, id: :recovered_runner)

    fenced =
      {fn _ -> flunk("interrupted case must not replay") end,
       fn _ -> {:error, :unconfirmed_residency} end}

    recovered_opts =
      opts |> Keyword.put(:runner, recovered_runner) |> Keyword.put(:resource, fenced)

    recovered = start_supervised!({Bridge, recovered_opts}, id: :interrupted_bridge)
    :ok = Bridge.pump(recovered)
    assert Bridge.status(recovered).resource_release_blocked
    assert Store.get(interrupted).state == "waiting_frontier"
    record = CaseRecord.get(interrupted)
    assert record.status == "failed"
    assert Enum.any?(record.events, &(&1.kind == "attempt" and &1.data["stage"] == "trail"))
    assert receive_type(frontier, "escalation")["payload"]["case"] == interrupted
    [[^interrupted, interrupted_lease]] = Store.holds()
    assert String.starts_with?(interrupted_lease, interrupted <> ":")
    refute_received {:model_waiting, _}
  end

  defp wait_resource(bridge, remaining \\ 500) do
    if :sys.get_state(bridge).resource_busy do
      if remaining == 0, do: flunk("resource operation did not finish")
      Process.sleep(10)
      wait_resource(bridge, remaining - 1)
    end
  end

  defp service(root, name) do
    bun = System.find_executable("bun") || raise "bun required for VORTEX integration"
    cli = Path.join(System.user_home!(), "projects/vortex/src/cli.ts")
    dir = Path.join(root, name)

    port =
      Port.open({:spawn_executable, bun}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 65_536},
        args: [cli, "serve", "--dir", dir, "--name", name, "--port", "0"]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      case File.read("/proc/#{os_pid}/cmdline") do
        {:ok, command} ->
          if String.contains?(command, dir),
            do: System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

        _ ->
          :ok
      end

      if Port.info(port), do: Port.close(port)
    end)

    ready(port)
    endpoint = Path.join(dir, "endpoint.json")
    {:ok, info} = Transport.call(endpoint, "info", %{})
    %{endpoint: endpoint, peer: info["peerId"], addr: hd(info["addrs"])}
  end

  defp ready(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"event" => "ready"}} -> :ok
          _ -> ready(port)
        end

      {^port, {:exit_status, status}} ->
        flunk("VORTEX fixture exited #{status}")
    after
      10_000 -> flunk("VORTEX fixture did not start")
    end
  end

  defp pair(caller, app) do
    {:ok, _} = Transport.call(caller.endpoint, "dial", %{"peer" => app.addr})
    {:ok, %{"room" => room}} = Transport.call(caller.endpoint, "invite", %{"peer" => app.peer})
    wait_message(app)
    {:ok, _} = Transport.call(app.endpoint, "accept", %{"room" => room})
    wait_message(caller)

    for service <- [caller, app] do
      {:ok, page} = Transport.call(service.endpoint, "read", %{})
      {:ok, _} = Transport.call(service.endpoint, "ack", %{"cursor" => page["cursor"]})
    end

    room
  end

  defp send_task(caller, room, request, repo, check),
    do:
      send_envelope(
        caller,
        room,
        Protocol.envelope("task", "task-#{request}", request, %{
          "repo" => repo,
          "request" => request,
          "check" => check,
          "files" => ["lib/greeting.ex"],
          "design" => []
        })
      )

  defp send_envelope(service, room, envelope) do
    {:ok, text} = Protocol.encode(envelope, "fixture caller")
    {:ok, _} = Transport.call(service.endpoint, "send", %{"room" => room, "text" => text})
  end

  defp wait_message(service) do
    assert {:ok, _} = Transport.call(service.endpoint, "wait", %{"timeout" => 5})
  end

  defp receive_type(service, type) do
    wait_message(service)
    {:ok, page} = Transport.call(service.endpoint, "read", %{})

    found =
      Enum.find_value(page["events"], fn event ->
        with %{"kind" => "message", "body" => body} <- event,
             {:ok, %{"type" => ^type} = message} <- Protocol.decode(body),
             do: message,
             else: (_ -> nil)
      end)

    {:ok, _} = Transport.call(service.endpoint, "ack", %{"cursor" => page["cursor"]})
    if found, do: found, else: receive_type(service, type)
  end

  defp git(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    output
  end
end
