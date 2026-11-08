defmodule Trailblazer.Vortex.BridgeConferenceTest do
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
