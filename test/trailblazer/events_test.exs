defmodule Trailblazer.EventsTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Events

  defp topic, do: {:test, make_ref()}

  test "J1: every subscriber gets each event once, in the order it was published" do
    t = topic()
    me = self()

    others =
      for _ <- 1..2 do
        spawn_link(fn ->
          :ok = Events.subscribe(t)
          send(me, :subscribed)

          send(
            me,
            {:got, self(), for(_ <- 1..3, do: receive(do: ({:trailblazer_event, ^t, e} -> e)))}
          )
        end)
      end

    for _ <- others, do: assert_receive(:subscribed)
    :ok = Events.subscribe(t)

    for n <- 1..3, do: :ok = Events.publish(t, n)

    for pid <- others, do: assert_receive({:got, ^pid, [1, 2, 3]})
    for n <- 1..3, do: assert_receive({:trailblazer_event, ^t, ^n})
    refute_received {:trailblazer_event, ^t, _}
  end

  test "J3: a dead subscriber is dropped and the publisher goes on" do
    t = topic()
    me = self()

    dead =
      spawn(fn ->
        :ok = Events.subscribe(t)
        send(me, :subscribed)
      end)

    assert_receive :subscribed
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}

    :ok = Events.subscribe(t)
    assert :ok = Events.publish(t, :after)
    assert_receive {:trailblazer_event, ^t, :after}
  end

  test "publishing with no subscribers does nothing; topics are separate" do
    assert :ok = Events.publish(topic(), :nobody)

    t = topic()
    :ok = Events.subscribe(t)
    :ok = Events.publish(topic(), :elsewhere)
    :ok = Events.publish(t, :here)
    assert_receive {:trailblazer_event, ^t, :here}
    refute_received {:trailblazer_event, _, :elsewhere}
  end

  test "unsubscribe stops delivery" do
    t = topic()
    :ok = Events.subscribe(t)
    :ok = Events.unsubscribe(t)
    :ok = Events.publish(t, :gone)
    refute_received {:trailblazer_event, ^t, :gone}
  end
end
