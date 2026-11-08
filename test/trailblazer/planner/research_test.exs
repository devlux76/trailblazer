defmodule Trailblazer.Planner.ResearchTest do
  # The research route's server: the planner brain routes a card here, the
  # card is claimed for the research actor, one VORTEX conference carries the
  # brief to the peer, and the peer's reply becomes child cards on the
  # admitted repositories. Every external effect is an injected function;
  # the journal is the real cases.db store.
  use ExUnit.Case, async: false
  alias Trailblazer.CaseStore
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

  defp count(log, op), do: length(logged(log, op))

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

  defp failing_run_fun(log, command, tail) do
    fn args ->
      push(log, {:run, args})

      if command_of(args) == command,
        do: %{status: :fail, output_tail: tail},
        else: %{status: :pass}
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

  defp seed_row(ref, state, children \\ "[]", conference \\ "") do
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

  test "dispatch claims the card, opens one conference and journals waiting", ctx do
    start_research(ctx)

    assert :ok = Research.dispatch(ctx.config, card())

    assert %{ref: "trailblazer:rr11aa", state: "waiting", conference: "conf-1"} =
             Research.row("trailblazer:rr11aa")

    assert [{:run, claim_args}] = logged(ctx.log, :run)
    assert arg_after(claim_args, "--actor") == "research"
    assert "start" in claim_args
    assert "trailblazer:rr11aa" in claim_args
    assert arg_after(claim_args, "--plan") =~ "research: Feather the research route"

    # one conference create, one brief post, one durable subscription and one
    # peer wake — each exactly once
    assert [{:create, create_args}] = logged(ctx.log, :create)
    assert arg_after(create_args, "session") == "trailblazer"
    assert List.wrap(arg_after(create_args, "peers")) == [@peer]
    assert arg_after(create_args, "admission") == "invitation"
    assert count(ctx.log, :post) == 1
    assert count(ctx.log, :subscribe) == 1
    assert count(ctx.log, :send) == 1

    assert [{:post, post_args}] = logged(ctx.log, :post)
    assert arg_after(post_args, "conference") == "conf-1"
    assert arg_after(post_args, "peer") in [nil, @peer]
    brief = arg_after(post_args, "text")
    assert is_binary(brief)
    assert brief =~ "trailblazer:rr11aa"
    assert brief =~ "needs a plan for the reply contract"
    assert brief =~ @repo_name
    contract = Jason.decode!(brief)["contract"]
    assert contract =~ "children"
    assert contract =~ "Files:"
    assert contract =~ "Acceptance:"
    refute Regex.match?(~r/model/i, brief)

    sends = logged(ctx.log, :send)
    assert length(sends) == 1
    assert arg_after(elem(hd(sends), 1), "peer") == @peer

    # the serial slot is held by the waiting row: a second dispatch refuses
    assert {:error, :busy} = Research.dispatch(ctx.config, other_card("trailblazer:zz22bb"))
  end

  ## OpenCode busy elsewhere (trailblazer:4657430)

  defmodule FakeOpenCode do
    import Plug.Conn
    def init(body), do: body

    def call(conn, body),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  defp fake_opencode(body) do
    pid = start_supervised!({Bandit, plug: {FakeOpenCode, body}, port: 0, ip: :loopback})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  # The real check, with the board's doing column answered by `rows`.
  defp board_run_fun(log, rows) do
    fn args ->
      if List.first(args) == "board" do
        push(log, {:board, args})
        %{status: :pass, output_tail: Jason.encode!(%{"cards" => rows})}
      else
        run_fun(log).(args)
      end
    end
  end

  defp start_with_opencode(ctx, url, rows) do
    start_research(ctx,
      run: board_run_fun(ctx.log, rows),
      peer_busy: nil,
      opencode_url: url
    )
  end

  test "an injected busy peer holds the card: nothing is claimed or announced", ctx do
    start_research(ctx, peer_busy: fn _ -> {:busy, "OpenCode has 1 running session(s)"} end)

    assert {:error, :busy} = Research.dispatch(ctx.config, card())
    assert logged(ctx.log, :run) == []
    assert logged(ctx.log, :create) == []
    assert Research.row(card().ref) == nil
  end

  test "an OpenCode with a running session holds research", ctx do
    url = fake_opencode(~s({"data":{"ses_1":{"status":"busy"}}}))
    start_with_opencode(ctx, url, [])

    assert {:error, :busy} = Research.dispatch(ctx.config, card())
    assert logged(ctx.log, :create) == []
  end

  test "a card in progress under OpenCode's actor holds research", ctx do
    url = fake_opencode(~s({"data":{}}))
    start_with_opencode(ctx, url, [["vortex:abc1234", "opencode", "p1"]])

    assert {:error, :busy} = Research.dispatch(ctx.config, card())
    assert logged(ctx.log, :create) == []
  end

  test "an unreachable OpenCode holds research rather than guessing it idle", ctx do
    start_with_opencode(ctx, "http://127.0.0.1:9", [])

    assert {:error, :busy} = Research.dispatch(ctx.config, card())
    assert logged(ctx.log, :run) == []
  end

  test "an idle OpenCode with nothing held lets research dispatch", ctx do
    url = fake_opencode(~s({"data":{}}))
    start_with_opencode(ctx, url, [["vortex:abc1234", "codex", "p1"]])

    assert :ok = Research.dispatch(ctx.config, card())
    assert [{:board, _}] = logged(ctx.log, :board)
    assert length(logged(ctx.log, :create)) == 1
  end

  test "a claim failure journals held and starts no conference", ctx do
    start_research(ctx, run: failing_run_fun(ctx.log, "start", "unknown repository"))

    assert {:error, {:claim, "unknown repository"}} = Research.dispatch(ctx.config, card())

    assert %{state: "held", reason: reason} = Research.row("trailblazer:rr11aa")
    assert reason =~ "claim failed"
    assert logged(ctx.log, :create) == []
  end

  test "a conference failure holds and notes the kept claim", ctx do
    start_research(ctx, transport: transport_fun(ctx.log, %{"create" => {:error, :down}}))

    assert {:error, {:create, :down}} = Research.dispatch(ctx.config, card())

    assert %{state: "held"} = Research.row("trailblazer:rr11aa")

    eventually(fn ->
      logged(ctx.log, :run)
      |> Enum.map(&elem(&1, 1))
      |> Enum.any?(&("note" in &1))
    end)

    note =
      logged(ctx.log, :run)
      |> Enum.map(&elem(&1, 1))
      |> Enum.find(&("note" in &1))

    assert arg_after(note, "--actor") == "research"
    assert "trailblazer:rr11aa" in note
    assert Enum.any?(note, &(&1 =~ "create failed"))
  end

  test "a researched or blocked row never dispatches again", ctx do
    seed_row("trailblazer:rr11aa", "researched")
    start_research(ctx)
    assert {:error, {:researched, "researched"}} = Research.dispatch(ctx.config, card())

    seed_row("trailblazer:rr11aa", "blocked")
    assert {:error, {:researched, "blocked"}} = Research.dispatch(ctx.config, card())
  end

  test "an unconfigured research entry is a held assignment, never a crash", ctx do
    config = Map.put(ctx.config, :research, nil)
    start_research(ctx, config: config)

    assert {:error, :not_configured} = Research.dispatch(config, card())
  end
end
