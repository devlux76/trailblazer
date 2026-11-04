defmodule Trailblazer.Loop.PermissionTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Loop.{CaseRecord, Permission}

  setup do
    root = Path.join(System.tmp_dir!(), "permission-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "partial.bin"), <<0, 255, 1>>)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, id} = CaseRecord.open(%{repo: root, request: "fix", from: "vortex:caller"})

    evidence = %{
      "base" => String.duplicate("a", 40),
      "policy_hash" => String.duplicate("b", 64),
      "source_hash" => String.duplicate("c", 64),
      "exception_hash" => String.duplicate("d", 64),
      "exceptions" => [%{"id" => "dir-mode", "path" => "dist"}],
      "committable_paths" => ["bundle"],
      "required_commit_paths" => ["bundle"],
      "normalizations" => [%{"id" => "restore-mode"}]
    }

    checkpoint = %{
      "repo" => root,
      "base" => evidence["base"],
      "stage" => "artifact_observed",
      "files" => [
        %{
          "path" => "partial.bin",
          "bytes_base64" => Base.encode64(<<0, 255, 1>>),
          "mode" => 0o600
        }
      ],
      "partial_reply" => "unfinished thought"
    }

    %{case_id: id, evidence: evidence, checkpoint: checkpoint, root: root}
  end

  defp open(c, extra \\ []) do
    Permission.open(
      c.case_id,
      "artifact_scope",
      c.evidence,
      c.checkpoint,
      Keyword.merge(
        [frontiers: ["frontier-a", "frontier-b"], now_ms: 1000, timeout_ms: 4000],
        extra
      )
    )
  end

  defp answer(r, outcome \\ "grant", extra \\ %{}) do
    Map.merge(
      %{
        "nonce" => r["nonce"],
        "binding" => r["binding"],
        "evidence_sha256" => r["evidence_sha256"],
        "base" => r["base"],
        "policy_hash" => r["policy_hash"],
        "source_hash" => r["source_hash"],
        "exception_hash" => r["exception_hash"],
        "outcome" => outcome,
        "reason" => "directory-only consequence",
        "exception_ids" => ["dir-mode"],
        "commit_paths" => ["bundle"],
        "normalizations" => []
      },
      extra
    )
  end

  test "opening is durable and idempotent, and atomically journals an open case", c do
    assert {:ok, id} = open(c)
    r = Permission.get(id)
    assert r["state"] == "waiting"
    assert r["deadline_at"] == 5000
    assert r["remind_at"] > r["created_at"] and r["remind_at"] < r["deadline_at"]
    assert r["checkpoint"] == c.checkpoint
    assert r["evidence"] == c.evidence
    assert {:ok, ^id} = open(c, now_ms: 2000)
    assert Permission.for_case(c.case_id)["id"] == id
    record = CaseRecord.get(c.case_id)
    assert record.status == "open"
    assert Enum.count(record.events, &(&1.kind == "permission")) == 1
    assert Enum.any?(Permission.pending(), &(&1["id"] == id))
  end

  test "only a bound frontier answer can grant and claim one continuation", c do
    {:ok, id} = open(c)
    r = Permission.get(id)
    assert {:error, :unauthorized_decider} = Permission.decide(id, "caller", answer(r), 2000)

    for invalid <- [
          %{"binding" => "wrong"},
          %{"base" => String.duplicate("f", 40)},
          %{"policy_hash" => String.duplicate("f", 64)},
          %{"source_hash" => String.duplicate("f", 64)},
          %{"exception_hash" => String.duplicate("f", 64)},
          %{"nonce" => "wrong"},
          %{"evidence_sha256" => "wrong"},
          %{"tier" => "local"},
          %{"command" => "chmod 777 /"},
          %{"normalizations" => ["arbitrary-shell"]},
          %{"commit_paths" => []},
          %{"exception_ids" => []},
          %{"reason" => ""}
        ] do
      assert {:error, _} = Permission.decide(id, "frontier-a", answer(r, "grant", invalid), 2000)
    end

    assert {:ok, granted} = Permission.decide(id, "frontier-a", answer(r), 2000)
    assert granted["state"] == "granted"
    assert {:ok, ^granted} = Permission.decide(id, "frontier-a", answer(r), 2001)
    assert {:ok, checkpoint} = Permission.claim_resume(id)
    assert checkpoint == c.checkpoint
    assert {:error, :not_granted} = Permission.claim_resume(id)
    assert {:ok, _} = Permission.finish_resume(id, "fixed")
    assert Permission.get(id)["state"] == "resumed"
    assert CaseRecord.get(c.case_id).status == "open"
  end

  test "expiry refuses the request but preserves all work and permits an explicit new request",
       c do
    {:ok, id} = open(c)
    r = Permission.get(id)
    assert {:error, :not_due} = Permission.expire(id, 4999)
    assert {:ok, expired} = Permission.expire(id, 5000)
    assert expired["state"] == "expired" and expired["reason"] == "no_decision"
    assert {:error, :expired} = Permission.decide(id, "frontier-a", answer(r), 5001)
    assert File.read!(Path.join(c.root, "partial.bin")) == <<0, 255, 1>>
    assert Permission.get(id)["checkpoint"] == c.checkpoint
    assert CaseRecord.get(c.case_id).status == "open"
    assert {:ok, next} = open(c, now_ms: 6000)
    refute next == id
    assert {:error, :expired} = Permission.decide(id, "frontier-a", answer(r), 6001)
  end

  test "grant versus expiry has one winner and journals the final transition", c do
    {:ok, id} = open(c)
    r = Permission.get(id)

    results =
      [
        Task.async(fn -> Permission.decide(id, "frontier-a", answer(r), 4999) end),
        Task.async(fn -> Permission.expire(id, 5000) end)
      ]
      |> Enum.map(&Task.await/1)

    assert length(results) == 2
    assert Permission.get(id)["state"] in ["expired", "granted"]

    assert Enum.count(
             CaseRecord.get(c.case_id).events,
             &(&1.data["state"] in ["expired", "granted"])
           ) == 1
  end

  test "escalation and policy proposals are audited without executing or self-applying", c do
    {:ok, id} = open(c)
    r = Permission.get(id)

    for outcome <- ["escalate", "amend_policy"] do
      assert {:ok, next} = Permission.decide(id, "frontier-a", answer(r, outcome), 2000)
      assert next["state"] == "waiting"
    end

    assert {:ok, refused} = Permission.decide(id, "frontier-b", answer(r, "refuse"), 2001)
    assert refused["state"] == "refused"
    assert {:error, :not_granted} = Permission.claim_resume(id)
    assert refused["checkpoint"] == c.checkpoint
  end

  test "closed cases, missing authority, bad evidence and changed pending checkpoints are refused",
       c do
    assert {:error, _} = open(c, frontiers: [])

    assert {:error, _} =
             Permission.open(
               c.case_id,
               "artifact_scope",
               %{c.evidence | "base" => "bad"},
               c.checkpoint,
               frontiers: ["frontier-a"]
             )

    {:ok, id} = open(c)

    assert {:error, :pending_changed} =
             Permission.open(
               c.case_id,
               "artifact_scope",
               c.evidence,
               Map.put(c.checkpoint, "partial_reply", "changed"),
               frontiers: ["frontier-a"],
               now_ms: 1000
             )

    :ok = CaseRecord.close(c.case_id, %{status: :failed})

    assert {:error, :case_closed} =
             Permission.decide(id, "frontier-a", answer(Permission.get(id)), 2000)
  end

  test "stored evidence survives writer restart with four-hour default and late reminder", c do
    assert {:ok, id} =
             Permission.open(c.case_id, "artifact_scope", c.evidence, c.checkpoint,
               frontiers: ["frontier-a"],
               now_ms: 1000
             )

    expected = Permission.get(id)
    assert expected["deadline_at"] == 14_401_000
    assert expected["remind_at"] == 12_601_000
    :ok = Supervisor.terminate_child(Trailblazer.Supervisor, Trailblazer.CaseStore)
    {:ok, _} = Supervisor.restart_child(Trailblazer.Supervisor, Trailblazer.CaseStore)
    assert Permission.get(id) == expected
    assert CaseRecord.get(c.case_id).status == "open"
  end

  test "resume transitions use the supplied clock in their atomic journal events", c do
    {:ok, id} = open(c)
    {:ok, _} = Permission.decide(id, "frontier-a", answer(Permission.get(id)), 2000)
    assert {:ok, _} = Permission.claim_resume(id, 2100)
    assert {:ok, _} = Permission.finish_resume(id, "checked", 2200)
    transitions = CaseRecord.get(c.case_id).events |> Enum.take(-2)
    assert Enum.map(transitions, & &1.at) == [2100, 2200]
    assert Enum.map(transitions, & &1.data["state"]) == ["resuming", "resumed"]
  end

  test "a lost permission CAS returns conflict without an event or writer restart", c do
    {:ok, id} = open(c)
    before = Permission.get(id)
    writer = Process.whereis(Trailblazer.CaseStore)
    trigger = "permission_cas_test"

    sql =
      "CREATE TRIGGER #{trigger} BEFORE UPDATE ON permission_request WHEN OLD.id = '#{id}' BEGIN SELECT RAISE(IGNORE); END"

    Trailblazer.CaseStore.transaction(fn conn ->
      Exqlite.prepare_execute!(conn, :permission_test_trigger, sql, [])
    end)

    on_exit(fn ->
      Trailblazer.CaseStore.transaction(fn conn ->
        Exqlite.prepare_execute!(
          conn,
          :permission_test_drop,
          "DROP TRIGGER IF EXISTS #{trigger}",
          []
        )
      end)
    end)

    assert {:error, :conflict} = Permission.expire(id, 5000)
    assert Process.whereis(Trailblazer.CaseStore) == writer
    assert Permission.get(id) == before
    assert length(CaseRecord.get(c.case_id).events) == 1
  end
end
