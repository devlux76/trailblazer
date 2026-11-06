defmodule Trailblazer.API do
  @moduledoc "Authenticated JSON operations for the local core."
  use Plug.Router
  alias Trailblazer.{Indexer, Query, Store}
  alias Trailblazer.Loop.{CaseRecord, Runner, Workspace}

  @operations ~w(watch status where uses impact read search trail stale_citations run case accept retire anomalies ack vortex vortex_status)
  plug(:authenticate)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  def init(opts), do: opts

  def call(conn, opts) do
    super(Plug.Conn.put_private(conn, :trailblazer_api, opts), opts)
  rescue
    _e in [
      Plug.Parsers.ParseError,
      Plug.Parsers.UnsupportedMediaTypeError,
      Plug.Parsers.RequestTooLargeError
    ] ->
      json(conn, 400, %{error: "bad request"})
  catch
    # a call that timed out (E23) answers with why, not an empty 500
    :exit, reason ->
      json(conn, 503, %{
        error: "the service did not answer in time",
        reason: reason |> inspect(limit: 5, printable_limit: 200) |> String.slice(0, 400)
      })
  end

  defp authenticate(conn, _) do
    opts = conn.private.trailblazer_api
    token = opts[:token] || Trailblazer.API.EndpointFile.token()

    case get_req_header(conn, "authorization") do
      ["Bearer " <> provided] ->
        if Plug.Crypto.secure_compare(provided, token),
          do: conn,
          else: conn |> json(401, %{error: "unauthorized"}) |> halt()

      _ ->
        conn |> json(401, %{error: "unauthorized"}) |> halt()
    end
  end

  post "/:op" do
    opts = conn.private.trailblazer_api
    params = conn.body_params

    cond do
      op not in @operations ->
        json(conn, 404, %{error: "unknown operation"})

      not valid?(op, params) ->
        json(conn, 400, %{error: "bad arguments"})

      op in ~w(vortex vortex_status) ->
        bridge = Keyword.get(opts, :vortex, Trailblazer.Vortex.Bridge)

        if is_pid(bridge) or Process.whereis(bridge) do
          result =
            if op == "vortex",
              do: Trailblazer.Vortex.Bridge.pump(bridge),
              else: Trailblazer.Vortex.Bridge.status(bridge)

          case result do
            :ok -> json(conn, 200, %{processed: true})
            {:error, _} -> json(conn, 503, %{error: "VORTEX unavailable"})
            result -> json(conn, 200, result)
          end
        else
          json(conn, 503, %{error: "VORTEX is not configured"})
        end

      op == "run" and Workspace.own_repo?(Path.expand(params["repo"])) ->
        respond(conn, {:error, :own_repo})

      op == "run" ->
        task = %{
          repo: Path.expand(params["repo"]),
          request: params["request"],
          files: Map.get(params, "files", []),
          read_rounds: Map.get(params, "read_rounds", 6),
          design: params["design"],
          check: params["check"],
          primary: params["primary"],
          from: "cli"
        }

        task =
          if Map.has_key?(params, "reasoning_budget_tokens"),
            do: Map.put(task, :reasoning_budget_tokens, params["reasoning_budget_tokens"]),
            else: task

        # Similar past changes on or off for this case (the replay eval's
        # arms); absent, config decides. Local callers only, not VORTEX peers.
        task =
          if Map.has_key?(params, "examples"),
            do: Map.put(task, :examples, params["examples"]),
            else: task

        case Runner.submit(task, Keyword.get(opts, :runner, Runner)) do
          {:ok, id} -> json(conn, 202, %{case: id})
          {:error, _} = error -> respond(conn, error)
        end

      op in ~w(accept retire) ->
        coordinator = Keyword.get(opts, :coordinator, Trailblazer.Loop.Coordinator)

        result =
          if op == "accept",
            do: coordinator.accept(params["case"], []),
            else: coordinator.retire(params["case"], [])

        case result do
          {:ok, r} ->
            json(conn, 200, Map.take(r, ~w(stage cleanup primary result candidate archive)))

          {:error, :no_lifecycle} ->
            json(conn, 404, %{error: "no lifecycle journal for that case"})

          {:error, reason} ->
            json(conn, 409, %{
              error: "blocked",
              reason: reason |> inspect(limit: 5, printable_limit: 200) |> String.slice(0, 400)
            })
        end

      op == "anomalies" ->
        json(conn, 200, %{anomalies: Trailblazer.Anomaly.list(open: params["all"] != true)})

      op == "ack" ->
        case Trailblazer.Anomaly.ack(params["id"]) do
          :ok -> json(conn, 200, %{acked: params["id"]})
          {:error, :no_anomaly} -> json(conn, 404, %{error: "no open anomaly with that id"})
        end

      op == "case" and params["follow"] == true ->
        follow(conn, params["case"])

      op == "case" ->
        case CaseRecord.get(params["case"], inline: false) do
          nil ->
            json(conn, 404, %{error: "no such case"})

          record ->
            state =
              if record.status == "open",
                do: Runner.status(record.id, Keyword.get(opts, :runner, Runner))

            json(conn, 200, %{
              case: record.id,
              status: state || record.status,
              report: record.report,
              record: record
            })
        end

      true ->
        indexer = Keyword.get(opts, :indexer, Indexer)

        if op != "watch" and not indexer.watched?(params["repo"]) do
          json(conn, 409, %{error: "not watched", hint: "trailblazer watch <repo>"})
        else
          # Every answer about a repository is brought up to date with git
          # first (design §13.7); a vanished root is an error, never a stale
          # answer (J22).
          case if(op == "watch", do: :ok, else: fresh(indexer, params["repo"])) do
            {:error, _} = error -> respond(conn, error)
            _ -> respond(conn, run(op, params, opts, indexer))
          end
        end
    end
  end

  match(_, do: json(conn, 404, %{error: "unknown operation"}))

  # Test indexers may not reconcile; the real one always does.
  defp fresh(indexer, repo) do
    if Code.ensure_loaded?(indexer) and function_exported?(indexer, :fresh, 1),
      do: indexer.fresh(repo),
      else: :ok
  end

  defp run("watch", p, opts, indexer) do
    with {:ok, _pid} <- indexer.watch(p["repo"], Keyword.get(opts, :indexer_opts, [])),
         do: %{watched: true}
  end

  defp run("status", p, _, indexer) do
    with %{} = status <- indexer.status(p["repo"]) do
      Map.merge(status, %{
        vortex: Trailblazer.Config.runtime_status(:vortex),
        planner: Trailblazer.Config.runtime_status(:planner)
      })
    end
  end

  defp run("stale_citations", p, _, _) do
    {:ok, id} = Store.add_repo(p["repo"])
    Trailblazer.Graph.Resolve.stale_citations(id)
  end

  defp run(op, p, opts, _) do
    query = Keyword.get(opts, :query, Query)
    qopts = Keyword.get(opts, :query_opts, [])
    repo = p["repo"]

    case op do
      "where" ->
        query.where_declared(
          repo,
          if(is_binary(p["name"]), do: p["name"], else: {p["path"], p["line"]}),
          qopts
        )

      "uses" ->
        query.who_uses(repo, p["id"] || p["name"], qopts)

      "impact" ->
        query.impact_of(repo, p["id"] || p["name"], Map.get(p, "depth", 3), qopts)

      "read" ->
        query.read_range(repo, p["path"], p["first"], p["last"], qopts)

      "search" ->
        query.search(repo, p["text"], Map.get(p, "limit", 10), qopts)

      "trail" ->
        trail = Keyword.get(opts, :trail, Trailblazer.Trail)

        trail.build(
          repo,
          p["request"],
          qopts ++
            [
              files: Map.get(p, "files", []),
              budget: Map.get(p, "budget", Trailblazer.Config.get(:trail_tokens))
            ]
        )
    end
  end

  # A case's events as they are recorded (design §13.3), one JSON object per
  # line: the task first, then every event, the report last. Subscribed
  # before the record is read, so nothing recorded in between is lost, and
  # events are taken by sequence number, so nothing is sent twice (J2). It
  # waits for the case's own events, however long the task takes; the
  # runner closes every case it starts, so the stream always ends.
  defp follow(conn, id) do
    :ok = Trailblazer.Events.subscribe({:case, id})

    case CaseRecord.get(id, inline: false) do
      nil ->
        Trailblazer.Events.unsubscribe({:case, id})
        json(conn, 404, %{error: "no such case"})

      record ->
        conn =
          conn
          |> put_resp_content_type("application/x-ndjson")
          |> send_chunked(200)

        with {:ok, conn} <- line(conn, %{case: id, task: record.task}),
             {:ok, conn, last, done?} <- emit(conn, record.events, 0) do
          if done?, do: finish(conn, id), else: follow_loop(conn, id, last)
        else
          {:error, conn} -> finish(conn, id)
        end
    end
  end

  defp follow_loop(conn, id, last) do
    receive do
      {:trailblazer_event, {:case, ^id}, %{seq: seq}} when seq > last ->
        case emit(conn, CaseRecord.events_after(id, last, inline: false), last) do
          {:ok, conn, last, false} -> follow_loop(conn, id, last)
          {:ok, conn, _last, true} -> finish(conn, id)
          {:error, conn} -> finish(conn, id)
        end

      {:trailblazer_event, {:case, ^id}, _seen} ->
        follow_loop(conn, id, last)
    end
  end

  defp emit(conn, events, last) do
    Enum.reduce_while(events, {:ok, conn, last, false}, fn e, {:ok, conn, _last, _done} ->
      payload = if e.kind == "report", do: %{report: e.data}, else: %{event: e}

      case line(conn, payload) do
        {:ok, conn} -> {:cont, {:ok, conn, e.seq, e.kind == "report"}}
        {:error, conn} -> {:halt, {:error, conn}}
      end
    end)
  end

  defp line(conn, data) do
    case chunk(conn, [Jason.encode!(data), "\n"]) do
      {:ok, conn} -> {:ok, conn}
      {:error, _closed} -> {:error, conn}
    end
  end

  defp finish(conn, id) do
    Trailblazer.Events.unsubscribe({:case, id})
    conn
  end

  defp respond(conn, {:ok, result}), do: respond(conn, result)

  defp respond(conn, {:error, :not_watched}),
    do: json(conn, 409, %{error: "not watched", hint: "trailblazer watch <repo>"})

  defp respond(conn, {:error, :own_repo}),
    do: json(conn, 400, %{error: "Trailblazer does not work on its own repository"})

  defp respond(conn, {:error, :vortex_unavailable}),
    do: json(conn, 503, %{error: "vortex_unavailable"})

  defp respond(conn, {:error, reason}) when reason in [:bad_range, :outside_repo, :enoent],
    do: json(conn, 400, %{error: Atom.to_string(reason)})

  defp respond(conn, {:error, _reason}), do: json(conn, 503, %{error: "operation failed"})
  defp respond(conn, %_{} = result), do: json(conn, 200, Map.from_struct(result))
  defp respond(conn, result), do: json(conn, 200, result)

  defp valid?(op, params) when op in ~w(vortex vortex_status), do: params == %{}

  defp valid?("case", p) when is_map(p),
    do: is_binary(p["case"]) and p["case"] != "" and p["follow"] in [nil, true, false]

  defp valid?(op, p) when op in ~w(accept retire) and is_map(p),
    do: is_binary(p["case"]) and p["case"] != ""

  defp valid?("anomalies", p) when is_map(p), do: p["all"] in [nil, true, false]
  defp valid?("ack", p) when is_map(p), do: is_integer(p["id"]) and p["id"] > 0

  defp valid?(op, p) when is_map(p) do
    is_binary(p["repo"]) and p["repo"] != "" and valid_args?(op, p)
  end

  defp valid?(_, _), do: false
  defp valid_args?(op, _) when op in ["watch", "status", "stale_citations"], do: true

  defp valid_args?("where", p),
    do: is_binary(p["name"]) or (is_binary(p["path"]) and positive?(p["line"]))

  defp valid_args?("uses", p), do: node_ref?(p)

  defp valid_args?("impact", p),
    do: node_ref?(p) and is_integer(Map.get(p, "depth", 3)) and Map.get(p, "depth", 3) >= 0

  defp valid_args?("read", p),
    do:
      is_binary(p["path"]) and positive?(p["first"]) and positive?(p["last"]) and
        p["last"] >= p["first"]

  defp valid_args?("search", p), do: is_binary(p["text"]) and positive?(Map.get(p, "limit", 10))

  defp valid_args?("trail", p),
    do:
      is_binary(p["request"]) and
        positive?(Map.get(p, "budget", Trailblazer.Config.get(:trail_tokens))) and
        is_list(Map.get(p, "files", [])) and Enum.all?(Map.get(p, "files", []), &is_binary/1)

  defp valid_args?("run", p) do
    read_rounds = Map.get(p, "read_rounds", 6)

    is_integer(read_rounds) and read_rounds in 0..6 and
      (not Map.has_key?(p, "reasoning_budget_tokens") or
         Trailblazer.Model.valid_reasoning_budget?(p["reasoning_budget_tokens"])) and
      (not Map.has_key?(p, "examples") or is_boolean(p["examples"])) and
      is_binary(p["request"]) and String.trim(p["request"]) != "" and
      is_list(Map.get(p, "files", [])) and Enum.all?(Map.get(p, "files", []), &is_binary/1) and
      (is_nil(p["check"]) or is_binary(p["check"])) and
      (is_nil(p["primary"]) or (is_binary(p["primary"]) and p["primary"] != "")) and
      (is_nil(p["design"]) or is_binary(p["design"]) or
         (is_list(p["design"]) and Enum.all?(p["design"], &is_binary/1)))
  end

  defp node_ref?(p) do
    if Map.has_key?(p, "id"), do: positive?(p["id"]), else: is_binary(p["name"])
  end

  defp positive?(v), do: is_integer(v) and v > 0

  defp json(conn, status, data),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(data))
end
