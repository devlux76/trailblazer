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

  test "an authorized peer's refused task gets one correlated rejected reply and opens no case",
       ctx do
    body =
      Protocol.envelope("task", "message-1", ctx.request, %{
        "repo" => "/tmp",
        "request" => "fix",
        "check" => "rm -rf /"
      })
      |> Jason.encode!()

    refused = %{
      "kind" => "message",
      "peer" => "caller",
      "room" => "room",
      "body" => body,
      "cursor" => 1
    }

    Agent.update(ctx.page, fn _ -> %{events: [refused], cursor: 1} end)

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
    assert_receive {:sent, %{"text" => reply}}
    assert {:ok, rejected} = Protocol.decode(reply)
    assert rejected["type"] == "rejected"
    assert rejected["request_id"] == ctx.request
    assert rejected["payload"] == %{"reason" => "unauthorized_task"}
    refute reply =~ "rm -rf"
    assert Bridge.status(bridge).requests == []
    assert Bridge.status(bridge).active == nil

    # A redelivery repeats the identical reply (same id), and still opens no case.
    Agent.update(ctx.page, fn _ -> %{events: [Map.put(refused, "cursor", 2)], cursor: 2} end)
    assert :ok = Bridge.pump(bridge)
    assert_receive {:acked, 2}
    assert_receive {:sent, %{"text" => again}}
    assert {:ok, %{"id" => same}} = Protocol.decode(again)
    assert same == rejected["id"]
    assert Bridge.status(bridge).requests == []
  end

  test "a task from an unauthorized peer gets no reply at all", ctx do
    stranger = event(ctx) |> Map.put("peer", "stranger")
    Agent.update(ctx.page, fn _ -> %{events: [stranger], cursor: 1} end)

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
    refute_receive {:sent, _}, 200
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
end
