defmodule Trailblazer.AnomalyTest do
  use ExUnit.Case, async: false

  alias Trailblazer.{Anomaly, Backstop, Events}

  # Investigation requests come back to the test as messages.
  setup do
    me = self()

    Application.put_env(
      :trailblazer,
      :investigate_transport,
      {:fun,
       fn text ->
         send(me, {:investigation, text})
         [_, id] = Regex.run(~r/anomaly (\d+)\./, text)
         send(me, {:investigation_worker, String.to_integer(id), self()})
         Process.get(:fail_send, :ok)
       end}
    )

    on_exit(fn -> Application.put_env(:trailblazer, :investigate_transport, :none) end)
    %{subject: "subject-#{System.unique_integer([:positive])}"}
  end

  test "a report is recorded with the load, published, and sent once to investigate", %{
    subject: subject
  } do
    :ok = Events.subscribe(:anomaly)
    assert {:ok, id} = Anomaly.report(:model_call, subject, %{case: "c1", tokens: 0})

    assert_receive {:trailblazer_event, :anomaly, %{id: ^id, count: 1, load: load}}
    # J8: load is evidence
    assert Map.has_key?(load, :loadavg)
    assert Map.has_key?(load, :mem_available_mb)
    assert Map.has_key?(load, :swap_used_mb)
    assert Map.has_key?(load, :model)

    assert_receive {:investigation, text}
    assert text =~ "From Trailblazer, not typed by the operator"
    assert text =~ "anomaly #{id}"
    assert text =~ "model_call for #{subject}"
    assert text =~ "trailblazer ack #{id}"
    assert text =~ "It may just be load"

    assert [%{id: ^id, evidence: %{"case" => "c1"}}] =
             Enum.filter(Anomaly.list(open: true), &(&1.subject == subject))
  end

  test "J6: the same fault while open counts; after an ack it is new", %{subject: subject} do
    {:ok, id} = Anomaly.report(:check, subject, %{})
    assert_receive {:investigation, _}

    {:ok, ^id} = Anomaly.report(:check, subject, %{})
    refute_receive {:investigation, _}, 100
    assert [%{count: 2}] = Enum.filter(Anomaly.list(open: true), &(&1.id == id))

    assert :ok = Anomaly.ack(id)
    assert {:error, :no_anomaly} = Anomaly.ack(id)
    {:ok, new} = Anomaly.report(:check, subject, %{})
    assert new != id
    assert_receive {:investigation, text}
    assert text =~ "anomaly #{new}"
  end

  test "J9: a request that cannot be sent stays unsent and goes with the next report", %{
    subject: subject
  } do
    me = self()

    failing = fn text ->
      send(me, {:failed_send, text})
      {:error, :down}
    end

    Application.put_env(:trailblazer, :investigate_transport, {:fun, failing})
    {:ok, first} = Anomaly.report(:embed, subject, %{})
    # sending is asynchronous: wait until it has failed
    assert_receive {:failed_send, _}
    assert [%{sent: 0}] = Enum.filter(Anomaly.list(open: true), &(&1.id == first))

    working = fn text ->
      send(me, {:investigation, text})
      :ok
    end

    Application.put_env(:trailblazer, :investigate_transport, {:fun, working})
    {:ok, second} = Anomaly.report(:embed, subject <> "-2", %{})

    texts =
      for _ <- 1..2 do
        assert_receive {:investigation, text}
        text
      end

    assert Enum.any?(texts, &(&1 =~ "anomaly #{first}."))
    assert Enum.any?(texts, &(&1 =~ "anomaly #{second}."))
  end

  test "evidence that is not JSON (tuples, pids) is recorded as text, never a crash", %{
    subject: subject
  } do
    assert {:ok, id} = Anomaly.report(:odd, subject, %{state: {:busy, self()}, ref: make_ref()})
    assert [%{evidence: %{"state" => [_, _]}}] = Enum.filter(Anomaly.list(), &(&1.id == id))
  end

  describe "backstops" do
    test "disarmed in time: nothing fires", %{subject: subject} do
      :ok = Events.subscribe(:backstop)
      ref = Backstop.arm(:test, subject, {:ms, 60_000})
      assert_receive {:trailblazer_event, :backstop, {:armed, ^ref, :test, ^subject, 60_000}}
      assert :ok = Backstop.disarm(ref)
      assert_receive {:trailblazer_event, :backstop, {:disarmed, ^ref}}
      refute_received {:backstop, ^ref, _}
    end

    test "J5: a backstop that fires reports an anomaly with its evidence; disarm then says :fired",
         %{subject: subject} do
      ref = Backstop.arm(:model_call, subject, {:ms, 1}, fn -> %{tokens: 7} end)
      assert_receive {:backstop, ^ref, id}
      assert_receive {:investigation, text}
      assert text =~ "anomaly #{id}"

      assert [%{evidence: %{"tokens" => 7, "limit_ms" => 1, "waited_ms" => w}}] =
               Enum.filter(Anomaly.list(), &(&1.id == id))

      assert w >= 1
      assert :fired = Backstop.disarm(ref)
      assert :ok = Backstop.disarm(ref)
    end

    test "J7: a waiting process that dies takes its backstops with it", %{subject: subject} do
      :ok = Events.subscribe(:backstop)
      me = self()

      owner =
        spawn(fn ->
          send(me, {:ref, Backstop.arm(:test, subject, {:ms, 60_000})})
        end)

      assert_receive {:ref, ref}
      assert_receive {:trailblazer_event, :backstop, {:cancelled, ^ref, :owner_down}}
      refute Process.alive?(owner)
      refute_received {:investigation, _}
    end

    test "guarded IO cannot outlive its waiting owner", %{subject: subject} do
      parent = self()

      owner =
        spawn(fn ->
          Backstop.guard(:test, subject, {:ms, 60_000}, fn -> %{} end, fn ->
            send(parent, {:guarded_worker, self()})
            receive do: (:never -> :ok)
          end)
        end)

      assert_receive {:guarded_worker, worker}
      ref = Process.monitor(worker)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, _}, 100
    end

    test "guard: a value, a crash, and a hang that loses to its backstop", %{subject: subject} do
      assert {:ok, 42} =
               Backstop.guard(:test, subject, {:ms, 60_000}, fn -> %{} end, fn -> 42 end)

      assert {:error, {:down, _}} =
               Backstop.guard(:test, subject, {:ms, 60_000}, fn -> %{} end, fn -> exit(:boom) end)

      me = self()

      hang = fn ->
        send(me, {:hanging, self()})
        receive do: (:never -> :ok)
      end

      assert {:error, {:backstop, id}} =
               Backstop.guard(:http, subject, {:ms, 1}, fn -> %{url: "x"} end, hang)

      assert_receive {:hanging, pid}
      refute Process.alive?(pid)
      assert [%{kind: "http"}] = Enum.filter(Anomaly.list(), &(&1.id == id))
      # Delivery's callback runs before its mark_sent database write. Join that
      # worker before checking the global backstop count.
      assert_receive {:investigation_worker, ^id, worker}
      ref = Process.monitor(worker)
      assert_receive {:DOWN, ^ref, :process, ^worker, _}
      assert Backstop.armed() == 0
    end
  end
end
