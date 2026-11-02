defmodule Trailblazer.Vortex.BridgeTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Vortex.{Bridge, Protocol, Store}
  alias Trailblazer.Loop.{CaseRecord, Runner}

  setup do
    Trailblazer.CaseStore.transaction(fn conn ->
      for table <- ~w(vortex_outbox vortex_request) do
        Exqlite.query!(conn, "DELETE FROM #{table}", [], timeout: :infinity)
      end
    end)

    request = "bridge-#{System.unique_integer([:positive])}"
    {:ok, page} = Agent.start_link(fn -> %{events: [], cursor: 0} end)
    parent = self()

    transport = fn op, args ->
      case op do
        "read" ->
          {:ok, Agent.get(page, & &1)}

        "ack" ->
          send(parent, {:acked, args["cursor"]})
          {:ok, %{}}

        "send" ->
          send(parent, {:sent, args})
          {:ok, %{"sent" => true}}
      end
    end

    peers = %{
      "caller" => %{room: "room", role: :caller, repos: %{"/tmp" => ["true"]}},
      "frontier" => %{room: "frontier-room", role: :frontier, repos: %{}}
    }

    %{request: request, page: page, transport: transport, peers: peers}
  end

  defp event(ctx, id \\ "message-1") do
    body =
      Protocol.envelope("task", id, ctx.request, %{
        "repo" => "/tmp",
        "request" => "fix",
        "check" => "true"
      })
      |> Jason.encode!()

    %{"kind" => "message", "peer" => "caller", "room" => "room", "body" => body, "cursor" => 1}
  end

  test "intake stays model-free until ownership is available, and duplicate delivery opens no second case",
       ctx do
    Agent.update(ctx.page, fn _ -> %{events: [event(ctx)], cursor: 1} end)

    runner =
      start_supervised!(
        {Runner,
         name: nil, prepare: fn _ -> :ok end, run: fn _, _ -> flunk("must not execute") end}
      )

    bridge =
      start_supervised!(
        {Bridge, name: nil, peers: ctx.peers, transport: ctx.transport, runner: runner}
      )

    assert :ok = Bridge.pump(bridge)
    assert_receive {:acked, 1}
    assert_receive {:sent, %{"text" => body}}
    assert {:ok, accepted} = Protocol.decode(body)
    id = accepted["payload"]["case"]
    assert Store.get(id).state == "waiting_resource"
    assert CaseRecord.get(id).status == "open"
    assert :ok = Bridge.pump(bridge)
    assert Store.get(id).case_id == id
    stop_supervised!(Bridge)

    recovered =
      start_supervised!(
        {Bridge, name: nil, peers: ctx.peers, transport: ctx.transport, runner: runner},
        id: :recovered_bridge
      )

    assert :ok = Bridge.pump(recovered)
    assert Store.get(id).state == "waiting_resource"
  end

  test "a granted serial case produces a retained report even while recipient is unavailable",
       ctx do
    Agent.update(ctx.page, fn _ -> %{events: [event(ctx)], cursor: 1} end)
    parent = self()

    run = fn _, opts ->
      id = opts[:case_id]
      send(parent, {:running, id})
      CaseRecord.close(id, %{case: id, status: :fixed, attempts: 1, summary: "fixed"})
    end

    runner = start_supervised!({Runner, name: nil, prepare: fn _ -> :ok end, run: run})

    resource =
      {fn id -> {:ok, id} end,
       fn lease ->
         send(parent, {:released, lease})
         :ok
       end}

    bridge =
      start_supervised!(
        {Bridge,
         name: nil, peers: ctx.peers, transport: ctx.transport, runner: runner, resource: resource}
      )

    assert :ok = Bridge.pump(bridge)
    assert_receive {:running, id}
    assert_receive {:released, lease}
    assert String.starts_with?(lease, id <> ":")
    assert Store.get(id).state == "complete"
    assert Enum.any?(Store.outbox(), &(&1.case_id == id and &1.type == "report"))
  end

  test "a confirmed resource release publishes a planner wake", ctx do
    Agent.update(ctx.page, fn _ -> %{events: [event(ctx)], cursor: 1} end)
    parent = self()
    Trailblazer.Events.subscribe(:planner)

    run = fn _, opts ->
      id = opts[:case_id]
      CaseRecord.close(id, %{case: id, status: :fixed, attempts: 1, summary: "fixed"})
    end

    runner = start_supervised!({Runner, name: nil, prepare: fn _ -> :ok end, run: run})

    resource =
      {fn id -> {:ok, id} end,
       fn lease ->
         send(parent, {:released, lease})
         :ok
       end}

    bridge =
      start_supervised!(
        {Bridge,
         name: nil, peers: ctx.peers, transport: ctx.transport, runner: runner, resource: resource}
      )

    assert :ok = Bridge.pump(bridge)
    assert_receive {:released, lease}
    assert_receive {:trailblazer_event, :planner, {:resource_released, id}}
    assert String.starts_with?(lease, id <> ":")
  end

  test "admission still answers while the model worker is busy", ctx do
    parent = self()

    run = fn _, opts ->
      send(parent, {:worker, self(), opts[:case_id]})

      receive do: (:finish ->
                     CaseRecord.close(opts[:case_id], %{status: :fixed, summary: "done"}))
    end

    runner = start_supervised!({Runner, name: nil, prepare: fn _ -> :ok end, run: run})
    resource = {fn id -> {:ok, id} end, fn _ -> :ok end}
    Agent.update(ctx.page, fn _ -> %{events: [event(ctx)], cursor: 1} end)

    bridge =
      start_supervised!(
        {Bridge,
         name: nil, peers: ctx.peers, transport: ctx.transport, runner: runner, resource: resource}
      )

    :ok = Bridge.pump(bridge)
    assert_receive {:worker, worker, first}

    second =
      event(%{ctx | request: ctx.request <> "-second"}, "message-2") |> Map.put("cursor", 2)

    Agent.update(ctx.page, fn _ -> %{events: [second], cursor: 2} end)
    :ok = Bridge.pump(bridge)
    assert_receive {:acked, 2}
    assert Bridge.status(bridge).active == first

    assert Enum.any?(
             Bridge.status(bridge).requests,
             &(&1.case_id != first and &1.state == "waiting_resource")
           )

    send(worker, :finish)
  end

  test "restart preserves waiting cases and fences an unconfirmed resident model", ctx do
    {:ok, id, _} =
      Store.admit("caller", "room", ctx.request, %{
        repo: "/tmp",
        request: "fix",
        check: "true",
        files: [],
        design: [],
        from: "vortex:caller"
      })

    runner = start_supervised!({Runner, name: nil, recover: true})
    assert CaseRecord.get(id).status == "open"
    :ok = Store.state(id, "running", "old-residency-lease")
    stop_supervised!(Runner)
    start_supervised!({Runner, name: nil, recover: true}, id: :recovered_runner)
    assert CaseRecord.get(id).status == "failed"
    parent = self()

    resource =
      {fn _ ->
         send(parent, :acquired)
         {:ok, "new"}
       end, fn _ -> {:error, :still_resident} end}

    bridge =
      start_supervised!(
        {Bridge,
         name: nil, peers: ctx.peers, transport: ctx.transport, runner: runner, resource: resource}
      )

    :ok = Bridge.pump(bridge)
    assert Bridge.status(bridge).resource_release_blocked
    refute_received :acquired
    assert Store.holds() == [[id, "old-residency-lease"]]
  end

  # trailblazer:ebd0381 (catastrophic): a boot-time release that raced the
  # router's start was parked in blocked_release forever, fencing all dispatch.
  test "a blocked release is retried until it is confirmed, then dispatch resumes", ctx do
    {:ok, id, _} =
      Store.admit("caller", "room", ctx.request, %{
        repo: "/tmp",
        request: "fix",
        check: "true",
        files: [],
        design: [],
        from: "vortex:caller"
      })

    runner = start_supervised!({Runner, name: nil, recover: true})
    :ok = Store.state(id, "running", "old-residency-lease")
    stop_supervised!(Runner)
    start_supervised!({Runner, name: nil, recover: true}, id: :recovered_runner)
    assert CaseRecord.get(id).status == "failed"
    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    release = fn lease ->
      n = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
      send(parent, {:release_attempt, n, lease})
      if n == 1, do: {:error, :router_not_ready}, else: :ok
    end

    bridge =
      start_supervised!(
        {Bridge,
         name: nil,
         peers: ctx.peers,
         transport: ctx.transport,
         runner: runner,
         resource: {fn _ -> :blocked end, release},
         release_retry_ms: 20}
      )

    assert_receive {:release_attempt, 1, "old-residency-lease"}
    assert_receive {:release_attempt, 2, "old-residency-lease"}, 2_000

    eventually = fn eventually, n ->
      cond do
        not Bridge.status(bridge).resource_release_blocked -> :ok
        n == 0 -> flunk("release stayed blocked")
        true -> Process.sleep(20) && eventually.(eventually, n - 1)
      end
    end

    eventually.(eventually, 100)
    assert Store.holds() == []
  end

  test "a release that keeps failing stays fenced and keeps retrying with backoff", ctx do
    {:ok, id, _} =
      Store.admit("caller", "room", ctx.request, %{
        repo: "/tmp",
        request: "fix",
        check: "true",
        files: [],
        design: [],
        from: "vortex:caller"
      })

    runner = start_supervised!({Runner, name: nil, recover: true})
    :ok = Store.state(id, "running", "old-residency-lease")
    stop_supervised!(Runner)
    start_supervised!({Runner, name: nil, recover: true}, id: :recovered_runner)
    parent = self()

    release = fn _lease ->
      send(parent, :release_attempt)
      {:error, :still_resident}
    end

    bridge =
      start_supervised!(
        {Bridge,
         name: nil,
         peers: ctx.peers,
         transport: ctx.transport,
         runner: runner,
         resource:
           {fn _ ->
              send(parent, :acquired)
              :blocked
            end, release},
         release_retry_ms: 10,
         release_retry_max_ms: 40}
      )

    for _ <- 1..4, do: assert_receive(:release_attempt, 2_000)
    assert Bridge.status(bridge).resource_release_blocked
    refute_received :acquired
    assert Store.holds() == [[id, "old-residency-lease"]]
  end

  test "the caller can cancel a durable waiting request without running a model", ctx do
    Agent.update(ctx.page, fn _ -> %{events: [event(ctx)], cursor: 1} end)
    bridge = start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: ctx.transport})
    :ok = Bridge.pump(bridge)
    assert_receive {:sent, %{"text" => text}}
    {:ok, accepted} = Protocol.decode(text)
    id = accepted["payload"]["case"]
    cancel = Protocol.envelope("cancel", "cancel-1", ctx.request, %{"case" => id})

    Agent.update(ctx.page, fn _ ->
      %{
        events: [
          %{
            "kind" => "message",
            "peer" => "caller",
            "room" => "room",
            "body" => Jason.encode!(cancel),
            "cursor" => 2
          }
        ],
        cursor: 2
      }
    end)

    :ok = Bridge.pump(bridge)
    assert CaseRecord.get(id).status == "cancelled"
    assert Store.get(id).state == "complete"
    assert Store.holds() == []
  end

  test "a stalled outgoing transport cannot block intake or status", ctx do
    parent = self()

    transport = fn op, args ->
      if op == "send" do
        send(parent, {:stalled_sender, self()})
        receive do: (:resume -> {:ok, %{}})
      else
        ctx.transport.(op, args)
      end
    end

    Agent.update(ctx.page, fn _ -> %{events: [event(ctx)], cursor: 1} end)
    bridge = start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: transport})
    pump = Task.async(fn -> Bridge.pump(bridge) end)
    assert_receive {:stalled_sender, sender}
    assert Task.yield(pump, 100) == {:ok, :ok}
    assert GenServer.call(bridge, :status, 100).active == nil
    second = event(%{ctx | request: ctx.request <> "-next"}, "next") |> Map.put("cursor", 2)
    Agent.update(ctx.page, fn _ -> %{events: [second], cursor: 2} end)
    assert :ok = GenServer.call(bridge, :pump, 100)
    assert_receive {:acked, 2}
    assert length(Bridge.status(bridge).requests) == 2
    send(sender, :resume)
  end

  test "a transport timeout remains inspectable without recursively escalating through itself",
       ctx do
    parent = self()

    transport = fn op, args ->
      if op == "send" do
        send(parent, :delivery_attempt)

        Trailblazer.Backstop.guard(:vortex, "send", {:ms, 1}, fn -> %{} end, fn ->
          receive do: (:never -> :ok)
        end)
      else
        ctx.transport.(op, args)
      end
    end

    Agent.update(ctx.page, fn _ -> %{events: [event(ctx)], cursor: 1} end)
    bridge = start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: transport})
    pump = Task.async(fn -> Bridge.pump(bridge) end)
    assert_receive :delivery_attempt
    assert Task.yield(pump, 1000) == {:ok, :ok}
    refute_receive :delivery_attempt, 100
    assert Enum.any?(Trailblazer.Anomaly.list(open: true), &(&1.kind == "vortex"))
    assert Enum.any?(Store.outbox(), &(&1.type == "accepted"))

    refute Enum.any?(Store.outbox(), fn m ->
             m.case_id |> String.starts_with?("anomaly-")
           end)
  end

  test "lost cursor acknowledgment replays admission without opening a second case", ctx do
    Agent.update(ctx.page, fn _ -> %{events: [event(ctx)], cursor: 1} end)

    transport = fn op, args ->
      if op == "ack", do: {:error, :disconnected}, else: ctx.transport.(op, args)
    end

    bridge = start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: transport})
    assert {:error, :disconnected} = Bridge.pump(bridge)
    [id] = Store.ids()
    stop_supervised!(Bridge)

    recovered =
      start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: ctx.transport},
        id: :recovered
      )

    assert :ok = Bridge.pump(recovered)
    assert Store.ids() == [id]
    assert CaseRecord.get(id).status == "open"
  end

  test "returned fix rejects wrong request correlation and survives a bridge restart", ctx do
    task = %{
      repo: "/tmp",
      request: "fix",
      check: "true",
      files: [],
      design: [],
      from: "vortex:caller"
    }

    {:ok, id, _} = Store.admit("caller", "room", ctx.request, task)
    :ok = CaseRecord.close(id, %{status: :failed, attempts: 3})
    :ok = Store.finish(id, {"frontier", "frontier-room"})
    :ok = Store.claim("frontier", id)

    fix = %{
      "case" => id,
      "base" => String.duplicate("a", 40),
      "commit" => String.duplicate("b", 40)
    }

    message = Protocol.envelope("returned_fix", "return-1", "wrong-request", fix)

    incoming = fn message, cursor ->
      %{
        "kind" => "message",
        "peer" => "frontier",
        "room" => "frontier-room",
        "body" => Jason.encode!(message),
        "cursor" => cursor
      }
    end

    Agent.update(ctx.page, fn _ -> %{events: [incoming.(message, 1)], cursor: 1} end)
    bridge = start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: ctx.transport})
    :ok = Bridge.pump(bridge)
    assert Store.get(id).state == "claimed"
    message = %{message | "request_id" => ctx.request}
    Agent.update(ctx.page, fn _ -> %{events: [incoming.(message, 2)], cursor: 2} end)
    :ok = Bridge.pump(bridge)
    stop_supervised!(Bridge)

    recovered =
      start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: ctx.transport},
        id: :recovered
      )

    :ok = Bridge.pump(recovered)
    assert Enum.find(Bridge.status(recovered).requests, &(&1.case_id == id)).returned_fix == fix
    assert Store.get(id).state == "waiting_verification"
    assert length(Enum.filter(Store.outbox(), &(&1.type == "receipt"))) <= 1
  end

  # A transport whose "attach" is a line the test holds open and closes.
  defp line_transport(ctx) do
    parent = self()

    fn
      "attach", %{"notify" => notify} ->
        send(parent, {:line, self(), notify})

        receive do
          :close -> {:ok, :closed}
        end

      op, args ->
        if op == "read", do: send(parent, :read)
        ctx.transport.(op, args)
    end
  end

  test "an open attach line admits mail per notice, with no timed wait or ring", ctx do
    bridge =
      start_supervised!(
        {Bridge, name: nil, peers: ctx.peers, transport: line_transport(ctx), listen: true}
      )

    assert_receive {:line, _line, notify}, 100
    assert Bridge.status(bridge).active == nil
    Agent.update(ctx.page, fn _ -> %{events: [event(ctx)], cursor: 1} end)
    send(notify, {:vortex_notice, 1})
    assert_receive {:acked, 1}
    assert [id] = Store.ids()
    assert Store.get(id).state == "waiting_resource"
    # The line stays open across the read: no second line, no wait.
    refute_receive {:line, _, _}, 50
  end

  test "a notice during a read is read after the ack, not dropped", ctx do
    gate = self()
    line = line_transport(ctx)

    transport = fn
      "read", args ->
        send(gate, {:reading, self()})

        receive do
          :go -> line.("read", args)
        end

      op, args ->
        line.(op, args)
    end

    start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: transport, listen: true})
    assert_receive {:line, _, notify}, 100
    send(notify, {:vortex_notice, 1})
    assert_receive {:reading, first}
    send(notify, {:vortex_notice, 2})
    send(first, :go)
    assert_receive {:reading, second}, 200
    send(second, :go)
  end

  test "a closed line is reopened by the next pump (the ring), not by a clock", ctx do
    bridge =
      start_supervised!(
        {Bridge, name: nil, peers: ctx.peers, transport: line_transport(ctx), listen: true}
      )

    assert_receive {:line, line, _}, 100
    send(line, :close)
    refute_receive {:line, _, _}, 100
    assert :ok = Bridge.pump(bridge)
    assert_receive {:line, _, _}, 100
  end

  test "production state keeps no local closures, so it survives hot loads", ctx do
    bridge =
      start_supervised!(
        {Bridge, name: nil, peers: ctx.peers, endpoint: "/nonexistent/endpoint.json"}
      )

    state = :sys.get_state(bridge)
    assert {:endpoint, "/nonexistent/endpoint.json", nil} = state.transport
    {grant, release} = state.resource
    assert Function.info(grant, :type) == {:type, :external}
    assert Function.info(release, :type) == {:type, :external}
  end

  test "bridge restart cleans a durable grant acquired before async delivery", ctx do
    Agent.update(ctx.page, fn _ -> %{events: [event(ctx)], cursor: 1} end)
    parent = self()

    resource =
      {fn lease ->
         send(parent, {:acquiring, self(), lease})

         receive do
           :continue -> {:ok, lease}
         end
       end,
       fn lease ->
         send(parent, {:cleanup, lease})
         :ok
       end}

    runner =
      start_supervised!(
        {Runner,
         name: nil,
         prepare: fn _ -> :ok end,
         run: fn _, _ -> flunk("orphan grant must not run") end}
      )

    bridge =
      start_supervised!(
        {Bridge,
         name: nil, peers: ctx.peers, transport: ctx.transport, runner: runner, resource: resource}
      )

    :ok = Bridge.pump(bridge)
    assert_receive {:acquiring, _, lease}
    [[id, ^lease]] = Store.holds()
    stop_supervised!(Bridge)

    start_supervised!(
      {Bridge,
       name: nil, peers: ctx.peers, transport: ctx.transport, runner: runner, resource: resource}
    )

    assert_receive {:cleanup, ^lease}
    assert CaseRecord.get(id).status == "failed"
  end

  test "late grant after cancellation retains failed cleanup across restart", ctx do
    Agent.update(ctx.page, fn _ -> %{events: [event(ctx)], cursor: 1} end)
    parent = self()

    resource =
      {fn lease ->
         send(parent, {:acquiring, self(), lease})

         receive do
           :continue -> {:ok, lease}
         end
       end,
       fn lease ->
         send(parent, {:cleanup_failed, lease})
         {:error, :busy}
       end}

    runner =
      start_supervised!(
        {Runner,
         name: nil,
         prepare: fn _ -> :ok end,
         run: fn _, _ -> flunk("cancelled case must not run") end}
      )

    bridge =
      start_supervised!(
        {Bridge,
         name: nil, peers: ctx.peers, transport: ctx.transport, runner: runner, resource: resource}
      )

    :ok = Bridge.pump(bridge)
    assert_receive {:acquiring, worker, lease}
    [[id, ^lease]] = Store.holds()
    CaseRecord.close(id, %{case: id, status: :cancelled, summary: "cancelled"})
    send(worker, :continue)
    assert_receive {:cleanup_failed, ^lease}
    assert Store.holds() == [[id, lease]]
    stop_supervised!(Bridge)

    recovered =
      {fn _ -> :blocked end,
       fn value ->
         send(parent, {:cleanup_ok, value})
         :ok
       end}

    start_supervised!(
      {Bridge,
       name: nil, peers: ctx.peers, transport: ctx.transport, runner: runner, resource: recovered}
    )

    assert_receive {:cleanup_ok, ^lease}
    assert CaseRecord.get(id).status == "cancelled"
  end

  test "failed acquire reply keeps reservation until verified cleanup", ctx do
    Agent.update(ctx.page, fn _ -> %{events: [event(ctx)], cursor: 1} end)
    parent = self()

    resource =
      {fn _ -> exit(:lost_grant_reply) end,
       fn lease ->
         send(parent, {:cleanup_failed, lease})
         {:error, :unknown}
       end}

    bridge =
      start_supervised!(
        {Bridge, name: nil, peers: ctx.peers, transport: ctx.transport, resource: resource}
      )

    :ok = Bridge.pump(bridge)
    assert_receive {:cleanup_failed, lease}
    assert [[id, ^lease]] = Store.holds()
    assert CaseRecord.get(id).status == "failed"
  end

  test "untrusted sender and commands are classified before the VORTEX cursor advances", ctx do
    bad = Map.put(event(ctx), "peer", "unknown")
    Agent.update(ctx.page, fn _ -> %{events: [bad], cursor: 1} end)
    bridge = start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: ctx.transport})
    assert :ok = Bridge.pump(bridge)
    assert_receive {:acked, 1}
    refute_receive {:sent, _}, 20
  end

  # 2026-10-23 storm: escalations await an application receipt the frontier
  # never sent, so every later anomaly's flush resent the whole backlog.
  defp anomaly(n) do
    %{
      id: System.unique_integer([:positive]),
      kind: :watcher_down,
      subject: "/repo-#{n}",
      at: System.os_time(:millisecond),
      evidence: %{n: n},
      load: %{},
      count: 1
    }
  end

  test "an unreceipted escalation is sent once per run, not again on every later flush", ctx do
    anomaly = &anomaly/1

    bridge = start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: ctx.transport})
    send(bridge, {:trailblazer_event, :anomaly, anomaly.(1)})
    assert_receive {:sent, %{"room" => "frontier-room", "text" => first}}
    send(bridge, {:trailblazer_event, :anomaly, anomaly.(2)})
    assert_receive {:sent, %{"text" => second}}
    refute second == first
    send(bridge, {:trailblazer_event, :anomaly, anomaly.(3)})
    assert_receive {:sent, %{"text" => third}}
    refute third in [first, second]
    refute_receive {:sent, _}, 100
    assert Bridge.status(bridge).pending_messages == 3, "unreceipted escalations stay durable"

    stop_supervised!(Bridge)
    start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: ctx.transport})

    texts =
      for _ <- 1..3 do
        assert_receive {:sent, %{"text" => text}}
        text
      end

    assert Enum.sort(texts) == Enum.sort([first, second, third]), "a restart resends each once"
    refute_receive {:sent, _}, 100
  end

  # Hot load (deploy/hot-load.sh) of 6ca0fb1 into a bridge whose state predates
  # `:transmitted`: the backlog already sent must stay quiet, and the escalation
  # of the very anomaly that first wakes the new code must still go out.
  test "after a hot load from older state, the old backlog stays quiet and a new escalation is sent",
       ctx do
    bridge = start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: ctx.transport})
    send(bridge, {:trailblazer_event, :anomaly, anomaly(1)})
    assert_receive {:sent, %{"text" => old}}
    :sys.replace_state(bridge, &Map.delete(&1, :transmitted))

    send(bridge, {:trailblazer_event, :anomaly, anomaly(2)})

    assert_receive {:sent, %{"text" => new}},
                   1000,
                   "the new escalation is not swallowed by the seed"

    refute new == old
    refute_receive {:sent, _}, 100
    assert %MapSet{} = Map.get(:sys.get_state(bridge), :transmitted)
  end

  test "a send job started before the hot load still settles with its list-shaped result", ctx do
    bridge = start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: ctx.transport})
    send(bridge, {:trailblazer_event, :anomaly, anomaly(1)})
    assert_receive {:sent, _}
    [message] = Store.outbox()
    ref = make_ref()

    :sys.replace_state(bridge, fn state ->
      %{
        state
        | jobs: Map.put(state.jobs, ref, %{task: nil, kind: {:send, "frontier", [message.id]}})
      }
    end)

    send(bridge, {ref, [message]})
    assert Bridge.status(bridge).pending_messages == 0, "the old result is receipted"
    assert Process.alive?(bridge)
  end

  ## Research route (trailblazer:4cc63df): conference messages lift to the
  ## planner; the direct-room protocol intake above stays untouched.

  defp conference(peer, room, cursor, body) do
    %{
      "kind" => "conference_message",
      "peer" => peer,
      "room" => room,
      "body" => body,
      "cursor" => cursor
    }
  end

  test "a conference message lifts unaltered to the planner and opens no case", ctx do
    Trailblazer.Events.subscribe(:planner)

    Agent.update(ctx.page, fn _ ->
      %{
        events: [
          conference("some-peer", "conference:xyz123", 5, ~s({"parent": "x", "children": []}))
        ],
        cursor: 5
      }
    end)

    bridge = start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: ctx.transport})
    assert :ok = Bridge.pump(bridge)
    assert_receive {:acked, 5}

    assert_receive {:trailblazer_event, :planner,
                    {:research_conference,
                     %{
                       "conference" => "xyz123",
                       "peer" => "some-peer",
                       "body" => ~s({"parent": "x", "children": []}),
                       "cursor" => 5
                     }}}

    refute_receive {:trailblazer_event, :planner, {:research_recovered, _}}, 200
    assert Store.ids() == [], "a conference message is not protocol intake"
  end

  test "an authorized peer's conference message also publishes recovery", ctx do
    Trailblazer.Events.subscribe(:planner)

    Agent.update(ctx.page, fn _ ->
      %{events: [conference("frontier", "conference:abc", 6, "hello there")], cursor: 6}
    end)

    bridge = start_supervised!({Bridge, name: nil, peers: ctx.peers, transport: ctx.transport})
    assert :ok = Bridge.pump(bridge)

    assert_receive {:trailblazer_event, :planner,
                    {:research_conference, %{"conference" => "abc", "peer" => "frontier"}}}

    assert_receive {:trailblazer_event, :planner, {:research_recovered, "frontier"}}
  end
end
