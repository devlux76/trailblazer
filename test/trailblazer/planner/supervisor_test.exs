defmodule Trailblazer.Planner.SupervisorTest do
  # Phase 7 (trailblazer:4cc63df): the research server joins the planner group
  # next to the brain when the planner is configured, and the brain's default
  # research dispatch is the research server — a research card really
  # dispatches without an injected fun, through the vortex endpoint transport.
  use ExUnit.Case, async: false
  alias Trailblazer.Planner.{Journal, Research, Supervisor}

  @peer "12D3KooWTestOtherPeer"

  setup do
    Trailblazer.CaseStore.transaction(fn conn ->
      for ddl <- [
            "CREATE TABLE IF NOT EXISTS planner_brain (fingerprint TEXT PRIMARY KEY, lease TEXT NOT NULL, state TEXT NOT NULL, ref TEXT, reason TEXT NOT NULL, at INTEGER NOT NULL)",
            "CREATE TABLE IF NOT EXISTS planner_research (ref TEXT PRIMARY KEY, lease TEXT NOT NULL, state TEXT NOT NULL, conference TEXT, children TEXT, children_done INTEGER NOT NULL, reason TEXT NOT NULL, at INTEGER NOT NULL)"
          ],
          do: Exqlite.query!(conn, ddl, [], timeout: :infinity)

      for table <- ~w(planner_brain planner_research),
          do: Exqlite.query!(conn, "DELETE FROM #{table}", [], timeout: :infinity)
    end)

    {:ok, log} = Agent.start_link(fn -> [] end)

    config = %Trailblazer.Planner.Board{
      repos: %{},
      planner: {"/bin/true", []},
      research: %{peer: @peer, actor: "research", session: "trailblazer"}
    }

    prev_planner = Application.get_env(:trailblazer, :planner)
    prev_vortex = Application.get_env(:trailblazer, :vortex)

    on_exit(fn ->
      Application.put_env(:trailblazer, :planner, prev_planner)
      Application.put_env(:trailblazer, :vortex, prev_vortex)
    end)

    %{
      log: log,
      config: config
    }
    |> tap(fn _ -> start_supervised!({Task.Supervisor, name: :planner_resolver_tasks}) end)
  end

  defp push(log, op), do: Agent.update(log, &[op | &1])

  defp logged(log, op),
    do: log |> Agent.get(& &1) |> Enum.reverse() |> Enum.filter(&(elem(&1, 0) == op))

  defp eventually(fun, n \\ 100) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && eventually(fun, n - 1)
    end
  end

  ## Group wiring

  test "the research server joins the planner group when the planner is configured", ctx do
    Application.put_env(:trailblazer, :planner, ctx.config)
    sup =
      start_supervised!(
        {Supervisor,
         name: :planner_supervisor_resolver,
         brain_opts: [
           bridge_status: fn -> %{active: nil, resource_release_blocked: nil, requests: []} end,
           start_watcher: fn _config -> :off end,
           start_sse: fn _ -> {:error, :test_stream_unavailable} end
         ]}
      )

    ids = children(sup)
    assert Trailblazer.Planner.Research in ids
    assert Trailblazer.Planner.Brain in ids
    assert Process.whereis(Trailblazer.Planner.Research) != nil
  end

  test "an unconfigured planner gains no research or brain child", _ctx do
    Application.put_env(:trailblazer, :planner, nil)
    sup = start_supervised!({Supervisor, name: :planner_supervisor_empty})

    ids = children(sup)
    refute Trailblazer.Planner.Research in ids, inspect(ids)
    refute Trailblazer.Planner.Brain in ids, inspect(ids)
    assert Trailblazer.Planner.Companion in ids
  end

  ## The brain's default research dispatch

  defp research_card, do: research_card("probe:aaaa11")

  defp research_card(ref) do
    %{
      ref: ref,
      check: "make test",
      repo: "/tmp/repo",
      context: %{"ref" => ref, "title" => "Feather the research route", "body" => "needs a plan"}
    }
  end

  defp snapshot(cards, n), do: %{fingerprint: "fp-#{n}", cards: cards}

  defp static_board(log, file),
    do: fn _config -> push(log, {:board, nil}) && {:ok, file} end

  defp choose_fun(log, result),
    do: fn _ -> push(log, {:choose, []}) && result end

  defp transport_fun do
    fn
      "create", _args -> %{"conference" => "conf-7"}
      _op, _args -> %{}
    end
  end

  defp children(sup),
    do: sup |> :supervisor.which_children() |> Enum.map(&elem(&1, 0))

  defp run_fun(log) do
    fn args ->
      push(log, {:run, args})
      %{status: :pass}
    end
  end

  test "a research card dispatches through the real research server, no injected fun", ctx do
    start_supervised!({
      Research,
      config: ctx.config,
      transport: transport_fun(),
      run: run_fun(ctx.log),
      peer_busy: fn _ -> :idle end
    })

    acquire = fn lease -> push(ctx.log, {:acquire, lease}) && {:ok, lease} end
    release = fn lease -> push(ctx.log, {:release, lease}) && :ok end

    start_supervised!(%{
      id: :default_research_brain,
      start: {
        GenServer,
        :start_link,
        [
          Trailblazer.Planner.Brain,
          [
            name: nil,
            config: ctx.config,
            tasks: :planner_resolver_tasks,
            board: static_board(ctx.log, snapshot([research_card()], 1)),
            choose:
              choose_fun(
                ctx.log,
                {:ok, %{ref: "probe:aaaa11", target: "research", reason: "needs a plan"}}
              ),
            assign: fn _config, _card -> flunk("a research card never assigns the coder") end,
            acquire: acquire,
            release: release,
            bridge_status: fn -> %{active: nil, resource_release_blocked: nil, requests: []} end,
            start_sse: fn _ -> {:error, :test_stream_unavailable} end,
            start_watcher: fn _config -> :off end
          ]
        ]
      }
    })

    eventually(fn -> match?(%{state: "dispatched"}, Journal.latest()) end)
    assert %{ref: "probe:aaaa11", state: "dispatched"} = Journal.latest()

    # The claim ran on the research server's own runner.
    assert [{:run, claim_args}] = logged(ctx.log, :run)
    assert "start" in claim_args
    assert "probe:aaaa11" in claim_args
  end

  ## The vortex endpoint is the research route's own transport

  test "without an injected transport the configured vortex endpoint serves the ops", ctx do
    Application.put_env(:trailblazer, :vortex, %{endpoint: "/tmp/opencode/missing-endpoint-file"})

    start_supervised!(
      {Research, config: ctx.config, run: run_fun(ctx.log), peer_busy: fn _ -> :idle end}
    )

    assert {:error, {:create, :transport_unavailable}} =
             Research.dispatch(ctx.config, research_card())

    assert %{state: "held", reason: reason} = Research.row("probe:aaaa11")
    assert reason =~ "create failed"
  end
end
