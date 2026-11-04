defmodule Trailblazer.Loop.Permission do
  @moduledoc "Durable permission requests; expiry never closes a case or deletes its work."
  alias Trailblazer.{CaseStore, Events}
  @active ~w(waiting granted resuming)
  @outcomes ~w(grant refuse escalate amend_policy)
  @fields ~w(request_id nonce binding evidence_sha256 base policy_hash source_hash exception_hash outcome reason exception_ids commit_paths normalizations)

  def open(case_id, consumer, evidence, checkpoint, opts) do
    with {:ok, evidence} <- data(evidence),
         {:ok, checkpoint} <- data(checkpoint),
         {:ok, notification_policy} <- policy_data(opts[:notification_policy]),
         true <- is_map(evidence) and is_map(checkpoint),
         true <- is_binary(consumer) and Regex.match?(~r/\A[a-z][a-z0-9_.-]{0,63}\z/, consumer),
         true <- valid_evidence?(evidence, checkpoint),
         frontiers = Keyword.get(opts, :frontiers, []),
         true <-
           frontiers != [] and is_list(frontiers) and
             Enum.all?(frontiers, &(is_binary(&1) and &1 != "")),
         true <- policy_frontiers?(notification_policy, frontiers),
         now = Keyword.get(opts, :now_ms, System.os_time(:millisecond)),
         timeout = Keyword.get(opts, :timeout_ms, 14_400_000),
         true <- is_integer(now) and is_integer(timeout) and timeout > 0,
         hard_deadline = Keyword.get(opts, :hard_deadline_ms, now + timeout),
         true <- is_integer(hard_deadline) do
      repo = checkpoint["repo"]

      transact(fn conn ->
        case query(conn, :permission_owner, "SELECT repo,task,status FROM task_case WHERE id=?", [
               case_id
             ]) do
          [[^repo, task, "open"]] ->
            owner = Jason.decode!(task)["from"] || "cli"

            base = %{
              "case_id" => case_id,
              "consumer" => consumer,
              "repo" => repo,
              "owner" => owner,
              "frontiers" => Enum.sort(Enum.uniq(frontiers)),
              "base" => evidence["base"],
              "policy_hash" => evidence["policy_hash"],
              "source_hash" => evidence["source_hash"],
              "exception_hash" => evidence["exception_hash"],
              "evidence_sha256" => digest(evidence),
              "checkpoint_sha256" => digest(checkpoint)
            }

            base =
              if notification_policy,
                do: Map.put(base, "notification_policy_hash", digest(notification_policy)),
                else: base

            binding = digest(base)
            previous = latest(conn, case_id)

            cond do
              previous && previous["state"] in @active && previous["binding"] == binding ->
                {{:ok, previous["id"]}, nil}

              previous && previous["state"] in @active ->
                {{:error, :pending_changed}, nil}

              true ->
                deadline = min(now + timeout, hard_deadline)

                if deadline <= now do
                  {{:error, :deadline_elapsed}, nil}
                else
                  lifetime = deadline - now

                  r =
                    Map.merge(base, %{
                      "id" => "perm-" <> random(),
                      "nonce" => random(),
                      "binding" => binding,
                      "evidence" => evidence,
                      "checkpoint" => checkpoint,
                      "created_at" => now,
                      "deadline_at" => deadline,
                      "remind_at" => now + max(lifetime - 1_800_000, div(lifetime, 2)),
                      "state" => "waiting",
                      "version" => 0,
                      "notification_policy" => notification_policy,
                      "notification_ready" => false,
                      "notifications" => [],
                      "answers" => []
                    })

                  save(conn, r, now, fn next -> {:ok, next["id"]} end)
                end
            end

          [] ->
            {{:error, :no_case}, nil}

          [[_, _, status]] when status != "open" ->
            {{:error, :case_closed}, nil}

          _ ->
            {{:error, :checkpoint_repo_mismatch}, nil}
        end
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def get(id), do: CaseStore.transaction(&fetch(&1, id))
  def for_case(id), do: CaseStore.transaction(&latest(&1, id))

  def pending do
    CaseStore.transaction(fn conn ->
      query(
        conn,
        :permission_pending,
        "SELECT record FROM permission_request WHERE state IN ('waiting','granted','resuming') ORDER BY rowid",
        []
      )
      |> Enum.map(fn [json] -> Jason.decode!(json) end)
    end)
  end

  @doc "Peer must come from verified transport identity, never a decision-body field."
  def decide(id, peer, decision, now) when is_integer(now) do
    with {:ok, decision} <- data(decision), true <- is_map(decision) do
      change(id, fn conn, r ->
        answer_digest = digest([peer, decision])

        cond do
          peer not in r["frontiers"] ->
            {{:error, :unauthorized_decider}, nil}

          r["state"] == "expired" ->
            {{:error, :expired}, nil}

          Enum.any?(r["answers"], &(&1["sha256"] == answer_digest)) ->
            {{:ok, r}, nil}

          r["state"] != "waiting" ->
            {{:error, :already_decided}, nil}

          now >= r["deadline_at"] ->
            expire_record(conn, r, now, {:error, :expired})

          not valid_answer?(r, decision) ->
            {{:error, :invalid_decision}, nil}

          true ->
            outcome = decision["outcome"]

            state =
              case outcome do
                "grant" -> "granted"
                "refuse" -> "refused"
                _ -> "waiting"
              end

            answer = %{
              "peer" => peer,
              "decision" => decision,
              "at" => now,
              "sha256" => answer_digest
            }

            next = r |> Map.put("state", state) |> Map.put("answers", r["answers"] ++ [answer])
            save(conn, next, now, &{:ok, &1})
        end
      end)
    else
      _ -> {:error, :invalid_decision}
    end
  end

  def expire(id, now) when is_integer(now) do
    change(id, fn conn, r ->
      cond do
        r["state"] == "expired" -> {{:ok, r}, nil}
        r["state"] != "waiting" -> {{:error, :already_decided}, nil}
        now < r["deadline_at"] -> {{:error, :not_due}, nil}
        true -> expire_record(conn, r, now, nil)
      end
    end)
  end

  def claim_resume(id, now \\ System.os_time(:millisecond)) when is_integer(now) do
    change(id, fn conn, r ->
      if r["state"] == "granted",
        do:
          save(
            conn,
            Map.put(r, "state", "resuming"),
            now,
            &{:ok, &1["checkpoint"]}
          ),
        else: {{:error, :not_granted}, nil}
    end)
  end

  def finish_resume(id, outcome, now \\ System.os_time(:millisecond))
      when is_binary(outcome) and is_integer(now) do
    change(id, fn conn, r ->
      if r["state"] == "resuming",
        do:
          save(
            conn,
            Map.merge(r, %{"state" => "resumed", "resume_outcome" => outcome}),
            now,
            &{:ok, &1}
          ),
        else: {{:error, :not_resuming}, nil}
    end)
  end

  @doc "Host-only: called after this case's resource release is confirmed, never by a peer/API."
  def notifications_ready(id, now) when is_integer(now) do
    change(id, fn conn, r ->
      cond do
        r["state"] != "waiting" -> {{:error, :already_decided}, nil}
        now >= r["deadline_at"] -> expire_record(conn, r, now, {:error, :expired})
        r["notification_policy"] == nil -> {{:error, :not_configured}, nil}
        r["notification_ready"] -> {{:ok, r}, nil}
        true -> save(conn, Map.put(r, "notification_ready", true), now, &{:ok, &1})
      end
    end)
  end

  @doc "Claim BEFORE effects; an unresolved claim after a crash is consumed, never replayed."
  def claim_notification(id, peer, ordinal, now) when is_integer(now) do
    change(id, fn conn, r ->
      notes = Map.get(r, "notifications", [])

      cond do
        peer not in r["frontiers"] ->
          {{:error, :unauthorized_decider}, nil}

        ordinal not in [0, 1] ->
          {{:error, :invalid_ordinal}, nil}

        r["state"] != "waiting" ->
          {{:error, :already_decided}, nil}

        now >= r["deadline_at"] ->
          expire_record(conn, r, now, {:error, :expired})

        r["notification_ready"] != true ->
          {{:error, :not_ready}, nil}

        Enum.any?(notes, &(&1["peer"] == peer and &1["ordinal"] == ordinal)) ->
          {{:error, :already_claimed}, nil}

        ordinal == 1 and now < r["remind_at"] ->
          {{:error, :not_due}, nil}

        ordinal == 1 and not Enum.any?(notes, &(&1["peer"] == peer and &1["ordinal"] == 0)) ->
          {{:error, :initial_not_attempted}, nil}

        true ->
          note = %{"peer" => peer, "ordinal" => ordinal, "state" => "claimed", "at" => now}
          save(conn, Map.put(r, "notifications", notes ++ [note]), now, &{:ok, &1})
      end
    end)
  end

  def record_notification(id, peer, ordinal, result, now) when is_integer(now) do
    with {:ok, result} <- data(result), true <- delivery?(result) do
      change(id, fn conn, r ->
        notes = Map.get(r, "notifications", [])
        index = Enum.find_index(notes, &(&1["peer"] == peer and &1["ordinal"] == ordinal))
        note = index && Enum.at(notes, index)

        cond do
          note == nil ->
            {{:error, :not_claimed}, nil}

          note["result"] == result ->
            {{:ok, r}, nil}

          note["state"] != "claimed" ->
            {{:error, :conflict}, nil}

          true ->
            updated =
              Map.merge(note, %{"state" => "recorded", "result" => result, "finished_at" => now})

            save(
              conn,
              Map.put(r, "notifications", List.replace_at(notes, index, updated)),
              now,
              &{:ok, &1}
            )
        end
      end)
    else
      _ -> {:error, :invalid_delivery}
    end
  end

  defp delivery?(d) when is_map(d) do
    Enum.all?(Map.keys(d), &(&1 in ~w(delivery exit ms turn_id))) and
      d["delivery"] in ~w(host_admitted queued unknown failure) and
      (d["exit"] == nil or is_integer(d["exit"])) and is_integer(d["ms"]) and d["ms"] >= 0 and
      (not Map.has_key?(d, "turn_id") or
         (is_binary(d["turn_id"]) and byte_size(d["turn_id"]) in 1..100))
  end

  defp delivery?(_), do: false

  defp policy_data(nil), do: {:ok, nil}

  defp policy_data(policy) do
    with {:ok, p} <- data(policy),
         true <- is_map(p) and is_map(p["deciders"]),
         true <-
           map_size(p["deciders"]) > 0 and
             Enum.all?(p["deciders"], fn {_, d} ->
               is_map(d) and is_binary(d["peer"]) and is_binary(d["room"])
             end),
         do: {:ok, p},
         else: (_ -> {:error, :invalid_policy})
  end

  defp policy_frontiers?(nil, _), do: true

  defp policy_frontiers?(policy, frontiers) do
    peers = Enum.map(policy["deciders"], fn {_, d} -> d["peer"] end)
    Enum.all?(frontiers, &(&1 in peers))
  end

  defp valid_evidence?(e, c) do
    hash?(e["base"], 40) and c["base"] == e["base"] and is_binary(c["repo"]) and
      Enum.all?(~w(policy_hash source_hash exception_hash), &hash?(e[&1], 64)) and
      is_list(e["exceptions"]) and e["exceptions"] != [] and
      Enum.all?(e["exceptions"], &(is_map(&1) and is_binary(&1["id"]) and &1["id"] != "")) and
      Enum.uniq_by(e["exceptions"], & &1["id"]) == e["exceptions"] and
      Enum.all?(~w(committable_paths required_commit_paths), fn key ->
        values = Map.get(e, key, [])
        is_list(values) and Enum.all?(values, &is_binary/1)
      end) and
      is_list(Map.get(e, "normalizations", [])) and
      Enum.all?(Map.get(e, "normalizations", []), &(is_map(&1) and is_binary(&1["id"])))
  end

  defp valid_answer?(r, d) do
    Enum.all?(Map.keys(d), &(&1 in @fields)) and
      (not Map.has_key?(d, "request_id") or d["request_id"] == r["id"]) and
      Enum.all?(~w(base policy_hash source_hash exception_hash), &(d[&1] == r[&1])) and
      d["nonce"] == r["nonce"] and d["binding"] == r["binding"] and
      d["evidence_sha256"] == r["evidence_sha256"] and
      d["outcome"] in @outcomes and is_binary(d["reason"]) and String.trim(d["reason"]) != "" and
      byte_size(d["reason"]) <= 1000 and
      selections?(r["evidence"], d)
  end

  defp selections?(e, d) do
    ids = Enum.map(e["exceptions"], & &1["id"])
    chosen = Map.get(d, "exception_ids", [])
    paths = Map.get(d, "commit_paths", [])
    actions = Map.get(d, "normalizations", [])
    offered = Enum.map(Map.get(e, "normalizations", []), & &1["id"])

    Enum.all?([chosen, paths, actions], &is_list/1) and
      Enum.all?(chosen, &(&1 in ids)) and
      Enum.all?(paths, &(&1 in Map.get(e, "committable_paths", []))) and
      Enum.all?(actions, &(&1 in offered)) and
      (d["outcome"] != "grant" or
         (Enum.sort(chosen) == Enum.sort(ids) and
            Enum.all?(Map.get(e, "required_commit_paths", []), &(&1 in paths))))
  end

  defp expire_record(conn, r, now, reply) do
    save(conn, Map.merge(r, %{"state" => "expired", "reason" => "no_decision"}), now, fn next ->
      reply || {:ok, next}
    end)
  end

  defp change(id, fun) do
    transact(fn conn ->
      case fetch(conn, id) do
        nil ->
          {{:error, :no_request}, nil}

        r ->
          case query(conn, :permission_case_open, "SELECT status FROM task_case WHERE id=?", [
                 r["case_id"]
               ]) do
            [["open"]] -> fun.(conn, r)
            _ -> {{:error, :case_closed}, nil}
          end
      end
    end)
  end

  defp save(conn, r, now, reply) do
    next = Map.update!(r, "version", &(&1 + 1))

    query(
      conn,
      :permission_save,
      "INSERT INTO permission_request(id,case_id,version,state,deadline_at,record) VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET version=excluded.version,state=excluded.state,deadline_at=excluded.deadline_at,record=excluded.record WHERE permission_request.version=excluded.version-1",
      [
        next["id"],
        next["case_id"],
        next["version"],
        next["state"],
        next["deadline_at"],
        Jason.encode!(next)
      ]
    )

    if query(conn, :permission_changes, "SELECT changes()", []) == [[1]] do
      journal(conn, next, now, reply)
    else
      {{:error, :conflict}, nil}
    end
  end

  defp journal(conn, next, now, reply) do
    [[seq]] =
      query(
        conn,
        :permission_seq,
        "SELECT COALESCE(MAX(seq),0)+1 FROM case_event WHERE case_id=?",
        [next["case_id"]]
      )

    event = %{
      "request" => next["id"],
      "version" => next["version"],
      "state" => next["state"],
      "binding" => next["binding"]
    }

    query(
      conn,
      :permission_event,
      "INSERT INTO case_event(case_id,seq,kind,at,data) VALUES (?,?,'permission',?,?)",
      [next["case_id"], seq, now, Jason.encode!(event)]
    )

    {reply.(next), {next["case_id"], seq}}
  end

  defp transact(fun) do
    {reply, notice} = CaseStore.transaction(fun)

    if notice do
      {id, seq} = notice
      Events.publish({:case, id}, %{seq: seq, kind: "permission", closed: false})
    end

    reply
  end

  defp fetch(conn, id),
    do:
      decode(
        query(conn, :permission_get, "SELECT record FROM permission_request WHERE id=?", [id])
      )

  defp latest(conn, id),
    do:
      decode(
        query(
          conn,
          :permission_latest,
          "SELECT record FROM permission_request WHERE case_id=? ORDER BY rowid DESC LIMIT 1",
          [id]
        )
      )

  defp decode([]), do: nil
  defp decode([[json]]), do: Jason.decode!(json)

  defp query(conn, name, sql, params) do
    {_, %Exqlite.Result{rows: rows}} =
      Exqlite.prepare_execute!(conn, name, sql, params, timeout: :infinity)

    rows || []
  end

  defp data(value) do
    {:ok, value |> Jason.encode!() |> Jason.decode!()}
  rescue
    _ -> {:error, :not_data}
  end

  defp hash?(s, n), do: is_binary(s) and byte_size(s) == n and Regex.match?(~r/\A[0-9a-f]+\z/, s)
  defp random, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp digest(value),
    do: :crypto.hash(:sha256, Jason.encode!(canonical(value))) |> Base.encode16(case: :lower)

  defp canonical(m) when is_map(m),
    do: ["map", Enum.map(Enum.sort(m), fn {k, v} -> [k, canonical(v)] end)]

  defp canonical(l) when is_list(l), do: ["list", Enum.map(l, &canonical/1)]
  defp canonical(v), do: v
end
