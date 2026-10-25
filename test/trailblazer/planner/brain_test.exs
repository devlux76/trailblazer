defmodule Trailblazer.Planner.BrainTest do
  # The OTP brain: it coalesces real events, checks the worker and the planner
  # claim, plans under the dedicated resource lease, fences on a failed
  # cleanup, recovers an unresolved lease on restart without repeating the
  # model, and dispatches only a still-current selection through the existing
  # planner CLI. Every external effect is an injected function; the journal is
  # the real cases.db store.
  use ExUnit.Case, async: false
  alias Trailblazer.Planner.{Brain, Journal}

  setup do
    Trailblazer.CaseStore.transaction(fn conn ->
      for ddl <- [
            "CREATE TABLE IF NOT EXISTS planner_brain (fingerprint TEXT PRIMARY KEY, lease TEXT NOT NULL, state TEXT NOT NULL, ref TEXT, reason TEXT NOT NULL, at INTEGER NOT NULL)",
            "CREATE TABLE IF NOT EXISTS planner_assignment (case_id TEXT PRIMARY KEY, ref TEXT NOT NULL, state TEXT NOT NULL, deadline_at INTEGER NOT NULL, note TEXT NOT NULL)"
          ],
          do: Exqlite.query!(conn, ddl, [], timeout: :infinity)

      for table <- ~w(planner_brain planner_assignment),
          do: Exqlite.query!(conn, "DELETE FROM #{table}", [], timeout: :infinity)
    end)

    dir = Path.join(System.tmp_dir!(), "planner-brain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, log} = Agent.start_link(fn -> [] end)
    start_supervised!({Task.Supervisor, name: :brain_test_tasks}, id: :brain_test_tasks_sup)

    %{
      dir: dir,
      log: log,
      config: %{repos: %{}, planner: {"/bin/true", []}}
    }
  end

  ## Fakes (every one is an external-effect boundary; the journal stays real)

  defp push(log, op), do: Agent.update(log, &[op | &1])

  defp logged(log, op),
    do: log |> Agent.get(& &1) |> Enum.reverse() |> Enum.filter(&match?({^op, _}, &1))

  defp count(log, op), do: length(logged(log, op))

  defp card(ref \\ "probe:aaaa11", check \\ "make test") do
    %{
      ref: ref,
      check: check,
      repo: "/tmp/repo",
      context: %{"ref" => ref, "title" => "t", "priority" => "p1", "body" => "b", "recent" => []}
    }
  end

  defp snapshot(cards, n), do: %{fingerprint: "fp-#{n}", cards: cards}

  defp queue(initial) do
    {:ok, agent} = Agent.start_link(fn -> initial end)
    agent
  end

  defp pop(agent),
    do:
      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [next | rest] -> {next, rest}
      end)

  # A board whose snapshots come from a queue; each read is logged.
  defp board_fun(log, queue) do
    fn _config ->
      push(log, {:board, System.unique_integer()})
      {:ok, pop(queue)}
    end
  end

  defp static_board(log, snapshot),
    do: fn _config -> push(log, {:board, nil}) && {:ok, snapshot} end

  # A programmed result is a bare value; a queue is {:queue, agent}.
  defp take({:queue, agent}), do: pop(agent)
  defp take(value), do: value

  defp choose_fun(log, result),
    do: fn cards -> push(log, {:choose, Enum.map(cards, & &1.ref)}) && take(result) end

  defp resource_funs(log, acquire_results \\ :ok, release_result \\ :ok) do
    acquire = fn lease ->
      push(log, {:acquire, lease})

      case take(acquire_results) do
        :ok -> {:ok, lease}
        other -> other
      end
    end

    release = fn lease ->
      push(log, {:release, lease})
      release_result
    end

    {acquire, release}
  end

  defp idle_bridge do
    fn -> %{active: nil, resource_release_blocked: nil, requests: []} end
  end

  defp start_brain(ctx, extra \\ []) do
    {acquire, release} = resource_funs(ctx.log)

    opts =
      Keyword.merge(
        [
          name: nil,
          config: ctx.config,
          tasks: :brain_test_tasks,
          board: static_board(ctx.log, snapshot([card()], 1)),
          choose: choose_fun(ctx.log, {:ok, :wait}),
          assign: fn _config, card -> push(ctx.log, {:assign, card.ref}) && :ok end,
          acquire: acquire,
          release: release,
          bridge_status: idle_bridge(),
          start_sse: fn _ -> {:error, :test_stream_unavailable} end,
          start_watcher: fn _config -> :off end
        ],
        extra
      )

    start_supervised!(%{id: make_ref(), start: {GenServer, :start_link, [Brain, opts]}})
  end

  defp eventually(fun, n \\ 100) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && eventually(fun, n - 1)
    end
  end

  test "startup takes one snapshot and records a wait decision under the lease", ctx do
    brain = start_brain(ctx)
    eventually(fn -> match?(%{state: "wait"}, Journal.latest()) end)

    assert [{:acquire, lease}] = logged(ctx.log, :acquire)
    assert [{:release, ^lease}] = logged(ctx.log, :release)
    assert %{state: "wait"} = Journal.latest()
    eventually(fn -> Brain.status(brain).state == :idle end)
  end

  test "an empty board never infers", ctx do
    brain = start_brain(ctx, board: static_board(ctx.log, snapshot([], 1)))
    eventually(fn -> count(ctx.log, :board) >= 1 end)
    Process.sleep(300)

    assert count(ctx.log, :choose) == 0
    assert count(ctx.log, :acquire) == 0
    assert Brain.status(brain).last == nil
  end

  test "a busy worker or a pending resource request never infers", ctx do
    brain =
      start_brain(ctx,
        bridge_status: fn -> %{active: "worker", resource_release_blocked: nil, requests: []} end
      )

    Process.sleep(300)
    assert count(ctx.log, :board) == 0 and count(ctx.log, :choose) == 0
    GenServer.stop(brain)

    busy_requests =
      fn ->
        %{
          active: nil,
          resource_release_blocked: nil,
          requests: [%{case_id: "c", state: "waiting_resource"}]
        }
      end

    brain = start_brain(ctx, bridge_status: busy_requests)
    Process.sleep(300)
    assert count(ctx.log, :board) == 0 and count(ctx.log, :choose) == 0
    GenServer.stop(brain)
  end

  test "an active trailblazer planner claim never infers", ctx do
    Trailblazer.CaseStore.transaction(fn conn ->
      Exqlite.query!(
        conn,
        "INSERT INTO planner_assignment (case_id, ref, state, deadline_at, note) VALUES ('c1', 'vortex:abc', 'open', 0, '')",
        [],
        timeout: :infinity
      )
    end)

    start_brain(ctx)
    Process.sleep(300)
    assert count(ctx.log, :choose) == 0 and count(ctx.log, :board) == 0
  end

  test "a selection that is no longer current never dispatches", ctx do
    queue =
      queue([
        snapshot([card("probe:aaaa11"), card("probe:bbbb22")], 1),
        snapshot([card("probe:bbbb22")], 2)
      ])

    start_brain(ctx,
      board: board_fun(ctx.log, queue),
      choose: choose_fun(ctx.log, {:ok, %{ref: "probe:aaaa11", reason: "first"}})
    )

    eventually(fn -> match?(%{state: "stale"}, Journal.latest()) end)
    assert count(ctx.log, :assign) == 0
  end

  test "a forged ref (not in the snapshot) never dispatches", ctx do
    start_brain(ctx, choose: choose_fun(ctx.log, {:ok, %{ref: "forge:ffff", reason: "invented"}}))
    eventually(fn -> match?(%{state: "stale"}, Journal.latest()) end)
    assert count(ctx.log, :assign) == 0
  end

  test "a model error releases the lease, is journaled and never retried for the same snapshot",
       ctx do
    brain = start_brain(ctx, choose: choose_fun(ctx.log, {:error, :boom}))
    eventually(fn -> match?(%{state: "error"}, Journal.latest()) end)
    assert count(ctx.log, :release) == 1

    Trailblazer.Events.publish(:planner, {:mirrored, "probe:zzzz", "block"})
    eventually(fn -> count(ctx.log, :board) >= 2 end)
    Process.sleep(300)

    assert count(ctx.log, :choose) == 1
    assert %{state: :idle, last: %{state: "error"}} = Brain.status(brain)
  end

  test "an unavailable resource runs no inference but a later event may retry", ctx do
    acquire_queue = queue([:blocked, {:ok, "lease-1"}])

    start_brain(ctx,
      choose: choose_fun(ctx.log, {:ok, %{ref: "probe:aaaa11", reason: "go"}}),
      acquire: fn lease ->
        push(ctx.log, {:acquire, lease})
        pop(acquire_queue)
      end
    )

    eventually(fn -> match?(%{state: "unavailable"}, Journal.latest()) end)
    assert count(ctx.log, :choose) == 0

    Trailblazer.Events.publish(:planner, {:resource_released, "case-1"})
    eventually(fn -> match?(%{state: "dispatched"}, Journal.latest()) end)
    assert count(ctx.log, :choose) == 1
    assert count(ctx.log, :assign) == 1
  end

  test "a failed resource cleanup fences all further work", ctx do
    brain =
      start_brain(ctx,
        choose: choose_fun(ctx.log, {:ok, %{ref: "probe:aaaa11", reason: "go"}}),
        release: fn lease ->
          push(ctx.log, {:release, lease})
          {:error, :release_unconfirmed}
        end
      )

    eventually(fn -> Brain.status(brain).state == :fenced end)
    assert count(ctx.log, :assign) == 0
    # the lease stays unresolved in the journal for restart recovery
    assert [%{state: "intent"}] = Journal.unresolved()

    Trailblazer.Events.publish(:planner, {:mirrored, "probe:zzzz", "done"})
    Process.sleep(300)
    assert count(ctx.log, :board) == 1
    assert Brain.status(brain).state == :fenced
  end

  test "restart recovers an unresolved lease and never repeats the model", ctx do
    :ok = Journal.record("fp-1", "lease-9", "intent", nil, "planning")

    start_brain(ctx, board: static_board(ctx.log, snapshot([card()], 1)))
    eventually(fn -> Journal.get("fp-1").state == "interrupted" end)

    assert [{:release, "lease-9"}] = logged(ctx.log, :release)
    assert count(ctx.log, :choose) == 0
    assert count(ctx.log, :assign) == 0
  end

  test "a confirmed release precedes the dispatch, which runs for the selected card", ctx do
    start_brain(ctx, choose: choose_fun(ctx.log, {:ok, %{ref: "probe:aaaa11", reason: "go"}}))
    eventually(fn -> match?(%{state: "dispatched"}, Journal.latest()) end)

    ops = Agent.get(ctx.log, & &1) |> Enum.reverse()
    release_at = Enum.find_index(ops, &match?({:release, _}, &1))
    assign_at = Enum.find_index(ops, &match?({:assign, _}, &1))
    assert release_at < assign_at

    assert [{:assign, "probe:aaaa11"}] = logged(ctx.log, :assign)
    assert %{state: "dispatched", ref: "probe:aaaa11"} = Journal.latest()
  end

  test "the next ready card advances when the mirror reports completion", ctx do
    queue =
      queue([
        snapshot([card("probe:aaaa11"), card("probe:bbbb22")], 1),
        snapshot([card("probe:aaaa11"), card("probe:bbbb22")], 1),
        snapshot([card("probe:bbbb22")], 2)
      ])

    choose_queue =
      queue([
        {:ok, %{ref: "probe:aaaa11", reason: "first"}},
        {:ok, %{ref: "probe:bbbb22", reason: "second"}}
      ])

    start_brain(ctx,
      board: board_fun(ctx.log, queue),
      choose: choose_fun(ctx.log, {:queue, choose_queue})
    )

    eventually(fn -> count(ctx.log, :assign) == 1 end)
    Trailblazer.Events.publish(:planner, {:mirrored, "probe:aaaa11", "done"})
    eventually(fn -> count(ctx.log, :assign) == 2 end)

    assert Enum.map(logged(ctx.log, :assign), &elem(&1, 1)) == ["probe:aaaa11", "probe:bbbb22"]
  end

  test "events while busy coalesce into one follow-up cycle", ctx do
    blocking_board = fn _config ->
      first = count(ctx.log, :board) == 0
      push(ctx.log, {:board, self()})

      if first do
        receive do
          :go -> {:ok, snapshot([card()], 1)}
        end
      else
        {:ok, snapshot([card()], 1)}
      end
    end

    brain = start_brain(ctx, board: blocking_board, choose: choose_fun(ctx.log, {:ok, :wait}))
    eventually(fn -> count(ctx.log, :board) == 1 end)

    for _ <- 1..3, do: Brain.wake(brain)

    for _ <- 1..2, do: Trailblazer.Events.publish(:planner, {:mirrored, "r", "done"})

    [{:board, worker}] = logged(ctx.log, :board)
    send(worker, :go)

    eventually(fn -> count(ctx.log, :board) == 2 end)
    Process.sleep(300)

    assert count(ctx.log, :board) == 2
    assert count(ctx.log, :choose) == 1
  end

  test "an unchanged snapshot is inferred once, not again", ctx do
    brain = start_brain(ctx)
    eventually(fn -> count(ctx.log, :board) == 1 end)

    Trailblazer.Events.publish(:planner, {:mirrored, "probe:zzzz", "done"})
    eventually(fn -> count(ctx.log, :board) == 2 end)
    Process.sleep(300)

    assert count(ctx.log, :choose) == 1
    assert Brain.status(brain).state == :idle
  end

  test "a disabled brain (nil config) does nothing and reports itself", ctx do
    brain = start_brain(ctx, config: nil)
    Process.sleep(300)

    assert %{state: :disabled, watcher: :off} = Brain.status(brain)
    assert count(ctx.log, :board) == 0

    :ok = Brain.wake(brain)
    Process.sleep(200)
    assert count(ctx.log, :board) == 0
  end

  test "status carries the model, the last decision and watcher health without secrets", ctx do
    brain = start_brain(ctx)
    eventually(fn -> match?(%{state: "wait"}, Journal.latest()) end)

    status = Brain.status(brain)
    assert status.model == Trailblazer.Config.get(:code_model)
    assert status.watcher == :off
    assert %{state: "wait"} = status.last
    refute Map.has_key?(status, :token)
    refute Map.has_key?(status, :api_key)
  end

  test "a real inotify port delivers actual board changes to the brain", ctx do
    state_dir = Path.join(ctx.dir, "state")
    refs = Path.join([state_dir, ".git", "refs", "bugs"])
    File.mkdir_p!(refs)

    brain =
      start_brain(ctx,
        config: %{repos: %{state_dir => ["true"]}, planner: {"/bin/true", []}},
        start_watcher: nil
      )

    eventually(fn -> count(ctx.log, :board) == 1 end)
    eventually(fn -> Brain.status(brain).watcher == :ready end)
    File.write!(Path.join(refs, "fixture-ref"), "changed\n")
    eventually(fn -> count(ctx.log, :board) >= 2 end, 200)
    Process.sleep(100)
    reads = count(ctx.log, :board)
    Process.sleep(200)
    assert count(ctx.log, :board) == reads
    assert count(ctx.log, :choose) == 1
  end

  test "a dead watcher is visible and does not crash or block the brain", ctx do
    # the state directory cannot be created: the watcher fails for real
    brain =
      start_brain(ctx,
        config: %{repos: %{}, planner: {"/bin/true", []}, state_dir: "/dev/null/planner-state"},
        board: static_board(ctx.log, snapshot([], 1)),
        start_watcher: nil
      )

    eventually(fn -> count(ctx.log, :board) == 1 end)
    assert match?({:down, _}, Brain.status(brain).watcher)
    assert Brain.status(brain).state == :idle

    Trailblazer.Events.publish(:planner, {:mirrored, "r", "done"})
    eventually(fn -> count(ctx.log, :board) == 2 end)
    assert Process.alive?(brain)
  end

  test "the supervisor adds the brain after tasks and companion only when configured", ctx do
    cli = Path.join(ctx.dir, "planner")
    File.write!(cli, "#!/bin/sh\nprintf '{}'\n")
    File.chmod!(cli, 0o755)

    Application.put_env(:trailblazer, :planner, %{
      repos: %{},
      planner: {cli, []},
      state_dir: ctx.dir
    })

    on_exit(fn -> Application.delete_env(:trailblazer, :planner) end)

    start_supervised!(
      {Trailblazer.Planner.Supervisor,
       name: :planner_sup_test,
       tasks: :planner_sup_tasks,
       companion_name: :planner_sup_companion,
       brain_name: :planner_sup_brain,
       planner: {cli, []}}
    )

    assert Process.whereis(:planner_sup_tasks)
    assert Process.whereis(:planner_sup_companion)
    assert Process.whereis(:planner_sup_brain)

    stop_supervised!(Trailblazer.Planner.Supervisor)
    Application.delete_env(:trailblazer, :planner)

    start_supervised!(
      {Trailblazer.Planner.Supervisor,
       name: :planner_sup_test2,
       tasks: :planner_sup_tasks2,
       companion_name: :planner_sup_companion2,
       brain_name: :planner_sup_brain2,
       planner: {cli, []}},
      id: :planner_sup2
    )

    refute Process.whereis(:planner_sup_brain2)
  end

  test "an asynchronous unload retains the decision and rechecks after SSE headers", ctx do
    parent = self()
    releases = queue([{:error, :release_unconfirmed}, :ok])

    brain =
      start_brain(ctx,
        choose: choose_fun(ctx.log, {:ok, %{ref: "probe:aaaa11", reason: "go"}}),
        release: fn lease ->
          push(ctx.log, {:release, lease})
          pop(releases)
        end,
        start_sse: fn _ ->
          port = Port.open({:spawn_executable, ~c"/bin/cat"}, [:binary, :exit_status])
          send(parent, {:stream, self(), port})
          {:ok, port}
        end
      )

    assert_receive {:stream, ^brain, port}, 5_000
    assert count(ctx.log, :assign) == 0
    send(brain, {port, {:data, {:eol, "HTTP/1.1 200 OK\r"}}})
    send(brain, {port, {:data, {:eol, "\r"}}})
    eventually(fn -> match?(%{state: "dispatched"}, Journal.latest()) end)
    assert count(ctx.log, :choose) == 1
    assert count(ctx.log, :release) == 2
    assert count(ctx.log, :assign) == 1
  end

  test "same ref with edited context is stale and never dispatched", ctx do
    snapshots = queue([snapshot([card()], 1), snapshot([card()], 2)])

    start_brain(ctx,
      board: board_fun(ctx.log, snapshots),
      choose: choose_fun(ctx.log, {:ok, %{ref: "probe:aaaa11", reason: "go"}})
    )

    eventually(fn -> match?(%{state: "stale"}, Journal.latest()) end)
    assert count(ctx.log, :assign) == 0
  end

  test "lease intent is durable before acquire and false bridge flags mean idle", ctx do
    start_brain(ctx,
      bridge_status: fn -> %{active: nil, resource_release_blocked: false, requests: []} end,
      acquire: fn lease ->
        assert %{lease: ^lease, state: "intent"} = Journal.latest()
        {:ok, lease}
      end
    )

    eventually(fn -> match?(%{state: "wait"}, Journal.latest()) end)
    assert count(ctx.log, :choose) == 1
  end

  test "a missed unload notice gets one bounded cleanup investigation without inference replay",
       ctx do
    releases = queue([{:error, :release_unconfirmed}, :ok])

    start_brain(ctx,
      drain_limit_ms: 50,
      choose: choose_fun(ctx.log, {:ok, %{ref: "probe:aaaa11", reason: "go"}}),
      release: fn lease ->
        push(ctx.log, {:release, lease})
        pop(releases)
      end,
      start_sse: fn _ ->
        {:ok, Port.open({:spawn_executable, ~c"/bin/cat"}, [:binary, :exit_status])}
      end
    )

    eventually(fn -> match?(%{state: "dispatched"}, Journal.latest()) end)
    assert count(ctx.log, :choose) == 1
    assert count(ctx.log, :release) == 2
    assert count(ctx.log, :assign) == 1
  end

  test "a planning task crash restarts its OTP group and recovers the lease without model replay",
       ctx do
    {acquire, release} = resource_funs(ctx.log)

    opts = [
      name: :brain_crash,
      config: ctx.config,
      tasks: :brain_crash_tasks,
      board: static_board(ctx.log, snapshot([card()], 1)),
      choose: fn _ ->
        push(ctx.log, {:choose, nil})
        exit(:fixture_failure)
      end,
      acquire: acquire,
      release: release,
      bridge_status: idle_bridge(),
      start_watcher: fn _ -> :off end
    ]

    children = [{Task.Supervisor, name: :brain_crash_tasks}, {Brain, opts}]

    start_supervised!(%{
      id: :crash_group,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_all]]}
    })

    eventually(fn -> match?(%{state: "interrupted"}, Journal.latest()) end)
    assert count(ctx.log, :choose) == 1
    assert count(ctx.log, :release) == 1
    assert Process.alive?(Process.whereis(:brain_crash))
    assert Task.Supervisor.children(:brain_crash_tasks) == []
  end
end
