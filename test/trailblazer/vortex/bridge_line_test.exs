defmodule Trailblazer.Vortex.BridgeLineTest do
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
end
