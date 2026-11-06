defmodule Trailblazer.EmbedGateTest do
  use ExUnit.Case, async: true
  alias Trailblazer.EmbedGate

  test "a crashed permit holder releases the single permit" do
    gate = start_supervised!({EmbedGate, name: nil})
    :ok = EmbedGate.update(10, true, gate)
    parent = self()

    holder =
      spawn(fn ->
        :ok = EmbedGate.acquire(parent, gate)
        send(parent, {:holding, self()})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:holding, ^holder}

    next =
      spawn(fn ->
        :ok = EmbedGate.acquire(parent, gate)
        send(parent, {:holding, self()})
        EmbedGate.release(gate)
      end)

    refute_receive {:holding, ^next}, 30
    Process.exit(holder, :kill)
    assert_receive {:holding, ^next}, 1000
  end

  test "hold waits for the running batch, then goes ahead of every queued job" do
    gate = start_supervised!({EmbedGate, name: nil})
    :ok = EmbedGate.update(10, true, gate)
    parent = self()

    batch =
      spawn(fn ->
        :ok = EmbedGate.acquire(parent, gate)
        send(parent, :batch_running)
        receive do: (:finish -> EmbedGate.release(gate))
      end)

    assert_receive :batch_running

    queued =
      spawn(fn ->
        :ok = EmbedGate.acquire(parent, gate)
        send(parent, :queued_ran)
      end)

    eventually(fn -> EmbedGate.queued?(queued, gate) end)

    model =
      spawn(fn ->
        :ok = EmbedGate.hold(gate)
        send(parent, :held)
        receive do: (:let_go -> :ok)
      end)

    refute_receive :held, 50
    send(batch, :finish)
    assert_receive :held, 1000
    refute_receive :queued_ran, 50

    # the holder exits without releasing: the gate is free again
    send(model, :let_go)
    assert_receive :queued_ran, 1000
  end

  test "a held gate is released by the holder" do
    gate = start_supervised!({EmbedGate, name: nil})
    :ok = EmbedGate.update(10, true, gate)
    :ok = EmbedGate.hold(gate)
    parent = self()

    spawn(fn ->
      :ok = EmbedGate.acquire(parent, gate)
      send(parent, :ran)
    end)

    refute_receive :ran, 50
    :ok = EmbedGate.release(gate)
    assert_receive :ran, 1000
  end

  test "a dead waiting job cannot strand the queue" do
    gate = start_supervised!({EmbedGate, name: nil})
    :ok = EmbedGate.update(10, true, gate)
    parent = self()
    :ok = EmbedGate.acquire(parent, gate)
    waiter = spawn(fn -> EmbedGate.acquire(parent, gate) end)
    eventually(fn -> EmbedGate.queued?(waiter, gate) end)
    Process.exit(waiter, :kill)
    :ok = EmbedGate.release(gate)
    :ok = EmbedGate.acquire(parent, gate)
    :ok = EmbedGate.release(gate)
  end

  test "equal priorities drain the earlier watch first, regardless of enqueue order" do
    gate = start_supervised!({EmbedGate, name: nil})
    :ok = EmbedGate.update(0, false, gate)
    :ok = EmbedGate.acquire(self(), gate)
    parent = self()
    earlier = owner(gate, parent)
    assert_receive {:registered, ^earlier}
    later = owner(gate, parent)
    assert_receive {:registered, ^later}
    send(later, :run)
    send(earlier, :run)
    eventually(fn -> EmbedGate.queued?(earlier, gate) and EmbedGate.queued?(later, gate) end)
    :ok = EmbedGate.release(gate)
    assert_receive {:admitted, ^earlier}
    refute_receive {:admitted, ^later}, 30
    send(earlier, :finish)
    assert_receive {:admitted, ^later}
    send(later, :finish)
  end

  test "a dead repository cannot reserve priority forever" do
    gate = start_supervised!({EmbedGate, name: nil})
    :ok = EmbedGate.update(0, false, gate)
    parent = self()
    owner = owner(gate, parent)
    assert_receive {:registered, ^owner}

    waiter =
      spawn(fn ->
        :ok = EmbedGate.acquire(parent, gate)
        send(parent, :admitted)
        EmbedGate.release(gate)
      end)

    eventually(fn -> EmbedGate.queued?(waiter, gate) end)
    refute_receive :admitted, 30
    Process.exit(owner, :kill)
    assert_receive :admitted
  end

  defp owner(gate, parent) do
    spawn(fn ->
      :ok = EmbedGate.update(10, true, gate)
      send(parent, {:registered, self()})
      receive do: (:run -> :ok)
      :ok = EmbedGate.acquire(self(), gate)
      send(parent, {:admitted, self()})
      receive do: (:finish -> :ok)
      :ok = EmbedGate.update(10, false, gate)
      :ok = EmbedGate.release(gate)
    end)
  end

  defp eventually(check, tries \\ 100)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, tries) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(check, tries - 1)
        )
  end

  test "a timed out hold leaves no ghost reservation while its owner stays alive" do
    gate = start_supervised!({EmbedGate, name: nil})
    :ok = EmbedGate.hold(gate)
    parent = self()

    waiter =
      spawn(fn ->
        send(parent, {:hold_result, EmbedGate.hold(gate, 30)})
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> Process.exit(waiter, :kill) end)
    assert_receive {:hold_result, {:error, :timeout}}, 1000
    :ok = EmbedGate.release(gate)
    assert :ok = EmbedGate.hold(gate, 200)
    :ok = EmbedGate.release(gate)
  end

  test "document requests wait while a query runs, and go on when it ends" do
    gate = start_supervised!({EmbedGate, name: nil})
    parent = self()
    assert :ok = EmbedGate.clear(gate)

    query =
      spawn(fn ->
        EmbedGate.query(
          fn ->
            send(parent, :querying)
            receive do: (:done -> :ok)
          end,
          gate
        )

        send(parent, :query_over)
      end)

    assert_receive :querying, 1000
    doc = spawn(fn -> EmbedGate.clear(gate) && send(parent, :doc_sent) end)
    refute_receive :doc_sent, 30

    send(query, :done)
    assert_receive :query_over, 1000
    assert_receive :doc_sent, 1000
    refute Process.alive?(doc)
  end

  test "a query whose process dies no longer holds documents back" do
    gate = start_supervised!({EmbedGate, name: nil})
    parent = self()

    query =
      spawn(fn ->
        EmbedGate.query(
          fn ->
            send(parent, :querying)
            receive do: (:never -> :ok)
          end,
          gate
        )
      end)

    assert_receive :querying, 1000
    spawn(fn -> EmbedGate.clear(gate) && send(parent, :doc_sent) end)
    refute_receive :doc_sent, 30
    Process.exit(query, :kill)
    assert_receive :doc_sent, 1000
  end

  test "the idle tier gets the gate only when no indexer has work" do
    gate = start_supervised!({EmbedGate, name: nil})
    parent = self()

    indexer =
      spawn(fn ->
        :ok = EmbedGate.update(0, true, gate)
        :ok = EmbedGate.acquire(self(), gate)
        send(parent, :indexing)
        receive do: (:finish -> :ok)
        :ok = EmbedGate.release(gate)
        :ok = EmbedGate.update(0, true, gate)
        send(parent, :more_work)
        receive do: (:no_work -> EmbedGate.update(0, false, gate))
        receive do: (:never -> :ok)
      end)

    assert_receive :indexing, 1000

    backfill =
      spawn(fn ->
        :ok = EmbedGate.update(EmbedGate.idle_priority(), true, gate)
        :ok = EmbedGate.acquire(self(), gate)
        send(parent, :backfilling)
        EmbedGate.release(gate)
      end)

    send(indexer, :finish)
    assert_receive :more_work, 1000
    # the indexer still reports work: the backfill keeps waiting
    refute_receive :backfilling, 30
    send(indexer, :no_work)
    assert_receive :backfilling, 1000
    refute Process.alive?(backfill)
  end

  test "a gate whose state predates queries (kept by a hot load) still serves them" do
    gate = start_supervised!({EmbedGate, name: nil})
    :sys.replace_state(gate, &Map.drop(&1, [:queries, :clearing]))
    parent = self()

    query =
      spawn(fn ->
        EmbedGate.query(
          fn ->
            send(parent, :querying)
            receive do: (:done -> :ok)
          end,
          gate
        )
      end)

    assert_receive :querying, 1000
    spawn(fn -> EmbedGate.clear(gate) && send(parent, :doc_sent) end)
    refute_receive :doc_sent, 30
    send(query, :done)
    assert_receive :doc_sent, 1000
    assert Process.alive?(gate)
  end
end
