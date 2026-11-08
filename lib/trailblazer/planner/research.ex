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
  alias Trailblazer.Planner.{Board, Route}

  @table "planner_research"
  @closed ~w(researched blocked)
  @priorities ~w(p0 p1 p2 p3)
  @label "dispatch:ready"
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
  def list, do: CaseStore.transaction(&rows/1)

  @doc "The row for one research card's ref, or nil."
  def row(ref), do: row_of(ref)

  defp row_of(ref),
    do:
      CaseStore.transaction(fn conn ->
        schema(conn)
        rowof(conn, ref)
      end)

  # The journal's DDL stays public: the store test keeps its own temp tables.
  def schema(conn),
    do:
      query(
        conn,
        :planner_research_schema,
        "CREATE TABLE IF NOT EXISTS #{@table} (ref TEXT PRIMARY KEY, lease TEXT NOT NULL, state TEXT NOT NULL, conference TEXT, children TEXT, children_done INTEGER NOT NULL, reason TEXT NOT NULL, at INTEGER NOT NULL)",
        []
      )

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
      transport: opts[:transport] || endpoint_transport(),
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
      research_of(config) == nil ->
        {{:error, :not_configured}, state}

      state.busy ->
        {{:error, :busy}, state}

      finished?(ref) ->
        {{:error, {:researched, journal_state(ref)}}, state}

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
    actors = Enum.uniq([research_of(config).actor | @opencode_actors])

    with :idle <- opencode_sessions(url),
         {:ok, []} <- Board.held_by(config, actors, Keyword.take(opts, [:run])) do
      :idle
    else
      {:busy, _} = busy -> busy
      {:ok, refs} -> {:busy, "OpenCode holds " <> Enum.join(refs, ", ")}
      {:error, reason} -> {:busy, "the board could not be read: " <> format(reason)}
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
        {:busy, "OpenCode's activity is unknown (#{format(reason)})"}
    end
  end

  defp begin_dispatch(state, config, ref, card) do
    research = research_of(config)
    title = title_of(card)
    record(ref, "intent", "claiming")

    case perform(state.run, config, [
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
    research = research_of(config)

    with {:ok, %{"conference" => conference}} <-
           transport(state.transport, "create", %{
             "session" => research.session,
             "statement" => "research: " <> title,
             "admission" => "invitation",
             "peers" => [research.peer]
           }),
         {:ok, _} <-
           transport(state.transport, "post", %{
             "session" => research.session,
             "conference" => conference,
             "text" => brief(card, config, research)
           }),
         {:ok, _} <-
           transport(state.transport, "subscribe", %{
             "session" => research.session,
             "conference" => conference,
             "ttl" => @subscription_ttl
           }),
         {:ok, _} <-
           transport(state.transport, "send", %{
             "peer" => research.peer,
             "text" => "a research conference carries one brief: " <> conference
           }) do
      record(ref, "waiting", "awaiting the research reply", conference)
      backstop = arm_reply(state, ref, conference)
      {:ok, %{state | busy: true, backstops: Map.put(state.backstops, ref, backstop)}}
    else
      {:error, step, reason} ->
        {{:error, {step, reason}}, hold(state, config, ref, "#{step} failed: #{format(reason)}")}
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
      "title" => title_of(card),
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

  # The application's own authenticated VORTEX endpoint carries the research
  # route's ops; nothing here needs a peer credential. With no vortex at all
  # the announce holds on :no_transport instead of crashing.
  defp endpoint_transport do
    # Settings.load/1 yields a keyword list (tests may inject a map).
    vortex = Trailblazer.Config.get(:vortex)
    endpoint = if is_list(vortex) or is_map(vortex), do: vortex[:endpoint]
    if is_binary(endpoint), do: &Trailblazer.Vortex.Transport.call(endpoint, &1, &2)
  end

  ## Reply intake: exactly one waiting row owns a conference, and only the
  ## configured research peer may answer.

  @impl true
  def handle_info({:trailblazer_event, :planner, {:research_conference, event}}, state),
    do: {:noreply, intake(event, state)}

  def handle_info({:trailblazer_event, :planner, {:mirrored, child_ref, "done"}}, state),
    do: {:noreply, child_done(child_ref, state)}

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
          case row_of(ref) do
            %{state: "waiting"} ->
              record(ref, "held", "no reply from the research peer within the limit")
              %{state | busy: false, backstops: backstops}

            _ ->
              %{state | backstops: backstops}
          end

        {:noreply, new_state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp intake(event, state) do
    research = research_of(state.config)
    conf_id = value(event, "conference")

    cond do
      research == nil or not is_binary(conf_id) ->
        state

      value(event, "peer") != research.peer ->
        state

      true ->
        case waiting_row(conf_id) do
          nil -> state
          row -> answer(state, row, value(event, "body"))
        end
    end
  end

  defp waiting_row(conf_id) do
    CaseStore.transaction(fn conn ->
      Enum.find(rows(conn), &(&1.conference == conf_id and &1.state == "waiting"))
    end)
  end

  # The research peer's reply is exactly one JSON object. Non-JSON replies and
  # replies naming another parent do nothing; valid children are added.
  defp answer(state, row, body) do
    case payload(body, row.ref) do
      {:error, :bad_json} ->
        state

      {:error, :wrong_parent} ->
        record(row.ref, "waiting", "a reply names another parent", row.conference)
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
    names = names_of(state)
    analysis = Enum.map(children, &analyze_child(&1, names))
    good = for {:ok, child} <- analysis, do: child
    drops = for {:error, why} <- analysis, do: why

    {refs, drops} =
      Enum.reduce(good, {[], drops}, fn child, {refs, drops} ->
        case add_child(child, state, row) do
          {:ok, ref} -> {refs ++ [ref], drops}
          {:error, why} -> {refs, drops ++ ["adding failed: " <> why]}
        end
      end)

    cond do
      refs == [] ->
        reject_children(state, row, drops)

      true ->
        record(row.ref, "researched", summarise(refs, drops), row.conference, children: refs)

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
    research = research_of(state.config)
    why = "no valid children; dropped: " <> Enum.join(drops, "; ")

    record(row.ref, "blocked", why, row.conference)

    if research,
      do:
        perform(state.run, state.config, [
          "--actor",
          research.actor,
          "block",
          row.ref,
          String.slice(why, 0, 300)
        ])

    release(state, row.ref)
  end

  defp summarise(refs, []), do: "children: " <> Enum.join(refs, ", ")

  defp summarise(refs, drops),
    do: Enum.join([dropped_note(drops), summarise(refs, [])], "; ")

  defp dropped_note(drops),
    do: "dropped (" <> Integer.to_string(length(drops)) <> "): " <> Enum.join(drops, "; ")

  defp release(state, ref) do
    case Map.pop(state.backstops, ref) do
      {nil, _} ->
        %{state | busy: false}

      {backstop, backstops} ->
        Backstop.disarm(backstop)
        %{state | busy: false, backstops: backstops}
    end
  end

  # One child must satisfy the route's own rules: not a research label again, a
  # non-empty title, an admitted repository, and a body that names files and
  # states acceptance and ordered implementation steps. The card's check proves the result.
  defp analyze_child(child, names) when is_map(child) do
    title = value(child, "title")
    repo = value(child, "repo")
    files = List.wrap(value(child, "files") || [])
    acceptance = value(child, "acceptance")
    plan = value(child, "plan")

    cond do
      "dispatch:research" in List.wrap(value(child, "labels") || []) ->
        {:error, "a research-labelled child repeats the loop"}

      not (is_binary(title) and String.trim(title) != "") ->
        {:error, "no title"}

      not (is_binary(repo) and repo in names) ->
        {:error, "unknown repository"}

      not (is_binary(acceptance) and String.trim(acceptance) != "") ->
        {:error, "no acceptance criteria"}

      not (is_list(plan) and plan != [] and
               Enum.all?(plan, &(is_binary(&1) and String.trim(&1) != ""))) ->
        {:error, "no implementation plan"}

      not (files != [] and Enum.all?(files, &is_binary/1)) ->
        {:error, "the files do not parse as relative paths"}

      true ->
        body = compose(files, acceptance, plan)

        if Route.classify(%{"labels" => [], "body" => body}) == :trailblazer,
          do:
            {:ok,
             %{
               "title" => String.trim(title),
               "repo" => repo,
               "files" => files,
               "acceptance" => String.trim(acceptance),
               "plan" => plan,
               "priority" => priority_of(child)
             }},
          else: {:error, "the files do not parse as relative paths"}
    end
  end

  defp analyze_child(_, _), do: {:error, "not an object"}

  # The basenames of the admitted repositories: a child names its repository
  # by that name and the add runs under the matching path.
  defp names_of(%{config: %{repos: repos}}), do: Enum.map(Map.keys(repos), &Path.basename/1)
  defp names_of(_), do: []

  defp compose(files, acceptance, plan) do
    steps =
      Enum.map_join(Enum.with_index(plan, 1), "; ", fn {step, n} ->
        "#{n}. #{String.replace(step, "\n", " ")}"
      end)

    "Files: " <>
      Enum.join(files, " ") <>
      "\nAcceptance: " <>
      acceptance <>
      "\nImplementation plan: " <> steps
  end

  defp priority_of(%{"priority" => p}) when p in @priorities, do: p
  defp priority_of(_), do: "p2"

  defp add_child(child, state, row) do
    research = research_of(state.config)

    args = [
      "--actor",
      research.actor,
      "add",
      child["repo"],
      "--title",
      child["title"],
      "--plan",
      compose_plan(child, row.ref),
      "--priority",
      child["priority"]
    ]

    case perform(state.run, state.config, args) do
      {:error, tail} ->
        {:error, tail}

      {:ok, tail} ->
        case ref_of(tail) do
          {:ok, ref} ->
            [repo, bug] = String.split(ref, ":", parts: 2)
            apply_label(state.label, repo_path_of(state, repo), bug, @label)
            {:ok, ref}

          {:error, why} ->
            {:error, why}
        end
    end
  end

  defp compose_plan(child, parent) do
    compose(child["files"], child["acceptance"], child["plan"]) <>
      "\nChild of the research route for " <> parent <> "."
  end

  defp ref_of(tail) do
    case Jason.decode(String.slice(tail, -900, 900) |> String.trim()) do
      {:ok, %{"ref" => ref}} when is_binary(ref) -> {:ok, ref}
      _ -> {:error, "the add output does not end in a JSON object"}
    end
  end

  defp apply_label(nil, _, _, _), do: :ok

  defp apply_label(fun, path, bug, label) do
    if is_binary(path), do: fun.(path, bug, label)
    :ok
  end

  defp repo_path_of(state, name) do
    (Map.get(state.config || %{}, :repos) || %{})
    |> Enum.find_value(fn {path, _} -> if Path.basename(path) == name, do: path end)
  end

  defp note(state, ref, text) do
    research = research_of(state.config)

    perform(state.run, state.config, [
      "--actor",
      (research && research.actor) || "research",
      "note",
      ref,
      text
    ])

    :ok
  end

  # A child's completion arrives through the planner mirror; the parent ends
  # only when every one of its children is done.
  defp child_done(child_ref, state) do
    parent =
      CaseStore.transaction(fn conn ->
        Enum.find(rows(conn), &(child_ref in List.wrap(&1.children || [])))
      end)

    case parent do
      nil -> state
      row -> finish(state, row, child_ref)
    end
  end

  defp finish(state, row, child_ref) do
    kids = row.children || []
    total = length(kids)
    done = (row.children_done || 0) + 1

    record(
      row.ref,
      row.state,
      "children completed " <> Integer.to_string(done) <> "/" <> Integer.to_string(total),
      row.conference,
      children_done: done
    )

    if done >= total,
      do:
        perform(state.run, state.config, [
          "--actor",
          (research_of(state.config) || %{})[:actor],
          "done",
          row.ref,
          "--evidence",
          child_list(kids, child_ref)
        ])

    state
  end

  defp child_list(kids, _ref), do: "researched children: " <> Enum.join(kids, ", ")

  ## The runner/transport boundaries

  defp perform(nil, config, args), do: run_status(Board.run(config, args))

  defp perform(fun, _config, args) when is_function(fun, 1),
    do: run_status(fun.(args))

  defp run_status(%{status: :pass} = result), do: {:ok, result[:output_tail] || ""}
  defp run_status(%{output_tail: tail}), do: {:error, String.slice(tail || "unknown", 0, 300)}
  defp run_status(_), do: {:error, "the runner answered without a status"}

  defp transport(nil, _op, _args), do: {:error, :no_transport, "no transport configured"}

  defp transport(fun, op, args) do
    case fun.(op, args) do
      {:error, reason} -> {:error, op_atom(op), reason}
      result -> {:ok, result}
    end
  end

  defp op_atom("create"), do: :create
  defp op_atom("post"), do: :post
  defp op_atom("subscribe"), do: :subscribe
  defp op_atom("send"), do: :send
  defp op_atom(other), do: other

  ## Journal

  defp hold(state, config, ref, why) do
    record(ref, "held", why)

    research = research_of(config)

    if research,
      do:
        perform(state.run, config, [
          "--actor",
          research.actor,
          "note",
          ref,
          "research hold: " <> why
        ])

    state
  end

  defp record(ref, state, reason, conference \\ nil, extra \\ []) do
    CaseStore.transaction(fn conn ->
      schema(conn)
      existing = rowof(conn, ref) || %{}

      children_text =
        Jason.encode!(Keyword.get(extra, :children) || Map.get(existing, :children) || [])

      done =
        Keyword.get(extra, :children_done) ||
          (existing[:children_done] && Map.get(existing, :children_done)) || 0

      query(
        conn,
        :planner_research_put,
        "INSERT OR REPLACE INTO #{@table} (ref, lease, state, conference, children, children_done, reason, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [
          ref,
          existing[:lease] || "",
          state,
          conference || (existing[:conference] || nil),
          children_text,
          done,
          String.slice(reason || "", 0, 900),
          System.os_time(:millisecond)
        ]
      )

      :ok
    end)
  end

  defp rows(conn) do
    schema(conn)

    for [ref, lease, state, conference, children, done, reason, at] <-
          query(
            conn,
            :planner_research_rows,
            "SELECT ref, lease, state, conference, children, children_done, reason, at FROM #{@table} ORDER BY rowid",
            []
          ) do
      %{
        ref: ref,
        lease: lease,
        state: state,
        conference: conference,
        children: decode_children(children),
        children_done: done,
        reason: reason,
        at: at
      }
    end
  end

  defp rowof(conn, ref), do: Enum.find(rows(conn), &(&1.ref == ref))

  defp decode_children(""), do: []
  defp decode_children(nil), do: []

  defp decode_children(text) do
    case Jason.decode!(text) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp query(conn, name, sql, params) do
    {_query, %Exqlite.Result{rows: rows}} =
      Exqlite.prepare_execute!(conn, name, sql, params, timeout: :infinity)

    rows || []
  end

  ## Small helpers

  defp finished?(ref) do
    case row_of(ref) do
      %{state: state} -> state in @closed
      _ -> false
    end
  end

  defp journal_state(ref) do
    case row_of(ref) do
      %{state: state} -> state
      _ -> "none"
    end
  end

  defp research_of(%{research: research}), do: research
  defp research_of(_), do: nil

  defp title_of(%{context: %{"title" => title}}) when is_binary(title) and title != "",
    do: String.slice(String.trim(title), 0, 200)

  defp title_of(card), do: card.ref

  defp format(term) when is_binary(term), do: String.slice(term, 0, 300)
  defp format(term), do: String.slice(inspect(term), 0, 300)

  defp value(map, key) when is_map(map), do: Map.get(map, key)
  defp value(_, _), do: nil
end
