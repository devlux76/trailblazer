defmodule Trailblazer.Planner.ResearchReplyTest do
  # The research route's server: the planner brain routes a card here, the
  # card is claimed for the research actor, one VORTEX conference carries the
  # brief to the peer, and the peer's reply becomes child cards on the
  # admitted repositories. Every external effect is an injected function;
  # the journal is the real cases.db store.
  use ExUnit.Case, async: false
  alias Trailblazer.{CaseStore, Events}
  alias Trailblazer.Planner.{Board, Research}

  @peer "12D3KooWTestPeerIdentity1"
  @repo_path "#{System.tmp_dir!()}/research-test-#{System.unique_integer([:positive])}"
  @repo_name Path.basename(@repo_path)

  setup do
    CaseStore.transaction(fn conn ->
      Research.schema(conn)
      Exqlite.query!(conn, "DELETE FROM planner_research", [], timeout: :infinity)
    end)

    File.mkdir_p!(@repo_path)
    on_exit(fn -> File.rm_rf!(@repo_path) end)

    {:ok, log} = Agent.start_link(fn -> [] end)

    config = %Board{
      repos: %{@repo_path => ["make check"]},
      planner: {"/bin/true", []},
      research: %{peer: @peer, actor: "research", session: "trailblazer"}
    }

    %{log: log, config: config}
  end

  ## Fakes (every one is an external-effect boundary; the journal stays real)

  defp push(log, op), do: Agent.update(log, &[op | &1])

  defp logged(log, op),
    do: log |> Agent.get(& &1) |> Enum.reverse() |> Enum.filter(&(elem(&1, 0) == op))

  defp eventually(fun, n \\ 100) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition never held")
      true -> Process.sleep(30) && eventually(fun, n - 1)
    end
  end

  defp card do
    %{
      ref: "trailblazer:rr11aa",
      check: "make check",
      repo: @repo_name,
      context: %{
        "ref" => "trailblazer:rr11aa",
        "title" => "Feather the research route",
        "body" => "needs a plan for the reply contract"
      }
    }
  end

  defp other_card(ref) do
    %{card() | ref: ref, context: Map.put(card().context, "ref", ref)}
  end

  defp transport_fun(log, overrides \\ %{}) do
    fn op, args ->
      push(log, {String.to_atom(op), args})
      Map.get(overrides, op, default_reply(op))
    end
  end

  defp default_reply("create"), do: %{"conference" => "conf-1"}
  defp default_reply(_), do: %{}

  defp run_fun(log) do
    fn args ->
      push(log, {:run, args})
      command = command_of(args)

      case command do
        "add" -> %{status: :pass, output_tail: ~s({"ref":"#{@repo_name}:bab001","column":"todo"})}
        _ -> %{status: :pass}
      end
    end
  end

  defp command_of(args) do
    args
    |> Enum.with_index()
    |> Enum.drop(1)
    |> Kernel.++([])
    |> Enum.find_value(fn {a, i} ->
      if Enum.at(args, i - 1) != "--plan" and a in ~w(start add note block done), do: a
    end)
  end

  defp label_fun(log) do
    fn path, bug, label ->
      push(log, {:label, path, bug, label})
      :ok
    end
  end

  defp start_research(ctx, extra \\ []) do
    opts =
      Keyword.merge(
        [
          config: ctx.config,
          transport: transport_fun(ctx.log),
          run: run_fun(ctx.log),
          label: label_fun(ctx.log),
          peer_busy: fn _config -> :idle end
        ],
        extra
      )

    # The child_spec registers the server under its own name, which is the
    # same name dispatch/2 calls.
    start_supervised!({Research, opts})
  end

  defp reply(conference, body) do
    Events.publish(:planner, {
      :research_conference,
      %{"conference" => conference, "peer" => @peer, "body" => body, "cursor" => 9}
    })
  end

  defp seed_row(ref, state, children, conference) do
    CaseStore.transaction(fn conn ->
      Research.schema(conn)

      Exqlite.query!(
        conn,
        "INSERT OR REPLACE INTO planner_research (ref, lease, state, conference, children, children_done, reason, at) VALUES (?, '', ?, ?, ?, 0, '', ?)",
        [ref, state, conference, children, System.os_time(:millisecond)],
        timeout: :infinity
      )
    end)
  end

  defp arg_after(args, key) when is_map(args), do: Map.get(args, key)
  defp arg_after(args, flag), do: push_value(args, flag)

  defp push_value(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      i -> Enum.at(args, i + 1)
    end
  end

  ## dispatch

  ## Replies

  test "a valid reply adds labelled children and journals the parent done research", ctx do
    start_research(ctx)
    assert :ok = Research.dispatch(ctx.config, card())

    children = [
      %{
        "title" => "child one",
        "repo" => @repo_name,
        "files" => ["lib/a.ex"],
        "plan" => ["Change the named file and assert the requested behavior in its test"],
        "acceptance" => "make test",
        "priority" => "p1"
      },
      %{
        "title" => "child two",
        "repo" => @repo_name,
        "files" => ["lib/b.ex"],
        "plan" => ["Change the named file and assert the requested behavior in its test"],
        "acceptance" => "make test"
      }
    ]

    reply("conf-1", Jason.encode!(%{"parent" => "trailblazer:rr11aa", "children" => children}))

    eventually(fn -> match?(%{state: "researched"}, Research.row("trailblazer:rr11aa")) end)
    row = Research.row("trailblazer:rr11aa")
    assert row.children == ["#{@repo_name}:bab001", "#{@repo_name}:bab001"]
    assert row.children_done == 0

    adds =
      logged(ctx.log, :run)
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&("add" in &1))

    assert length(adds) == 2

    plans =
      Enum.map(
        adds,
        &[arg_after(&1, "--title"), arg_after(&1, "--plan"), arg_after(&1, "--priority")]
      )

    assert ["child one", plan_one, "p1"] = Enum.at(plans, 0)
    assert plan_one =~ "Files: lib/a.ex"
    assert plan_one =~ "Acceptance: make test"
    assert plan_one =~ "Implementation plan: 1. Change the named file"
    assert plan_one =~ "trailblazer:rr11aa"
    assert ["child two", plan_two, "p2"] = Enum.at(plans, 1)
    assert plan_two =~ "Files: lib/b.ex"

    assert [
             {:label, @repo_path, "bab001", "dispatch:ready"},
             {:label, @repo_path, "bab001", "dispatch:ready"}
           ] = logged(ctx.log, :label)

    notes =
      logged(ctx.log, :run)
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&("note" in &1))

    assert length(notes) == 1
    note_text = hd(notes) |> Enum.join(" ")
    assert note_text =~ ~s(trailblazer:rr11aa)
    assert note_text =~ "children"
  end

  test "a files-and-acceptance reply without a plan is blocked before child creation", ctx do
    start_research(ctx)
    assert :ok = Research.dispatch(ctx.config, card())

    reply(
      "conf-1",
      Jason.encode!(%{
        "parent" => "trailblazer:rr11aa",
        "children" => [
          %{
            "title" => "unplanned",
            "repo" => @repo_name,
            "files" => ["lib/a.ex"],
            "acceptance" => "make test"
          }
        ]
      })
    )

    eventually(fn -> match?(%{state: "blocked"}, Research.row("trailblazer:rr11aa")) end)
    assert Research.row("trailblazer:rr11aa").reason =~ "no implementation plan"
    refute Enum.any?(logged(ctx.log, :run), fn {_, args} -> "add" in args end)
  end

  test "children off the contract drop with a reason and none valid blocks the parent", ctx do
    start_research(ctx)
    assert :ok = Research.dispatch(ctx.config, card())

    reply(
      "conf-1",
      Jason.encode!(%{
        "parent" => "trailblazer:rr11aa",
        "children" => [
          %{
            "title" => "off-piste",
            "repo" => "somewhere-else",
            "files" => ["a.ex"],
            "plan" => ["Change the named file and assert the requested behavior in its test"],
            "acceptance" => "t"
          },
          %{
            "title" => "too thin",
            "repo" => @repo_name,
            "files" => [],
            "plan" => ["Change the named file and assert the requested behavior in its test"],
            "acceptance" => "t"
          },
          %{
            "title" => "researchy again",
            "repo" => @repo_name,
            "files" => ["lib/c.ex"],
            "plan" => ["Change the named file and assert the requested behavior in its test"],
            "acceptance" => "",
            "labels" => ["dispatch:research"]
          }
        ]
      })
    )

    eventually(fn -> match?(%{state: "blocked"}, Research.row("trailblazer:rr11aa")) end)
    assert Research.row("trailblazer:rr11aa").children == []
    assert Research.row("trailblazer:rr11aa").reason =~ "dropped"

    blocks =
      logged(ctx.log, :run)
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&("block" in &1))

    assert length(blocks) == 1
    assert "trailblazer:rr11aa" in hd(blocks)
  end

  test "a partially valid reply adds the good children and journals the drops", ctx do
    start_research(ctx)
    assert :ok = Research.dispatch(ctx.config, card())

    reply(
      "conf-1",
      Jason.encode!(%{
        "parent" => "trailblazer:rr11aa",
        "children" => [
          %{
            "title" => "keep me",
            "repo" => @repo_name,
            "files" => ["lib/a.ex"],
            "plan" => ["Change the named file and assert the requested behavior in its test"],
            "acceptance" => "make"
          },
          %{
            "title" => "meaningless",
            "repo" => @repo_name,
            "files" => ["../ escape.ex"],
            "plan" => ["Change the named file and assert the requested behavior in its test"],
            "acceptance" => "t"
          }
        ]
      })
    )

    eventually(fn -> match?(%{state: "researched"}, Research.row("trailblazer:rr11aa")) end)
    row = Research.row("trailblazer:rr11aa")
    assert row.children == ["#{@repo_name}:bab001"]
    assert row.reason =~ "dropped"
  end

  test "non-JSON and foreign-parent replies on a waiting row change nothing", ctx do
    start_research(ctx)
    assert :ok = Research.dispatch(ctx.config, card())

    reply("conf-1", "just prose, no JSON")
    Process.sleep(100)
    assert %{state: "waiting"} = Research.row("trailblazer:rr11aa")

    reply(
      "conf-1",
      Jason.encode!(%{
        "parent" => "trailblazer:other00",
        "children" => [
          %{
            "title" => "keep",
            "repo" => @repo_name,
            "files" => ["a.ex"],
            "plan" => ["Change the named file and assert the requested behavior in its test"],
            "acceptance" => "t"
          }
        ]
      })
    )

    Process.sleep(100)
    assert %{state: "waiting", children: []} = Research.row("trailblazer:rr11aa")
  end

  test "no valid reply within the limit holds and frees the slot", ctx do
    start_research(ctx, reply_limit_ms: 40)
    assert :ok = Research.dispatch(ctx.config, card())
    eventually(fn -> match?(%{state: "held"}, Research.row("trailblazer:rr11aa")) end)
    assert Research.row("trailblazer:rr11aa").reason =~ "no reply"

    assert :ok = Research.dispatch(ctx.config, other_card("trailblazer:zz22bb"))
    assert %{state: "waiting"} = Research.row("trailblazer:zz22bb")
  end

  test "done children complete the parent once every child is done", ctx do
    seed_row(
      "trailblazer:rr11aa",
      "researched",
      ~s(["#{@repo_name}:one", "#{@repo_name}:two"]),
      "conf-x"
    )

    start_research(ctx)

    Events.publish(:planner, {:mirrored, "#{@repo_name}:one", "done"})
    Process.sleep(100)
    assert %{children_done: 1} = Research.row("trailblazer:rr11aa")

    Events.publish(:planner, {:mirrored, "#{@repo_name}:two", "done"})

    eventually(fn ->
      logged(ctx.log, :run)
      |> Enum.map(&elem(&1, 1))
      |> Enum.any?(&("done" in &1))
    end)

    dones =
      logged(ctx.log, :run)
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&("done" in &1))

    assert length(dones) == 1
    assert "trailblazer:rr11aa" in hd(dones)
    assert hd(dones) |> Enum.join(" ") =~ "#{@repo_name}:one"
    assert hd(dones) |> Enum.join(" ") =~ "#{@repo_name}:two"
  end
end
