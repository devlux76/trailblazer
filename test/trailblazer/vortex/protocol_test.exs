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

  test "a planner card targets a linked worktree under its repository's name (c8813a0)" do
    tmp = Path.join(System.tmp_dir!(), "tb-wt-#{System.unique_integer([:positive])}")
    main = Path.join(tmp, "vortex")
    linked = Path.join(tmp, "v6-impl")
    foreign = Path.join(tmp, "elsewhere")

    try do
      for dir <- [main, foreign] do
        File.mkdir_p!(dir)
        {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)

        {_, 0} =
          System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@e", "commit", "-q", "--allow-empty", "-m", "base"],
            cd: dir
          )
      end

      {_, 0} = System.cmd("git", ["worktree", "add", "-q", "-b", "side", linked], cd: main)
      assert Protocol.repo_name(main) == "vortex"
      assert Protocol.repo_name(linked) == "vortex"
      assert Protocol.repo_name(foreign) == "elsewhere"

      {:ok, canonical} = Trailblazer.Files.canonical_path(linked)
      policy = %{room: "room", role: :caller, repos: %{canonical => ["bun test"]}}
      planned = fn ref -> %{@envelope | "payload" => %{@task | "repo" => linked} |> Map.put("planner", %{"ref" => ref})} end

      assert {:ok, task} = Protocol.task(planned.("vortex:abcdef1"), policy, "caller")
      assert task.planner.ref == "vortex:abcdef1"
      assert {:error, :unauthorized_task} = Protocol.task(planned.("v6-impl:abcdef1"), policy, "caller")
      assert {:error, :unauthorized_task} = Protocol.task(planned.("elsewhere:abcdef1"), policy, "caller")
    after
      File.rm_rf!(tmp)
    end
  end

  test "outbound encoding preserves attribution and the wire cap" do
    assert {:ok, body} = Protocol.encode(@envelope)
    assert String.starts_with?(body, "From Trailblazer, not typed by the operator:\n")
    assert {:ok, @envelope} = Protocol.decode(body)

    assert {:error, :too_large} =
             Protocol.encode(Map.put(@envelope, "payload", String.duplicate("x", 17_000)))
  end

  test "an explicit replay source is preserved and must be a case identifier" do
    message = %{@envelope | "payload" => Map.put(@task, "replay_reply_from", "fixture-case")}
    assert {:ok, task} = Protocol.task(message, @policy, "caller")
    assert task.replay_reply_from == "fixture-case"
    message = %{@envelope | "payload" => Map.put(@task, "replay_reply_from", "../file")}
    assert {:error, _} = Protocol.task(message, @policy, "caller")
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
  test "artifact selection is internal; peer and model cannot override it" do
    body = %{"prepare" => "cp source bundle", "paths" => ["bundle"], "definitions" => []}

    {:ok, artifacts} =
      Trailblazer.Loop.Artifacts.policies(%{"/tmp" => %{"bun test" => body}}, @policy.repos)

    policy = Map.put(@policy, :artifacts, artifacts)
    assert {:ok, task} = Protocol.task(@envelope, policy, "caller")
    assert task.artifacts == artifacts["/tmp"]["bun test"]
    assert {:ok, plain} = Protocol.task(@envelope, @policy, "caller")
    refute Map.has_key?(plain, :artifacts)

    for key <- ["artifacts", "prepare"] do
      forged = %{@envelope | "payload" => Map.put(@task, key, body)}
      assert {:error, :unauthorized_task} = Protocol.task(forged, policy, "caller")
    end
  end

  test "permission decisions have strict bound data, never body-supplied identity or commands" do
    id = "perm-" <> String.duplicate("a", 32)

    payload = %{
      "request_id" => id,
      "nonce" => String.duplicate("b", 32),
      "binding" => String.duplicate("c", 64),
      "evidence_sha256" => String.duplicate("d", 64),
      "base" => String.duplicate("e", 40),
      "policy_hash" => String.duplicate("f", 64),
      "source_hash" => String.duplicate("1", 64),
      "exception_hash" => String.duplicate("2", 64),
      "outcome" => "grant",
      "reason" => "Only the recorded directory metadata changes.",
      "exception_ids" => ["dir-mode"],
      "commit_paths" => ["dist/bundle.js"],
      "normalizations" => []
    }

    message = Protocol.envelope("permission_decision", "decision-1", id, payload)
    assert {:ok, ^message} = Protocol.decode(Jason.encode!(message))

    for patch <- [
          %{"from" => "operator"},
          %{"peer" => "frontier"},
          %{"tier" => "local"},
          %{"command" => "execute"},
          %{"outcome" => "allow_everything"},
          %{"nonce" => "bad"},
          %{"request_id" => "different-request"},
          %{"commit_paths" => ["../outside"]},
          %{"commit_paths" => [".git/config"]},
          %{"normalizations" => "execute"},
          %{"reason" => ""}
        ] do
      changed = %{message | "payload" => Map.merge(payload, patch)}
      assert {:error, :bad_envelope} = Protocol.decode(Jason.encode!(changed))
    end

    for field <- Map.keys(payload) do
      changed = %{message | "payload" => Map.delete(payload, field)}
      assert {:error, :bad_envelope} = Protocol.decode(Jason.encode!(changed))
    end

    for outcome <- ~w(refuse escalate amend_policy) do
      changed = %{message | "payload" => %{payload | "outcome" => outcome}}
      assert {:ok, ^changed} = Protocol.decode(Jason.encode!(changed))
    end
  end
end
