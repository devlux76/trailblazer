defmodule Trailblazer.Vortex.BridgeOutboxTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Vortex.{Bridge, Store}

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
end
