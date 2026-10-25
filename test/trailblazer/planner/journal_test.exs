defmodule Trailblazer.Planner.JournalTest do
  # The durable fence of the planning brain: rows are written before effects and
  # read back after a restart, on the real cases.db store.
  use ExUnit.Case, async: false
  alias Trailblazer.Planner.Journal

  setup do
    Trailblazer.CaseStore.transaction(fn conn ->
      Exqlite.query!(
        conn,
        "CREATE TABLE IF NOT EXISTS planner_brain (fingerprint TEXT PRIMARY KEY, lease TEXT NOT NULL, state TEXT NOT NULL, ref TEXT, reason TEXT NOT NULL, at INTEGER NOT NULL)",
        [],
        timeout: :infinity
      )

      Exqlite.query!(conn, "DELETE FROM planner_brain", [], timeout: :infinity)
    end)

    :ok
  end

  test "a recorded attempt reads back whole" do
    :ok = Journal.record("fp-1", "lease-1", "intent", nil, "planning")

    assert %{fingerprint: "fp-1", lease: "lease-1", state: "intent", ref: nil, reason: "planning"} =
             Journal.get("fp-1")
  end

  test "a state transition overwrites the row in place" do
    :ok = Journal.record("fp-1", "lease-1", "intent", nil, "planning")
    :ok = Journal.record("fp-1", "", "dispatched", "probe:abc", "impact")

    assert %{lease: "", state: "dispatched", ref: "probe:abc"} = Journal.get("fp-1")
    assert Journal.unresolved() == []
  end

  test "latest is the most recently written row" do
    :ok = Journal.record("fp-1", "", "wait", nil, "nothing ready")
    :ok = Journal.record("fp-2", "", "error", nil, "boom")

    assert %{fingerprint: "fp-2"} = Journal.latest()
    assert %{fingerprint: "fp-1"} = Journal.get("fp-1")
  end

  test "only intent rows hold an unresolved lease" do
    :ok = Journal.record("fp-intent", "lease-1", "intent", nil, "planning")
    :ok = Journal.record("fp-wait", "", "wait", nil, "nothing ready")
    :ok = Journal.record("fp-error", "", "error", nil, "model error")

    assert [%{fingerprint: "fp-intent", lease: "lease-1"}] = Journal.unresolved()
  end

  test "an unknown fingerprint reads as nil" do
    assert Journal.get("nope") == nil
    assert Journal.latest() == nil
    assert Journal.unresolved() == []
  end
end
