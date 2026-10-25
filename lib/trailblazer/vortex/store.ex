defmodule Trailblazer.Vortex.Store do
  @moduledoc "Atomic VORTEX admission and durable outbox on the existing cases.db writer."
  alias Trailblazer.CaseStore
  alias Trailblazer.Loop.CaseRecord
  alias Trailblazer.Vortex.Protocol

  def admit(peer, room, request_id, task) do
    encoded = Jason.encode!(task)

    id =
      "vortex-" <> Base.encode16(:crypto.hash(:sha256, peer <> "\0" <> request_id), case: :lower)

    CaseStore.transaction(fn conn ->
      case query(
             conn,
             :vortex_duplicate,
             "SELECT case_id, task, room FROM vortex_request WHERE peer = ? AND request_id = ?",
             [peer, request_id]
           ) do
        [[existing, previous, ^room]] when previous == encoded ->
          query(
            conn,
            :vortex_repeat_acceptance,
            "UPDATE vortex_outbox SET acked = 0 WHERE case_id = ? AND peer = ? AND type = 'accepted'",
            [existing, peer]
          )

          {:ok, existing, :duplicate}

        [_] ->
          {:error, :conflict}

        [] ->
          query(
            conn,
            :vortex_case,
            "INSERT INTO task_case (id,repo,task,opened_at) VALUES (?,?,?,?)",
            [id, task.repo, encoded, System.os_time(:millisecond)]
          )

          query(
            conn,
            :vortex_admit,
            "INSERT INTO vortex_request (case_id,peer,room,request_id,task,state) VALUES (?,?,?,?,?,'waiting_resource')",
            [id, peer, room, request_id, encoded]
          )

          put(conn, id, peer, room, "accepted", request_id, %{
            "case" => id,
            "state" => "waiting_resource"
          })

          {:ok, id, :new}
      end
    end)
  end

  def get(id) do
    CaseStore.transaction(fn conn ->
      case query(
             conn,
             :vortex_get,
             "SELECT case_id,peer,room,request_id,task,state,frontier,returned_fix FROM vortex_request WHERE case_id = ?",
             [id]
           ) do
        [[id, peer, room, request, task, state, frontier, returned_fix]] ->
          %{
            case_id: id,
            peer: peer,
            room: room,
            request_id: request,
            task: Jason.decode!(task),
            state: state,
            frontier: frontier,
            returned_fix: if(returned_fix, do: Jason.decode!(returned_fix))
          }

        [] ->
          nil
      end
    end)
  end

  def waiting?(id), do: match?(%{state: "waiting_resource"}, get(id))

  def ids do
    CaseStore.transaction(fn conn ->
      query(conn, :vortex_ids, "SELECT case_id FROM vortex_request ORDER BY rowid", [])
      |> List.flatten()
    end)
  end

  def reserve(id, lease) do
    CaseStore.transaction(fn conn ->
      query(
        conn,
        :vortex_reserve,
        "UPDATE vortex_request SET lease = ?, released = 0 WHERE case_id = ?",
        [lease, id]
      )

      :ok
    end)
  end

  def state(id, "running", lease) when is_binary(lease) do
    CaseStore.transaction(fn conn ->
      query(
        conn,
        :vortex_running,
        "UPDATE vortex_request SET state = 'running', lease = ?, released = 0 WHERE case_id = ?",
        [lease, id]
      )

      :ok
    end)
  end

  def state(id, "waiting_resource") do
    CaseStore.transaction(fn conn ->
      query(
        conn,
        :vortex_waiting,
        "UPDATE vortex_request SET state = 'waiting_resource' WHERE case_id = ?",
        [id]
      )

      :ok
    end)
  end

  def holds do
    CaseStore.transaction(fn conn ->
      query(
        conn,
        :vortex_holds,
        "SELECT case_id,lease FROM vortex_request WHERE released = 0 AND lease IS NOT NULL",
        []
      )
    end)
  end

  def released(id) do
    CaseStore.transaction(fn conn ->
      query(conn, :vortex_released, "UPDATE vortex_request SET released = 1 WHERE case_id = ?", [
        id
      ])

      :ok
    end)
  end

  def classify(peer, cursor, reason) do
    CaseStore.transaction(fn conn ->
      query(
        conn,
        :vortex_classify,
        "INSERT OR IGNORE INTO vortex_classification (peer,cursor,reason) VALUES (?,?,?)",
        [peer || "", cursor, to_string(reason)]
      )

      :ok
    end)
  end

  def outbox do
    CaseStore.transaction(fn conn ->
      query(
        conn,
        :vortex_outbox,
        "SELECT id,case_id,peer,room,type,body,receipt FROM vortex_outbox WHERE acked = 0 ORDER BY rowid",
        []
      )
      |> Enum.map(fn [id, case_id, peer, room, type, body, receipt] ->
        %{
          id: id,
          case_id: case_id,
          peer: peer,
          room: room,
          type: type,
          body: body,
          receipt: receipt == 1
        }
      end)
    end)
  end

  def receipt(peer, message_id) when is_binary(message_id) do
    CaseStore.transaction(fn conn ->
      case query(
             conn,
             :vortex_receipt_target,
             "SELECT peer,case_id FROM vortex_outbox WHERE id = ?",
             [
               message_id
             ]
           ) do
        [[^peer, case_id]] ->
          if String.starts_with?(case_id, "anomaly-") do
            {anomaly_id, ""} = case_id |> String.replace_prefix("anomaly-", "") |> Integer.parse()

            query(conn, :vortex_anomaly_receipt, "UPDATE anomaly SET sent = 1 WHERE id = ?", [
              anomaly_id
            ])
          end

          query(conn, :vortex_receipt, "UPDATE vortex_outbox SET acked = 1 WHERE id = ?", [
            message_id
          ])

          :ok

        _ ->
          {:error, :unknown_receipt}
      end
    end)
  end

  def receipt(_, _), do: {:error, :unknown_receipt}

  def investigate(anomaly, {peer, room}) do
    id = "anomaly-#{anomaly.id}"

    payload = %{
      "case" => id,
      "anomaly" => anomaly.id,
      "summary" => "Investigation requested; receipt is not resolution.",
      "dossier" => String.slice(Trailblazer.Investigate.text(anomaly), 0, 1400)
    }

    CaseStore.transaction(fn conn ->
      now = System.os_time(:millisecond)

      task =
        Jason.encode!(%{repo: "", request: "Investigate anomaly #{anomaly.id}", from: "internal"})

      report = Jason.encode!(%{status: "escalated", anomaly: anomaly.id})

      query(
        conn,
        :vortex_anomaly_case,
        "INSERT OR IGNORE INTO task_case (id,repo,task,status,report,opened_at,closed_at) VALUES (?,'',?,'escalated',?,?,?)",
        [id, task, report, now, now]
      )

      query(
        conn,
        :vortex_anomaly_request,
        "INSERT OR IGNORE INTO vortex_request (case_id,peer,room,request_id,task,state,frontier) VALUES (?,'internal','',?,?,'waiting_frontier',?)",
        [id, id, task, peer]
      )

      put(conn, id, peer, room, "escalation", id, payload)
      :ok
    end)
  end

  def investigate(_, nil), do: {:error, :no_frontier}

  def finish(id, frontier) do
    request = get(id)
    record = CaseRecord.get(id)

    if request && record && record.status != "open" do
      payload = report_payload(record)

      CaseStore.transaction(fn conn ->
        put(conn, id, request.peer, request.room, "report", request.request_id, payload)

        if record.status == "failed" do
          case frontier do
            {peer, room} ->
              put(conn, id, peer, room, "escalation", request.request_id, payload)

              query(
                conn,
                :vortex_escalated,
                "UPDATE vortex_request SET state = 'waiting_frontier', frontier = ? WHERE case_id = ? AND (state IN ('waiting_resource','running') OR (state = 'waiting_frontier' AND frontier IS NULL))",
                [peer, id]
              )

            nil ->
              query(
                conn,
                :vortex_no_frontier,
                "UPDATE vortex_request SET state = 'waiting_frontier' WHERE case_id = ? AND state IN ('waiting_resource','running')",
                [id]
              )
          end
        else
          query(
            conn,
            :vortex_completed,
            "UPDATE vortex_request SET state = 'complete' WHERE case_id = ? AND state IN ('waiting_resource','running')",
            [id]
          )
        end

        :ok
      end)
    else
      {:error, :not_closed}
    end
  end

  def claim(peer, id) do
    CaseStore.transaction(fn conn ->
      case query(
             conn,
             :vortex_claim_target,
             "SELECT frontier,state FROM vortex_request WHERE case_id = ?",
             [id]
           ) do
        [[^peer, state]] when state in ~w(waiting_frontier claimed) ->
          query(
            conn,
            :vortex_claim,
            "UPDATE vortex_request SET state = 'claimed' WHERE case_id = ?",
            [id]
          )

          :ok

        _ ->
          {:error, :not_assigned}
      end
    end)
  end

  def returned_fix(peer, id, payload) do
    CaseStore.transaction(fn conn ->
      case query(
             conn,
             :vortex_return_target,
             "SELECT frontier,state,returned_fix FROM vortex_request WHERE case_id = ?",
             [id]
           ) do
        [[^peer, "claimed", _]] ->
          query(
            conn,
            :vortex_return,
            "UPDATE vortex_request SET state = 'waiting_verification', returned_fix = ? WHERE case_id = ?",
            [Jason.encode!(payload), id]
          )

          :ok

        [[^peer, "waiting_verification", old]] ->
          if Jason.decode!(old) == payload, do: :ok, else: {:error, :conflict}

        _ ->
          {:error, :not_assigned}
      end
    end)
  end

  def acknowledgment(id, peer, room, request_id, message_id) do
    CaseStore.transaction(fn conn ->
      put(
        conn,
        id,
        peer,
        room,
        "receipt",
        request_id,
        %{"message_id" => message_id},
        false,
        message_id
      )

      :ok
    end)
  end

  defp report_payload(record) do
    report = record.report || %{}

    trail =
      Enum.find_value(record.events, "", fn e ->
        if e.kind == "attempt" && e.data["stage"] == "trail", do: e.data["text"]
      end)

    %{
      "case" => record.id,
      "status" => record.status,
      "summary" => String.slice(report["summary"] || "", 0, 300),
      "attempts" => report["attempts"] || 0,
      "commit" => report["commit"],
      "files" => report["files"] || [],
      "check" => report["check"],
      "branch" => report["branch"],
      "worktree" => report["worktree"],
      "dossier" =>
        String.slice(
          report["dossier"] ||
            if(record.status == "failed",
              do: "Interrupted case: inspect the retained record before any repair.",
              else: ""
            ),
          0,
          1200
        ),
      "trail" => String.slice(to_string(trail), 0, 400),
      "record" => CaseRecord.dir(record.id)
    }
  end

  defp put(conn, case_id, peer, room, type, request_id, payload, receipt \\ true, suffix \\ "") do
    id =
      type <> ":" <> Base.encode16(:crypto.hash(:sha256, case_id <> peer <> suffix), case: :lower)

    message = Protocol.envelope(type, id, request_id, payload)

    body =
      case Protocol.encode(message) do
        {:ok, body} ->
          body

        {:error, :too_large} ->
          {:ok, body} =
            Protocol.encode(%{
              message
              | "payload" => Map.take(payload, ~w(case status attempts record))
            })

          body
      end

    query(
      conn,
      :vortex_put_outbox,
      "INSERT OR IGNORE INTO vortex_outbox (id,case_id,peer,room,type,body,receipt) VALUES (?,?,?,?,?,?,?)",
      [id, case_id, peer, room, type, body, if(receipt, do: 1, else: 0)]
    )
  end

  defp query(conn, name, sql, params) do
    {_, %Exqlite.Result{rows: rows}} =
      Exqlite.prepare_execute!(conn, name, sql, params, timeout: :infinity)

    rows || []
  end
end
