defmodule Trailblazer.LoopAPITest do
  use ExUnit.Case, async: false
  import Plug.Test
  alias Trailblazer.{API, Loop.CaseRecord, Loop.Runner}

  setup do
    parent = self()

    runner =
      start_supervised!(
        {Runner,
         name: nil,
         prepare: fn _ -> :ok end,
         run: fn task, opts ->
           send(parent, {:started, task, self(), opts[:case_id]})

           receive do
             :finish -> CaseRecord.close(opts[:case_id], %{case: opts[:case_id], status: :fixed})
           end
         end}
      )

    %{opts: API.init(token: "test-secret", runner: runner)}
  end

  defp request(opts, op, body, token \\ "test-secret") do
    conn(:post, "/" <> op, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> API.call(opts)
  end

  defp lines(body), do: body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  # B3: the CLI polled /case every second; now it follows the case's events.
  test "J2: follow streams the task, every event once and in order, then the report", %{
    opts: opts
  } do
    {:ok, id} = CaseRecord.open(%{repo: "/fixture", request: "fix"})
    :ok = CaseRecord.event(id, :attempt, %{n: 1})

    follower = Task.async(fn -> request(opts, "case", %{case: id, follow: true}) end)

    :ok = CaseRecord.event(id, :edit, %{paths: ["a.ex"]})
    :ok = CaseRecord.event(id, :check, %{status: "pass"})
    :ok = CaseRecord.close(id, %{case: id, status: :fixed, summary: "Done."})

    response = Task.await(follower)
    assert response.status == 200
    assert [first | rest] = lines(response.resp_body)
    assert first["case"] == id
    assert first["task"]["request"] == "fix"
    {events, [last]} = Enum.split(rest, -1)
    assert Enum.map(events, & &1["event"]["kind"]) == ~w(attempt edit check)
    seqs = Enum.map(events, & &1["event"]["seq"])
    assert seqs == Enum.sort(Enum.uniq(seqs))
    assert last["report"]["status"] == "fixed"
  end

  test "follow on a closed case answers at once; on an unknown one, 404", %{opts: opts} do
    {:ok, id} = CaseRecord.open(%{repo: "/fixture", request: "fix"})
    :ok = CaseRecord.close(id, %{case: id, status: :failed, summary: "x"})

    response = request(opts, "case", %{case: id, follow: true})
    assert [%{"case" => ^id}, %{"report" => %{"status" => "failed"}}] = lines(response.resp_body)
    assert request(opts, "case", %{case: "nope", follow: true}).status == 404
  end

  test "anomalies lists open ones; ack closes one, and a second ack is a 404", %{opts: opts} do
    subject = "api-#{System.unique_integer([:positive])}"
    {:ok, id} = Trailblazer.Anomaly.report(:test, subject, %{n: 1})

    listed = request(opts, "anomalies", %{})
    assert listed.status == 200
    assert Enum.any?(Jason.decode!(listed.resp_body)["anomalies"], &(&1["id"] == id))

    assert request(opts, "ack", %{id: id}).status == 200
    assert request(opts, "ack", %{id: id}).status == 404
    assert request(opts, "ack", %{id: "x"}).status == 400

    open = Jason.decode!(request(opts, "anomalies", %{}).resp_body)["anomalies"]
    refute Enum.any?(open, &(&1["id"] == id))
    all = Jason.decode!(request(opts, "anomalies", %{all: true}).resp_body)["anomalies"]
    assert Enum.any?(all, &(&1["id"] == id))
  end

  # L9: Runner.submit timed out and the API answered an empty 500.
  test "E23: a runner that does not answer gives a 503 that says so" do
    {:ok, gone} = Agent.start(fn -> nil end)
    Agent.stop(gone)
    opts = API.init(token: "test-secret", runner: gone)

    response = request(opts, "run", %{repo: "/fixture", request: "fix"})
    assert response.status == 503
    assert %{"error" => "the service did not answer in time"} = Jason.decode!(response.resp_body)
  end

  test "run returns immediately and case returns queued/running state and durable record", %{
    opts: opts
  } do
    assert request(opts, "run", %{repo: "/fixture", request: "fix"}, "wrong").status == 401

    response =
      request(opts, "run", %{
        repo: "/fixture",
        request: "fix",
        files: ["a.ex"],
        read_rounds: 0,
        reasoning_budget_tokens: 1024,
        design: ["Keep the API"],
        check: "mix test"
      })

    assert response.status == 202
    assert %{"case" => id} = Jason.decode!(response.resp_body)
    assert_receive {:started, task, worker, ^id}
    assert task.files == ["a.ex"]
    assert task.read_rounds == 0
    assert task.reasoning_budget_tokens == 1024
    assert task.design == ["Keep the API"]
    state = request(opts, "case", %{case: id})
    assert state.status == 200

    assert %{"status" => "running", "report" => nil, "record" => %{"id" => ^id}} =
             Jason.decode!(state.resp_body)

    :ok = CaseRecord.event(id, :reply, %{content: <<255>>})
    # /case keeps binary spills as pointers, so malformed model bytes remain JSON safe.
    assert request(opts, "case", %{case: id}).status == 200
    send(worker, :finish)
    Process.monitor(worker)
    assert_receive {:DOWN, _, :process, ^worker, _}

    assert %{"report" => %{"status" => "fixed"}} =
             request(opts, "case", %{case: id}).resp_body |> Jason.decode!()

    assert request(opts, "case", %{case: "unknown"}).status == 404
  end

  test "invalid read budgets are rejected before opening a case", %{opts: opts} do
    for invalid <- [-1, 7, true, false, nil, "0", 0.5] do
      assert request(opts, "run", %{repo: "/fixture", request: "fix", read_rounds: invalid}).status ==
               400
    end

    refute_received {:started, _, _, _}
  end

  test "invalid reasoning budgets are rejected before opening a case", %{opts: opts} do
    for invalid <- [-1, true, false, nil, "1024", 1.5, 1_000_000] do
      assert request(opts, "run", %{
               repo: "/fixture",
               request: "fix",
               reasoning_budget_tokens: invalid
             }).status == 400
    end

    refute_received {:started, _, _, _}
  end

  test "bad tasks are rejected before creating cases", %{opts: opts} do
    for task <- [
          %{repo: "/fixture", request: ""},
          %{repo: "/fixture", request: "fix", files: [3]},
          %{repo: "/fixture", request: "fix", design: 3},
          %{repo: "/fixture", request: "fix", check: []}
        ] do
      assert request(opts, "run", task).status == 400
    end

    assert request(opts, "case", %{case: 3}).status == 400
    refute_received {:started, _, _, _}
  end
end
