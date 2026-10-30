defmodule Trailblazer.Vortex.ProtocolTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Vortex.Protocol

  @task %{"repo" => "/tmp", "request" => "fix greeting", "check" => "bun test"}
  @envelope %{
    "protocol" => "trailblazer/1",
    "type" => "task",
    "id" => "message-1",
    "request_id" => "request-1",
    "payload" => @task
  }
  @policy %{room: "room", role: :caller, repos: %{"/tmp" => ["bun test"]}}

  test "versioned, bounded envelopes reject malformed and unknown fields" do
    assert {:ok, @envelope} = Protocol.decode(Jason.encode!(@envelope))
    assert {:error, _} = Protocol.decode(String.duplicate("x", 16_385))
    assert {:error, _} = Protocol.decode("[]")
    assert {:error, _} = Protocol.decode(Jason.encode!(Map.put(@envelope, "shell", "anything")))
    assert {:error, _} = Protocol.decode(Jason.encode!(%{@envelope | "protocol" => "future"}))
    assert {:error, _} = Protocol.decode(Jason.encode!(%{@envelope | "type" => "unknown"}))
  end

  test "authority comes from configured peer, room, repository and exact check" do
    event = %{peer: "caller", room: "room"}
    assert {:ok, policy} = Protocol.peer(event, %{"caller" => @policy})
    assert {:ok, task} = Protocol.task(@envelope, policy, "caller")
    assert task.from == "vortex:caller"
    assert task.repo == "/tmp"
    assert {:error, _} = Protocol.peer(%{event | peer: "stranger"}, %{"caller" => @policy})
    assert {:error, _} = Protocol.peer(%{event | room: "other"}, %{"caller" => @policy})

    assert {:error, _} =
             Protocol.task(
               %{@envelope | "payload" => %{@task | "check" => "rm -rf /"}},
               policy,
               "caller"
             )

    assert {:error, _} =
             Protocol.task(%{@envelope | "payload" => %{@task | "repo" => "/"}}, policy, "caller")

    assert {:error, _} = Protocol.task(@envelope, %{policy | role: :frontier}, "caller")
  end

  test "outbound encoding preserves attribution and the wire cap" do
    assert {:ok, body} = Protocol.encode(@envelope)
    assert String.starts_with?(body, "From Trailblazer, not typed by the operator:\n")
    assert {:ok, @envelope} = Protocol.decode(body)

    assert {:error, :too_large} =
             Protocol.encode(Map.put(@envelope, "payload", String.duplicate("x", 17_000)))
  end

  test "task admission preserves bounded read rounds and rejects invalid budgets" do
    for rounds <- [0, 1, 6] do
      message = %{@envelope | "payload" => Map.put(@task, "read_rounds", rounds)}
      assert {:ok, task} = Protocol.task(message, @policy, "caller")
      assert task.read_rounds == rounds
    end

    for invalid <- [-1, 7, true, false, nil, "0", 0.5] do
      message = %{@envelope | "payload" => Map.put(@task, "read_rounds", invalid)}
      assert {:error, :unauthorized_task} = Protocol.task(message, @policy, "caller")
    end
  end

  test "task admission preserves a reasoning budget and rejects invalid values" do
    message = %{@envelope | "payload" => Map.put(@task, "reasoning_budget_tokens", 1024)}
    assert {:ok, task} = Protocol.task(message, @policy, "caller")
    assert task.reasoning_budget_tokens == 1024

    for invalid <- [-1, true, false, nil, "1024", 1.5, 1_000_000] do
      message = %{@envelope | "payload" => Map.put(@task, "reasoning_budget_tokens", invalid)}
      assert {:error, :unauthorized_task} = Protocol.task(message, @policy, "caller")
    end
  end
end
