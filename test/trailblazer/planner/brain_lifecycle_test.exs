defmodule Trailblazer.Planner.BrainLifecycleTest do
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
      context: %{
        "ref" => ref,
        "title" => "t",
        "priority" => "p1",
        # both markers: the deterministic routing check says trailblazer
        "body" =>
          "Files: lib/x.ex\nAcceptance: make test\nImplementation plan: Change x.ex and assert its new behavior.",
        "recent" => []
      }
    }
  end

  defp research_card(ref \\ "probe:aaaa11"), do: card(ref) |> put_body("needs investigation")

  defp tie_card(ref \\ "probe:aaaa11"),
    do:
      card(ref)
      |> put_body(
        "Files: lib/x.ex\nImplementation plan: Change x.ex and assert the new behavior."
      )

  defp put_body(%{context: context} = card, body),
    do: %{card | context: Map.put(context, "body", body)}

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

  defp start_brain(ctx, extra) do
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

  test "a research card dispatches through the research fun, never the coder", ctx do
    start_brain(ctx,
      board: static_board(ctx.log, snapshot([research_card()], 1)),
      choose:
        choose_fun(
          ctx.log,
          {:ok, %{ref: "probe:aaaa11", target: "research", reason: "needs a plan"}}
        ),
      research: fn given ->
        push(ctx.log, {:research, given.ref})
        :ok
      end
    )

    eventually(fn -> match?(%{state: "dispatched"}, Journal.latest()) end)
    assert [{:research, "probe:aaaa11"}] = logged(ctx.log, :research)
    assert count(ctx.log, :assign) == 0
  end

  test "a research card keeps its route even when the model names the coder", ctx do
    start_brain(ctx,
      board: static_board(ctx.log, snapshot([research_card()], 1)),
      choose:
        choose_fun(ctx.log, {:ok, %{ref: "probe:aaaa11", target: "trailblazer", reason: "r"}}),
      research: fn given ->
        push(ctx.log, {:research, given.ref})
        :ok
      end
    )

    eventually(fn -> match?(%{state: "dispatched"}, Journal.latest()) end)
    assert [{:research, "probe:aaaa11"}] = logged(ctx.log, :research)
    assert count(ctx.log, :assign) == 0
  end

  test "a checked card with a model research target journals an error and dispatches nothing",
       ctx do
    start_brain(ctx,
      board: static_board(ctx.log, snapshot([card()], 1)),
      choose: choose_fun(ctx.log, {:ok, %{ref: "probe:aaaa11", target: "research", reason: "r"}}),
      research: fn given ->
        push(ctx.log, {:research, given.ref})
        :ok
      end
    )

    eventually(fn -> match?(%{state: "error"}, Journal.latest()) end)
    assert logged(ctx.log, :research) == []
    assert count(ctx.log, :assign) == 0
  end

  test "the model target decides a tie: a research target calls the research fun", ctx do
    start_brain(ctx,
      board: static_board(ctx.log, snapshot([tie_card()], 1)),
      choose: choose_fun(ctx.log, {:ok, %{ref: "probe:aaaa11", target: "research", reason: "r"}}),
      research: fn given ->
        push(ctx.log, {:research, given.ref})
        :ok
      end
    )

    eventually(fn -> match?(%{state: "dispatched"}, Journal.latest()) end)
    assert [{:research, "probe:aaaa11"}] = logged(ctx.log, :research)
    assert count(ctx.log, :assign) == 0
  end

  test "the model target decides a tie: a trailblazer target assigns the worker", ctx do
    start_brain(ctx,
      board: static_board(ctx.log, snapshot([tie_card()], 1)),
      choose:
        choose_fun(ctx.log, {:ok, %{ref: "probe:aaaa11", target: "trailblazer", reason: "r"}}),
      research: fn given ->
        push(ctx.log, {:research, given.ref})
        :ok
      end
    )

    eventually(fn -> match?(%{state: "dispatched"}, Journal.latest()) end)
    assert logged(ctx.log, :research) == []
    assert count(ctx.log, :assign) == 1
  end

  test "a busy research lease journals unavailable and a later event retries it", ctx do
    start_brain(ctx,
      board: static_board(ctx.log, snapshot([research_card()], 1)),
      choose: choose_fun(ctx.log, {:ok, %{ref: "probe:aaaa11", target: "research", reason: "r"}}),
      research: fn given ->
        push(ctx.log, {:research, given.ref})
        {:error, :busy}
      end
    )

    eventually(fn -> match?(%{state: "unavailable"}, Journal.latest()) end)
    assert count(ctx.log, :assign) == 0

    Trailblazer.Events.publish(:planner, {:mirrored, "probe:zzzz", "block"})
    eventually(fn -> count(ctx.log, :research) == 2 end)
  end

  test "a failed research dispatch holds the card and a trailblazer card keeps flowing", ctx do
    board =
      queue([
        snapshot([research_card()], 1),
        snapshot([research_card()], 1),
        snapshot([card()], 2)
      ])

    start_brain(ctx,
      board: board_fun(ctx.log, board),
      choose:
        choose_fun(
          ctx.log,
          {:queue,
           queue([
             {:ok, %{ref: "probe:aaaa11", target: "research", reason: "r"}},
             {:ok, %{ref: "probe:aaaa11", target: "trailblazer", reason: "r"}}
           ])}
        ),
      research: fn given ->
        push(ctx.log, {:research, given.ref})
        {:error, :vortex_refused}
      end
    )

    eventually(fn -> match?(%{state: "assign_failed"}, Journal.latest()) end)
    assert count(ctx.log, :assign) == 0

    Trailblazer.Events.publish(:planner, {:mirrored, "probe:zzzz", "block"})

    eventually(fn -> match?(%{state: "dispatched"}, Journal.latest()) end)
    assert count(ctx.log, :assign) == 1
  end
end
