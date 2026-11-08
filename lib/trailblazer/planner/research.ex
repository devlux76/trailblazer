defmodule Trailblazer.Planner.Research do
  @moduledoc """
  The research route's server (trailblazer:4cc63df): the planner brain routes
  a ready card here, the card is claimed for the research actor, one VORTEX
  conference carries the brief to the research peer, and the peer's reply
  becomes child cards on the admitted repositories.

  One job at a time: an occupied slot answers `{:error, :busy}` and the brain
  journals the card unavailable. Every step writes its intent into cases.db
  before the effect, so a restart resumes from the journal. `waiting` holds
  the reply's deadline, `researched` and `blocked` are terminal (that card is
  never dispatched again), and `held` names a recoverable failure with the
  card's claim kept.
  """

  use GenServer
  require Logger
  alias Trailblazer.{Backstop, CaseStore, Events}
  alias Trailblazer.Planner.Board
  alias Trailblazer.Planner.Research.{Boundary, Children, Journal, Support}

  @subscription_ttl 86_400
  @reply_limit_ms 3 * 60 * 60 * 1000
  @opencode_url "http://127.0.0.1:4096"
  # How long the OpenCode activity question may take before it reads as unknown.
  @busy_check_ms 5_000
  # Planner actors OpenCode works under, besides the configured research actor.
  @opencode_actors ["opencode"]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc "Every research row."
  def list, do: CaseStore.transaction(&Journal.rows/1)

  @doc "The row for one research card's ref, or nil."
  def row(ref), do: Journal.row_of(ref)

  # The journal's DDL stays public: the store test keeps its own temp tables.
  defdelegate schema(conn), to: Trailblazer.Planner.Research.Journal

  @doc """
  Researches one card (the brain's research_fun boundary): claim it for the
  research actor, open one VORTEX conference, post the brief, subscribe
  durably and wake the peer. Returns `:ok`, `{:error, :busy}` while a job
  runs, `{:error, {:researched, state}}` for a finished card, or
  `{:error, reason}` for the journaled hold.
  """
  def dispatch(config, card),
    do: GenServer.call(__MODULE__, {:dispatch, config, card}, :infinity)

  @impl true
  def init(opts) do
    state = %{
      config: opts[:config],
      transport: opts[:transport] || Boundary.endpoint_transport(),
      run: opts[:run],
      label: opts[:label],
      reply_limit_ms: opts[:reply_limit_ms] || @reply_limit_ms,
      # OpenCode is strictly serial (free tier, ban risk): research waits
      # while it has any running session or holds an assignment elsewhere.
      peer_busy: opts[:peer_busy] || (&peer_busy(&1, opts)),
      busy: false,
      backstops: %{}
    }

    Events.subscribe(:planner)
    {:ok, state}
  end

  ## One dispatch

  @impl true
  def handle_call({:dispatch, config, card}, _from, state) do
    {answer, new_state} = attempt(config, card, state)
    {:reply, answer, new_state}
  end

  defp attempt(config, %{ref: ref} = card, state) do
    cond do
      Support.research_of(config) == nil ->
        {{:error, :not_configured}, state}

      state.busy ->
        {{:error, :busy}, state}

      Journal.finished?(ref) ->
        {{:error, {:researched, Journal.journal_state(ref)}}, state}

      true ->
        case state.peer_busy.(config) do
          :idle ->
            begin_dispatch(state, config, ref, card)

          {:busy, why} ->
            # The brain journals `busy` as unavailable and retries on the next
            # event; nothing is claimed or announced.
            Logger.info("trailblazer: research holds #{ref}: #{why}")
            {{:error, :busy}, state}
        end
    end
  end

  # :idle only when OpenCode answers with no running session and no card is
  # in progress under its actors. An unknown answer holds: the research peer
  # is OpenCode, so a job it cannot be asked about cannot be safely sent.
  defp peer_busy(config, opts) do
    url = (opts[:opencode_url] || @opencode_url) <> "/api/session/active"
    actors = Enum.uniq([Support.research_of(config).actor | @opencode_actors])

    with :idle <- opencode_sessions(url),
         {:ok, []} <- Board.held_by(config, actors, Keyword.take(opts, [:run])) do
      :idle
    else
      {:busy, _} = busy -> busy
      {:ok, refs} -> {:busy, "OpenCode holds " <> Enum.join(refs, ", ")}
      {:error, reason} -> {:busy, "the board could not be read: " <> Support.format(reason)}
    end
  end

  # One bounded question (the request has no client timeout of its own; the
  # backstop is its one clock, design §13.5). A hang reads as unknown: hold.
  defp opencode_sessions(url) do
    answer =
      case Backstop.guard(
             :research_peer_busy,
             url,
             {:ms, @busy_check_ms},
             fn -> %{url: url} end,
             fn ->
               Req.get(url, retry: false)
             end
           ) do
        {:ok, reply} -> reply
        {:error, reason} -> {:error, reason}
      end

    case answer do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when data == %{} or data == [] ->
        :idle

      {:ok, %Req.Response{status: 200, body: %{"data" => data}}}
      when is_map(data) or is_list(data) ->
        {:busy, "OpenCode has #{Enum.count(data)} running session(s)"}

      {:ok, %Req.Response{status: status}} ->
        {:busy, "OpenCode's activity is unknown (HTTP #{status})"}

      {:error, reason} ->
        {:busy, "OpenCode's activity is unknown (#{Support.format(reason)})"}
    end
  end

  defp begin_dispatch(state, config, ref, card) do
    research = Support.research_of(config)
    title = Support.title_of(card)
    Journal.record(ref, "intent", "claiming")

    case Boundary.perform(state.run, config, [
           "--actor",
           research.actor,
           "start",
           ref,
           "--plan",
           "research: " <> title
         ]) do
      {:ok, _tail} ->
        announce(state, config, ref, card, title)

      {:error, tail} ->
        {{:error, {:claim, tail}}, hold(state, config, ref, "claim failed: " <> tail)}
    end
  end

  defp announce(state, config, ref, card, title) do
    research = Support.research_of(config)

    with {:ok, %{"conference" => conference}} <-
           Boundary.transport(state.transport, "create", %{
             "session" => research.session,
             "statement" => "research: " <> title,
             "admission" => "invitation",
             "peers" => [research.peer]
           }),
         {:ok, _} <-
           Boundary.transport(state.transport, "post", %{
             "session" => research.session,
             "conference" => conference,
             "text" => brief(card, config, research)
           }),
         {:ok, _} <-
           Boundary.transport(state.transport, "subscribe", %{
             "session" => research.session,
             "conference" => conference,
             "ttl" => @subscription_ttl
           }),
         {:ok, _} <-
           Boundary.transport(state.transport, "send", %{
             "peer" => research.peer,
             "text" => "a research conference carries one brief: " <> conference
           }) do
      Journal.record(ref, "waiting", "awaiting the research reply", conference)
      backstop = arm_reply(state, ref, conference)
      {:ok, %{state | busy: true, backstops: Map.put(state.backstops, ref, backstop)}}
    else
      {:error, step, reason} ->
        {{:error, {step, reason}},
         hold(state, config, ref, "#{step} failed: #{Support.format(reason)}")}
    end
  end

  # The brief: the card's own text, the admitted repositories and the reply
  # contract in one line. It never names a model.
  defp brief(card, config, _research) do
    repos =
      config.repos
      |> Map.keys()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    contract =
      """
      Reply in this conference with exactly one JSON object:
      {"parent": "<this card's ref>", "children": [{"title": "<short and concrete>", "repo": "<one name from repos>", "files": ["<relative path>"], "acceptance": "<a test or check to pass>", "plan": ["<ordered step naming the exact file, interface or assertion>"], "priority": "p0" | "p1" | "p2" | "p3"}]}
      The files list becomes a "Files:" line and the acceptance string an "Acceptance:" line on the child card. The plan must resolve implementation choices and external interfaces, state the starting code available to the worker, and specify test assertions. It becomes an "Implementation plan:" line; requirements alone are not a plan. Split work that needs more exploration into smaller children. Children without a plan or failing the check's rules are dropped.
      """
      |> String.trim_trailing()

    Jason.encode!(%{
      "task" => "plan one ready card for implementation",
      "parent" => card.ref,
      "title" => Support.title_of(card),
      "card" => Map.get(card, :context) || %{},
      "repos" => repos,
      "contract" => contract
    })
  end

  defp arm_reply(state, ref, conference) do
    Backstop.arm(:planner_research_reply, ref, {:ms, state.reply_limit_ms}, fn ->
      %{ref: ref, conference: conference}
    end)
  end

  ## Reply intake: exactly one waiting row owns a conference, and only the
  ## configured research peer may answer.

  @impl true
  def handle_info({:trailblazer_event, :planner, {:research_conference, event}}, state),
    do: {:noreply, intake(event, state)}

  def handle_info({:trailblazer_event, :planner, {:mirrored, child_ref, "done"}}, state),
    do: {:noreply, Children.child_done(child_ref, state)}

  # A firing reply backstop holds the card: the claim stays and a later state
  # change (the board, or the peer's next word) checks again.
  def handle_info({:backstop, backstop_ref, _anomaly}, state) do
    case Enum.find(state.backstops, fn {_, ref} -> ref == backstop_ref end) do
      nil ->
        {:noreply, state}

      {ref, _backstop} ->
        {pending, backstops} = Map.pop(state.backstops, ref)
        Backstop.disarm(pending)

        new_state =
          case Journal.row_of(ref) do
            %{state: "waiting"} ->
              Journal.record(ref, "held", "no reply from the research peer within the limit")
              %{state | busy: false, backstops: backstops}

            _ ->
              %{state | backstops: backstops}
          end

        {:noreply, new_state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp intake(event, state) do
    research = Support.research_of(state.config)
    conf_id = Support.value(event, "conference")

    cond do
      research == nil or not is_binary(conf_id) ->
        state

      Support.value(event, "peer") != research.peer ->
        state

      true ->
        case waiting_row(conf_id) do
          nil -> state
          row -> answer(state, row, Support.value(event, "body"))
        end
    end
  end

  defp waiting_row(conf_id) do
    CaseStore.transaction(fn conn ->
      Enum.find(Journal.rows(conn), &(&1.conference == conf_id and &1.state == "waiting"))
    end)
  end

  # The research peer's reply is exactly one JSON object. Non-JSON replies and
  # replies naming another parent do nothing; valid children are added.
  defp answer(state, row, body) do
    case payload(body, row.ref) do
      {:error, :bad_json} ->
        state

      {:error, :wrong_parent} ->
        Journal.record(row.ref, "waiting", "a reply names another parent", row.conference)
        state

      {:ok, children} ->
        apply_children(state, row, children)
    end
  end

  defp payload(body, parent_ref) do
    case Jason.decode(body || "") do
      {:ok, %{"parent" => parent, "children" => children}}
      when is_binary(parent) and parent == parent_ref and is_list(children) ->
        {:ok, children}

      {:ok, %{"parent" => parent}} when is_binary(parent) and parent != parent_ref ->
        {:error, :wrong_parent}

      _ ->
        {:error, :bad_json}
    end
  end

  defp apply_children(state, row, children) do
    names = Children.names_of(state)
    analysis = Enum.map(children, &Children.analyze_child(&1, names))
    good = for {:ok, child} <- analysis, do: child
    drops = for {:error, why} <- analysis, do: why

    {refs, drops} =
      Enum.reduce(good, {[], drops}, fn child, {refs, drops} ->
        case Children.add_child(child, state, row) do
          {:ok, ref} -> {refs ++ [ref], drops}
          {:error, why} -> {refs, drops ++ ["adding failed: " <> why]}
        end
      end)

    cond do
      refs == [] ->
        reject_children(state, row, drops)

      true ->
        Journal.record(row.ref, "researched", Children.summarise(refs, drops), row.conference,
          children: refs
        )

        note(
          state,
          row.ref,
          "researched: " <>
            Integer.to_string(length(refs)) <> " children: " <> Enum.join(refs, ", ")
        )

        release(state, row.ref)
    end
  end

  defp reject_children(state, row, drops) do
    research = Support.research_of(state.config)
    why = "no valid children; dropped: " <> Enum.join(drops, "; ")

    Journal.record(row.ref, "blocked", why, row.conference)

    if research,
      do:
        Boundary.perform(state.run, state.config, [
          "--actor",
          research.actor,
          "block",
          row.ref,
          String.slice(why, 0, 300)
        ])

    release(state, row.ref)
  end

  defp release(state, ref) do
    case Map.pop(state.backstops, ref) do
      {nil, _} ->
        %{state | busy: false}

      {backstop, backstops} ->
        Backstop.disarm(backstop)
        %{state | busy: false, backstops: backstops}
    end
  end

  defp note(state, ref, text) do
    research = Support.research_of(state.config)

    Boundary.perform(state.run, state.config, [
      "--actor",
      (research && research.actor) || "research",
      "note",
      ref,
      text
    ])

    :ok
  end

  ## Journal

  defp hold(state, config, ref, why) do
    Journal.record(ref, "held", why)

    research = Support.research_of(config)

    if research,
      do:
        Boundary.perform(state.run, config, [
          "--actor",
          research.actor,
          "note",
          ref,
          "research hold: " <> why
        ])

    state
  end
end
