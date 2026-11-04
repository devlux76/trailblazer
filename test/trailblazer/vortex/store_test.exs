defmodule Trailblazer.Vortex.StoreTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Vortex.Store
  alias Trailblazer.Loop.CaseRecord

  setup do
    Trailblazer.CaseStore.transaction(fn conn ->
      for table <- ~w(vortex_outbox vortex_request) do
        Exqlite.query!(conn, "DELETE FROM #{table}", [], timeout: :infinity)
      end
    end)

    request = "request-#{System.unique_integer([:positive])}"

    task = %{
      repo: "/tmp",
      request: "fix",
      check: "true",
      files: [],
      design: [],
      from: "vortex:caller"
    }

    %{request: request, task: task}
  end

  test "admission atomically records one case and accepted outbox before cursor acknowledgment",
       ctx do
    assert {:ok, id, :new} = Store.admit("caller", "room", ctx.request, ctx.task)
    assert CaseRecord.get(id).status == "open"
    assert Store.get(id).state == "waiting_resource"
    assert {:ok, ^id, :duplicate} = Store.admit("caller", "room", ctx.request, ctx.task)

    assert {:error, :conflict} =
             Store.admit("caller", "room", ctx.request, %{ctx.task | request: "different"})

    messages = Enum.filter(Store.outbox(), &(&1.case_id == id))
    assert [%{peer: "caller", type: "accepted"}] = messages
    assert {:error, :unknown_receipt} = Store.receipt("impostor", hd(messages).id)
    assert :ok = Store.receipt("caller", hd(messages).id)
    refute Enum.any?(Store.outbox(), &(&1.case_id == id))
    assert :ok = Store.receipt("caller", hd(messages).id)
  end

  test "an investigation is durable and is marked delivered only by its recipient's receipt" do
    {:new, anomaly_id} =
      Trailblazer.CaseStore.anomaly_report(
        "vortex_probe",
        "probe-#{System.unique_integer([:positive])}",
        ~s({"detail":"fault"}),
        "{}",
        System.os_time(:millisecond)
      )

    anomaly = Enum.find(Trailblazer.Anomaly.list(), &(&1.id == anomaly_id))
    # The test suite's :none transport is not the production transport.
    :ok =
      Trailblazer.CaseStore.transaction(fn conn ->
        Exqlite.query!(conn, "UPDATE anomaly SET sent = 0 WHERE id = ?", [anomaly_id],
          timeout: :infinity
        )

        :ok
      end)

    :ok = Store.investigate(anomaly, {"frontier", "frontier-room"})
    message = Enum.find(Store.outbox(), &(&1.case_id == "anomaly-#{anomaly_id}"))
    assert message.type == "escalation"
    assert Enum.find(Trailblazer.Anomaly.list(), &(&1.id == anomaly_id)).sent == 0
    assert {:error, :unknown_receipt} = Store.receipt("other", message.id)
    :ok = Store.receipt("frontier", message.id)
    assert Enum.find(Trailblazer.Anomaly.list(), &(&1.id == anomaly_id)).sent == 1
  end

  test "a frontier claim is correlated and is not a transport receipt", ctx do
    {:ok, id, _} = Store.admit("caller", "room", ctx.request, ctx.task)
    :ok = CaseRecord.close(id, %{status: :failed, attempts: 3, dossier: "three failures"})
    assert :ok = Store.finish(id, {"frontier", "frontier-room"})
    escalation = Enum.find(Store.outbox(), &(&1.case_id == id and &1.type == "escalation"))
    assert escalation.peer == "frontier"
    assert Store.get(id).state == "waiting_frontier"
    assert :ok = Store.receipt("frontier", escalation.id)
    assert Store.get(id).state == "waiting_frontier"
    assert {:error, :not_assigned} = Store.claim("other", id)
    assert :ok = Store.claim("frontier", id)
    assert Store.get(id).state == "claimed"
    assert :ok = Store.claim("frontier", id)
    assert {:error, :not_assigned} = Store.claim("other", id)
  end

  test "successful report preserves the commit and verification without an interruption dossier",
       ctx do
    {:ok, id, _} = Store.admit("caller", "room", ctx.request, ctx.task)

    :ok =
      CaseRecord.close(id, %{
        status: :fixed,
        attempts: 1,
        commit: String.duplicate("a", 40),
        compiled: %{commit: String.duplicate("b", 40), index: %{pending_vectors: 0}},
        test_bugs: ["vortex:abcdef1"],
        files: ["lib/mirai.ex"],
        check: %{exit: 0, output: "1 test, 0 failures"}
      })

    :ok = Store.finish(id, nil)
    message = Enum.find(Store.outbox(), &(&1.type == "report"))
    {:ok, wire} = Trailblazer.Vortex.Protocol.decode(message.body)
    assert wire["payload"]["commit"] == String.duplicate("a", 40)
    assert wire["payload"]["compiled"]["commit"] == String.duplicate("b", 40)
    assert wire["payload"]["test_bugs"] == ["vortex:abcdef1"]
    assert wire["payload"]["files"] == ["lib/mirai.ex"]
    assert wire["payload"]["check"]["exit"] == 0
    refute wire["payload"]["dossier"] =~ "Interrupted"
  end

  test "returned fix requires the assigned claim and remains visible across reads", ctx do
    {:ok, id, _} = Store.admit("caller", "room", ctx.request, ctx.task)
    :ok = CaseRecord.close(id, %{status: :failed, attempts: 3})
    :ok = Store.finish(id, {"frontier", "frontier-room"})

    fix = %{
      "case" => id,
      "base" => String.duplicate("a", 40),
      "commit" => String.duplicate("b", 40)
    }

    assert {:error, :not_assigned} = Store.returned_fix("frontier", id, fix)
    assert :ok = Store.claim("frontier", id)
    assert {:error, :not_assigned} = Store.returned_fix("other", id, fix)
    assert :ok = Store.returned_fix("frontier", id, fix)
    assert :ok = Store.returned_fix("frontier", id, fix)

    assert {:error, :conflict} =
             Store.returned_fix("frontier", id, %{fix | "commit" => String.duplicate("c", 40)})

    assert Store.get(id).state == "waiting_verification"
    assert Store.get(id).returned_fix == fix
    assert CaseRecord.get(id).status == "failed"
  end
end
