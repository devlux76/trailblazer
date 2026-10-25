defmodule Trailblazer.Loop.CaseRecordTest do
  use ExUnit.Case, async: false

  alias Trailblazer.{CaseStore, Config}
  alias Trailblazer.Loop.CaseRecord

  @task %{
    repo: "/tmp/sojourney",
    request: "Fix the head bob",
    files: ["src/player.ts"],
    from: "cli"
  }

  test "a case is recorded in order, whole, and comes back as it was written" do
    assert {:ok, id} = CaseRecord.open(@task)

    :ok = CaseRecord.event(id, :prompt, %{messages: [%{role: "user", content: "hi"}]})
    :ok = CaseRecord.event(id, :reply, %{content: "ok", reasoning: "thinking", tool_calls: []})
    :ok = CaseRecord.event(id, :check, %{status: :pass, exit: 0, output_tail: ""})
    :ok = CaseRecord.close(id, %{status: :fixed, summary: "Done."})

    record = CaseRecord.get(id)
    assert record.id == id
    assert record.status == "fixed"
    assert record.task["request"] == "Fix the head bob"
    assert record.report["summary"] == "Done."
    assert Enum.map(record.events, & &1.kind) == ~w(prompt reply check report)
    assert Enum.map(record.events, & &1.seq) == [1, 2, 3, 4]
    assert [%{data: %{"messages" => [%{"content" => "hi"}]}} | _] = record.events
    assert Enum.at(record.events, 2).data["status"] == "pass"
    assert is_integer(record.opened_at) and is_integer(record.closed_at)
  end

  test "large text is kept in a file beside the record, verbatim, and read back" do
    {:ok, id} = CaseRecord.open(@task)
    big = String.duplicate("line of a long prompt\n", 2_000)
    :ok = CaseRecord.event(id, :prompt, %{content: big})

    dir = Path.join([Config.get(:state_dir), "cases", id])
    assert [file] = File.ls!(dir)
    assert File.read!(Path.join(dir, file)) == big

    assert [%{data: %{"content" => ^big}}] = CaseRecord.get(id).events

    assert [%{data: %{"content" => %{"$file" => ^file}}}] =
             CaseRecord.get(id, inline: false).events
  end

  test "A4: model text that is not valid UTF-8 is kept byte for byte" do
    {:ok, id} = CaseRecord.open(@task)
    bad = "caf" <> <<0xE9>> <> " “quoted”"
    :ok = CaseRecord.event(id, :reply, %{content: bad})
    assert [%{data: %{"content" => ^bad}}] = CaseRecord.get(id).events
  end

  test "D4: a bad kind or an unknown case is an error, not an exception, and writes nothing" do
    {:ok, id} = CaseRecord.open(@task)
    assert {:error, {:bad_kind, :gossip}} = CaseRecord.event(id, :gossip, %{})
    assert {:error, :no_case} = CaseRecord.event("nope", :prompt, %{})
    assert CaseRecord.get("nope") == nil
    assert CaseRecord.get(id).events == []
  end

  test "a closed case takes no more events; closing twice is an error" do
    {:ok, id} = CaseRecord.open(@task)
    :ok = CaseRecord.close(id, %{status: :failed, summary: "x"})
    assert {:error, :closed} = CaseRecord.event(id, :prompt, %{})
    assert {:error, :closed} = CaseRecord.close(id, %{status: :fixed})
  end

  test "G-class: case ids are unique and safe as a branch name" do
    ids = for _ <- 1..50, do: elem(CaseRecord.open(@task), 1)
    assert length(Enum.uniq(ids)) == 50

    for id <- ids do
      assert id =~ ~r/^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$/
      assert {_, 0} = System.cmd("git", ["check-ref-format", "--branch", "trailblazer/#{id}"])
    end
  end

  test "E9: a case left open by a crash is still whole up to its last event, and listed as open" do
    {:ok, id} = CaseRecord.open(@task)
    :ok = CaseRecord.event(id, :attempt, %{n: 1})
    :ok = CaseRecord.event(id, :edit, %{paths: ["a.ex"]})

    # The case store restarting (the service killed mid-attempt) loses nothing.
    :ok = Supervisor.terminate_child(Trailblazer.Supervisor, CaseStore)
    {:ok, _} = Supervisor.restart_child(Trailblazer.Supervisor, CaseStore)

    record = CaseRecord.get(id)
    assert record.status == "open"
    assert Enum.map(record.events, & &1.kind) == ~w(attempt edit)
    assert id in CaseRecord.open_cases()
  end

  # L9: with a large vendor repository being re-watched, `trailblazer run`
  # timed out opening its case behind the graph Store's one connection.
  test "E23: case records do not wait for the graph store" do
    me = self()

    # the graph store is held until this test lets it go (B9: on a message,
    # not a sleep); the case's writes complete while it is still held
    busy =
      Task.async(fn ->
        GenServer.call(
          Trailblazer.Store,
          {:run, :write,
           fn _conn ->
             send(me, {:holding, self()})

             receive do
               :release -> :ok
             end
           end},
          :infinity
        )
      end)

    assert_receive {:holding, store}
    on_exit(fn -> if Process.alive?(busy.pid), do: send(store, :release) end)
    {:ok, id} = CaseRecord.open(@task)
    :ok = CaseRecord.event(id, :attempt, %{n: 1})
    :ok = CaseRecord.close(id, %{status: :failed, summary: "x"})
    assert CaseRecord.get(id).status == "failed"

    send(store, :release)
    Task.await(busy, :infinity)
  end

  # Codex's review of L5: a reply holding `%{"$file" => "../../x"}` was taken
  # for a spill pointer and read a file outside the case.
  test "model data with a reserved key stays data and never names a file" do
    outside = Path.join(Config.get(:state_dir), "outside-case.txt")
    File.write!(outside, "outside-case-proof")
    on_exit(fn -> File.rm(outside) end)

    {:ok, id} = CaseRecord.open(@task)
    :ok = CaseRecord.event(id, :prompt, String.duplicate("x", 5000))
    payload = %{"$file" => "../../outside-case.txt", "$$x" => 1, "sha256" => "00"}
    :ok = CaseRecord.event(id, :reply, payload)
    assert List.last(CaseRecord.get(id).events).data == payload
  end

  test "a spilled file that was changed is not passed off as the record" do
    {:ok, id} = CaseRecord.open(@task)
    :ok = CaseRecord.event(id, :reply, %{content: String.duplicate("y", 5000)})
    [file] = File.ls!(CaseRecord.dir(id))
    File.write!(Path.join(CaseRecord.dir(id), file), "tampered")

    assert [%{data: %{"content" => %{"$file" => ^file, "missing" => true}}}] =
             CaseRecord.get(id).events
  end

  test "terms that JSON has no word for are recorded readably" do
    {:ok, id} = CaseRecord.open(@task)
    :ok = CaseRecord.event(id, :check, %{status: :timeout, error: {:http, 500}, exit: nil})
    assert [%{data: data}] = CaseRecord.get(id).events
    assert data == %{"status" => "timeout", "error" => ["http", 500], "exit" => nil}
  end
end
