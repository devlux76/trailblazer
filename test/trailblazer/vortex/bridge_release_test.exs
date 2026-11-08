defmodule Trailblazer.Vortex.BridgeReleaseTest do
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
    assert Store.get(id).returned_fix == fix
    # This case has no lifecycle record, so the recovered bridge's verifier rejects the return.
    Enum.reduce_while(1..100, nil, fn _, _ ->
      if Store.get(id).state == "return_rejected",
        do: {:halt, :ok},
        else: {:cont, Process.sleep(50)}
    end)

    assert Store.get(id).state == "return_rejected"
    assert length(Enum.filter(Store.outbox(), &(&1.type == "receipt"))) <= 1
  end

  test "a consumed release retry leaves no fired backstop record behind" do
    ref = Trailblazer.Backstop.arm(:resource_release_blocked, "review-only", {:ms, 10})
    assert_receive {:backstop, ^ref, _}, 5000
    assert Map.has_key?(:sys.get_state(Trailblazer.Backstop).fired, ref)

    # a lease replaced meanwhile: the retry is consumed without a release
    state = %{
      transmitted: MapSet.new(),
      release_retry: {ref, "closed-case", "old-lease"},
      blocked_release: nil,
      resource_busy: false
    }

    assert {:noreply, %{release_retry: nil}} = Bridge.handle_info({:backstop, ref, nil}, state)
    refute Map.has_key?(:sys.get_state(Trailblazer.Backstop).fired, ref)
  end
end
