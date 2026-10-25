defmodule Trailblazer.EmbedHealthTest do
  use ExUnit.Case, async: false
  alias Trailblazer.{Backstop, EmbedHealth, Events}

  # Probe answers come from the test: each probe asks the test process.
  setup do
    test = self()

    probe = fn ->
      send(test, {:probe, self()})
      receive do: ({:answer, answer} -> answer)
    end

    {:ok, health} = EmbedHealth.start_link(name: nil, probe: probe)
    Events.subscribe(:embedder)
    %{health: health}
  end

  test "down, failed probes, then up: one event per change (J12)", %{health: health} do
    waiter = spawn(fn -> receive do: (:stop -> :ok) end)
    EmbedHealth.down(:refused, waiter, health)
    # the published reason is the inspected one, as it always was
    assert_receive {:trailblazer_event, :embedder, %{state: :down, reason: ":refused"}}
    assert {:down, :refused} = EmbedHealth.state(health)

    assert_receive {:probe, p1}
    send(p1, {:answer, {:error, :refused}})
    # A second failure is not a new event.
    EmbedHealth.down(:refused, waiter, health)
    assert_receive {:probe, p2}, 5_000
    refute_received {:trailblazer_event, :embedder, %{state: :down}}
    send(p2, {:answer, :ok})

    assert_receive {:trailblazer_event, :embedder, %{state: :up}}
    assert EmbedHealth.state(health) == :up
    refute_received {:trailblazer_event, :embedder, _}
  end

  # Nothing here waits for a message that a probe sends twice: the probe's
  # `{:probed, ...}` is sent by another process, and only its death proves the
  # answer is already in EmbedHealth's mailbox, so a call after that is
  # answered after it. Timing was never the synchronizer (design §13.2).
  defp answer(probe, reply) do
    ref = Process.monitor(probe)
    send(probe, {:answer, reply})
    assert_receive {:DOWN, ^ref, :process, ^probe, _}
    :ok
  end

  # Design §13.2: probes, retry timers and the outage backstop exist only while
  # live consumers wait. The last one to go takes all of them with it, and the
  # health stays :down — nothing said it is up.
  test "the last waiter to die takes the timer, the probe and both guards with it", %{
    health: health
  } do
    :ok = Events.subscribe(:backstop)

    waiter = spawn(fn -> receive do: (:stop -> :ok) end)
    EmbedHealth.down(:refused, waiter, health)
    # the published reason is the inspected one, as it always was
    assert_receive {:trailblazer_event, :embedder, %{state: :down, reason: ":refused"}}

    # The outage guard covers the period of pending demand; the retry timer's
    # first probe arms a guard of its own.
    assert_receive {:trailblazer_event, :backstop, {:armed, outage, :embedder_down, :embedder, _}}

    assert_receive {:probe, probe}
    probe_ref = Process.monitor(probe)

    assert_receive {:trailblazer_event, :backstop, {:armed, guard, :embed_probe, :embedder, _}}

    # The only waiter goes away while the probe is still out.
    waiter_ref = Process.monitor(waiter)
    send(waiter, :stop)
    assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, _}

    assert_receive {:DOWN, ^probe_ref, :process, ^probe, :killed}
    assert_receive {:trailblazer_event, :backstop, {:disarmed, ^guard}}
    assert_receive {:trailblazer_event, :backstop, {:disarmed, ^outage}}

    assert {:down, :refused} = EmbedHealth.state(health)

    assert %{
             state: :down,
             reason: :refused,
             waiting: %{},
             timer: nil,
             probing: nil,
             backstop: nil
           } =
             :sys.get_state(health)

    # :down is what the last consumer reported; no probe has said otherwise,
    # and an answer nobody asked for is not one.
    refute_receive {:trailblazer_event, :embedder, %{state: :up}}, 0
  end

  test "new demand after nobody waited arms a new outage guard and probes again", %{
    health: health
  } do
    :ok = Events.subscribe(:backstop)

    first = spawn(fn -> receive do: (:stop -> :ok) end)
    EmbedHealth.down(:refused, first, health)
    # the published reason is the inspected one, as it always was
    assert_receive {:trailblazer_event, :embedder, %{state: :down, reason: ":refused"}}

    assert_receive {:trailblazer_event, :backstop,
                    {:armed, first_guard, :embedder_down, :embedder, _}}

    assert_receive {:probe, probe}
    probe_ref = Process.monitor(probe)
    first_ref = Process.monitor(first)
    send(first, :stop)
    assert_receive {:DOWN, ^first_ref, :process, ^first, _}
    assert_receive {:DOWN, ^probe_ref, :process, ^probe, :killed}
    assert_receive {:trailblazer_event, :backstop, {:disarmed, ^first_guard}}
    assert {:down, :refused} = EmbedHealth.state(health)

    # Still down with nothing armed, so a new consumer is new demand.
    second = spawn(fn -> receive do: (:stop -> :ok) end)
    EmbedHealth.down(:refused, second, health)

    assert_receive {:trailblazer_event, :backstop, {:armed, guard, :embedder_down, :embedder, _}}

    refute guard == first_guard
    assert_receive {:probe, again}

    # The state never left :down, so the second failure is not a second event.
    assert {:down, :refused} = EmbedHealth.state(health)
    refute_received {:trailblazer_event, :embedder, %{state: :down}}
    refute_received {:trailblazer_event, :embedder, %{state: :up}}

    :ok = answer(again, :ok)
    assert_receive {:trailblazer_event, :embedder, %{state: :up}}
    assert_receive {:trailblazer_event, :backstop, {:disarmed, ^guard}}

    # One event per change: the recovery is the only one after the first :down.
    refute_receive {:trailblazer_event, :embedder, %{state: :up}}, 0

    assert %{state: :up, waiting: %{}, timer: nil, probing: nil, backstop: nil} =
             :sys.get_state(health)
  end

  # Design §13.2: one outage guard per period of pending demand. A period ends
  # when the last consumer leaves, not when a new one joins, so a guard that has
  # fired is not rearmed underneath consumers who are still waiting.
  #
  # The owner's half of a fire is `{:backstop, ref, id}`, the message Backstop
  # sends the owner when one fires; it is sent here so the state a fire leaves
  # behind is reached without waiting on a timer, and the guard is disarmed from
  # this side so the test leaves nothing armed for the next one.
  test "a fired outage guard is not rearmed until every consumer has left", %{health: health} do
    :ok = Events.subscribe(:backstop)

    first = spawn(fn -> receive do: (:stop -> :ok) end)
    EmbedHealth.down(:refused, first, health)
    # the published reason is the inspected one, as it always was
    assert_receive {:trailblazer_event, :embedder, %{state: :down, reason: ":refused"}}
    assert_receive {:trailblazer_event, :backstop, {:armed, fired, :embedder_down, :embedder, _}}

    assert :ok = Backstop.disarm(fired)
    send(health, {:backstop, fired, 0})
    assert %{backstop: nil, waiting: %{^first => _}} = :sys.get_state(health)

    # A second consumer joins the period that is already pending, with its guard
    # spent: nothing is armed for it.
    second = spawn(fn -> receive do: (:stop -> :ok) end)
    EmbedHealth.down(:refused, second, health)

    assert {:down, :refused} = EmbedHealth.state(health)
    assert %{backstop: nil, waiting: %{^first => _, ^second => _}} = :sys.get_state(health)
    refute_received {:trailblazer_event, :backstop, {:armed, _, :embedder_down, :embedder, _}}

    # A probe is out. Its guard being disarmed is the fact that says the last
    # consumers are gone and this process is holding nothing for anyone.
    assert_receive {:probe, probe}, 5_000
    probe_ref = Process.monitor(probe)

    assert_receive {:trailblazer_event, :backstop,
                    {:armed, probe_guard, :embed_probe, :embedder, _}},
                   5_000

    first_ref = Process.monitor(first)
    second_ref = Process.monitor(second)
    send(first, :stop)
    send(second, :stop)
    assert_receive {:DOWN, ^first_ref, :process, ^first, _}
    assert_receive {:DOWN, ^second_ref, :process, ^second, _}
    assert_receive {:trailblazer_event, :backstop, {:disarmed, ^probe_guard}}
    assert_receive {:DOWN, ^probe_ref, :process, ^probe, :killed}
    assert %{waiting: %{}, timer: nil, probing: nil, backstop: nil} = :sys.get_state(health)

    # The period ended, so demand beginning another one arms a new guard.
    third = spawn(fn -> receive do: (:stop -> :ok) end)
    EmbedHealth.down(:refused, third, health)

    assert_receive {:trailblazer_event, :backstop, {:armed, again, :embedder_down, :embedder, _}},
                   5_000

    refute again == fired
    assert {:down, :refused} = EmbedHealth.state(health)

    # and this test leaves nothing armed for the next one
    third_ref = Process.monitor(third)
    send(third, :stop)
    assert_receive {:DOWN, ^third_ref, :process, ^third, _}
    assert_receive {:trailblazer_event, :backstop, {:disarmed, ^again}}
    assert %{waiting: %{}, backstop: nil} = :sys.get_state(health)
  end

  # `Process.cancel_timer/1` cannot retract a message already in this mailbox,
  # so a retry can outlive the demand that asked for it.
  test "a retry left over from a cancelled timer probes nobody", %{health: health} do
    :ok = Events.subscribe(:backstop)

    waiter = spawn(fn -> receive do: (:stop -> :ok) end)
    EmbedHealth.down(:refused, waiter, health)
    # the published reason is the inspected one, as it always was
    assert_receive {:trailblazer_event, :embedder, %{state: :down, reason: ":refused"}}
    assert_receive {:trailblazer_event, :backstop, {:armed, outage, :embedder_down, :embedder, _}}

    assert_receive {:probe, probe}
    probe_ref = Process.monitor(probe)

    assert_receive {:trailblazer_event, :backstop,
                    {:armed, probe_guard, :embed_probe, :embedder, _}},
                   5_000

    waiter_ref = Process.monitor(waiter)
    send(waiter, :stop)
    assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, _}
    assert_receive {:DOWN, ^probe_ref, :process, ^probe, :killed}
    assert_receive {:trailblazer_event, :backstop, {:disarmed, ^probe_guard}}
    assert_receive {:trailblazer_event, :backstop, {:disarmed, ^outage}}

    # This is the message that timer would have sent. Nobody is waiting, so it
    # asks for no probe and arms no guard.
    send(health, :probe)
    assert {:down, :refused} = EmbedHealth.state(health)

    refute_received {:probe, _}
    refute_received {:trailblazer_event, :backstop, {:armed, _, :embed_probe, :embedder, _}}
    refute_received {:trailblazer_event, :backstop, {:armed, _, :embedder_down, :embedder, _}}
    assert %{waiting: %{}, timer: nil, probing: nil, backstop: nil} = :sys.get_state(health)
  end

  test "a second retry does not replace the probe already out", %{health: health} do
    waiter = spawn(fn -> receive do: (:stop -> :ok) end)
    EmbedHealth.down(:refused, waiter, health)
    assert_receive {:probe, probe}
    probe_ref = Process.monitor(probe)

    send(health, :probe)
    send(health, :probe)

    assert %{probing: {^probe, _, _}, waiting: %{^waiter => _}} = :sys.get_state(health)
    assert Process.alive?(probe)
    refute_received {:probe, _}

    # The one probe that was out is the one that answers, and it recovers us.
    :ok = answer(probe, :ok)
    assert_receive {:DOWN, ^probe_ref, :process, ^probe, :normal}
    assert_receive {:trailblazer_event, :embedder, %{state: :up}}
    assert %{probing: nil, timer: nil, backstop: nil, waiting: %{}} = :sys.get_state(health)
    refute_received {:probe, _}
  end

  test "a probe that crashes counts as a failure and probing goes on", %{health: health} do
    waiter = spawn(fn -> receive do: (:stop -> :ok) end)
    EmbedHealth.down(:refused, waiter, health)
    assert_receive {:probe, p1}
    Process.exit(p1, :kill)
    assert_receive {:probe, p2}, 5_000
    send(p2, {:answer, :ok})
    assert_receive {:trailblazer_event, :embedder, %{state: :up}}
  end

  test "ok/0 resets the gap; failures double it up to the cap", %{health: health} do
    waiter = spawn(fn -> receive do: (:stop -> :ok) end)
    EmbedHealth.down(:refused, waiter, health)
    assert_receive {:probe, p1}
    send(p1, {:answer, {:error, :refused}})
    assert_receive {:probe, p2}, 5_000
    assert :sys.get_state(health).gap == 2_000
    send(p2, {:answer, :ok})
    assert_receive {:trailblazer_event, :embedder, %{state: :up}}
    EmbedHealth.ok(health)
    assert :sys.get_state(health).gap == 1_000
  end
end
