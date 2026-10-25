defmodule Trailblazer.Loop.RunnerTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Loop.{Runner, CaseRecord}

  test "cases exist before execution, run serially, and a dead worker does not stop the queue" do
    parent = self()

    run = fn task, opts ->
      send(parent, {:started, task.request, self(), opts[:case_id]})

      receive do
        :finish ->
          report = %{case: opts[:case_id], status: :fixed, summary: task.request}
          :ok = CaseRecord.close(opts[:case_id], report)
          report
      end
    end

    runner = start_supervised!({Runner, name: nil, run: run, prepare: fn _ -> :ok end})
    assert {:ok, first} = Runner.submit(%{repo: "/fixture", request: "first"}, runner)
    assert CaseRecord.get(first).task["request"] == "first"
    assert_receive {:started, "first", worker, ^first}
    assert Runner.status(first, runner) == :running
    assert {:ok, second} = Runner.submit(%{repo: "/fixture", request: "second"}, runner)
    assert Runner.status(second, runner) == :queued
    refute_receive {:started, "second", _, _}, 30
    Process.exit(worker, :kill)
    assert_receive {:started, "second", next, ^second}
    assert CaseRecord.get(first).status == "failed"
    assert CaseRecord.get(first).report["summary"] =~ "stopped"
    send(next, :finish)
    await_closed(second)
    assert CaseRecord.get(second).status == "fixed"
    assert Process.alive?(runner)
  end

  test "preparation failure closes a case without calling the model" do
    parent = self()

    runner =
      start_supervised!(
        {Runner,
         name: nil,
         run: fn _, _ -> send(parent, :model_called) end,
         prepare: fn _ -> {:error, :no_repo} end}
      )

    {:ok, id} = Runner.submit(%{repo: "/missing", request: "fix"}, runner)
    await_closed(id)
    assert CaseRecord.get(id).status == "failed"
    refute_received :model_called
  end

  test "stopping the runner closes queued cases and stops its worker" do
    parent = self()

    run = fn _, _ ->
      send(parent, {:worker, self()})
      receive do: (:finish -> :ok)
    end

    spec =
      Supervisor.child_spec({Runner, name: nil, run: run, prepare: fn _ -> :ok end},
        restart: :temporary
      )

    runner = start_supervised!(spec)
    {:ok, first} = Runner.submit(%{repo: "/fixture", request: "first"}, runner)
    assert_receive {:worker, worker}
    ref = Process.monitor(worker)
    {:ok, second} = Runner.submit(%{repo: "/fixture", request: "second"}, runner)
    GenServer.stop(runner, :normal)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert CaseRecord.get(first).status == "failed"
    assert CaseRecord.get(second).status == "failed"
  end

  test "service recovery closes interrupted cases without replaying them" do
    {:ok, id} = CaseRecord.open(%{repo: "/fixture", request: "interrupted"})
    parent = self()

    start_supervised!(
      {Runner, name: nil, recover: true, run: fn _, _ -> send(parent, :replayed) end}
    )

    assert CaseRecord.get(id).status == "failed"
    assert CaseRecord.get(id).report["summary"] =~ "service stopped"
    refute_received :replayed
  end

  defp await_closed(id) do
    topic = {:case, id}
    Trailblazer.Events.subscribe(topic)
    monitor = Process.monitor(Process.whereis(Trailblazer.CaseStore))

    try do
      if CaseRecord.get(id).status == "open" do
        receive do
          {:trailblazer_event, ^topic, %{closed: true}} -> :ok
          {:DOWN, ^monitor, _, _, reason} -> flunk("case store stopped: #{inspect(reason)}")
        end
      end
    after
      Process.demonitor(monitor, [:flush])
      Trailblazer.Events.unsubscribe(topic)
    end
  end
end
