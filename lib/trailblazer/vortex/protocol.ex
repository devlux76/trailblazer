defmodule Trailblazer.Vortex.Protocol do
  @moduledoc "Versioned task messages; authority is local policy, never body-supplied identity."
  alias Trailblazer.Files
  alias Trailblazer.Loop.{Artifacts, CompiledCheckpoint, Workspace}
  @types ~w(task accepted report escalation receipt claim returned_fix rejected cancel)
  @keys ~w(protocol type id request_id payload)

  def decode(text) when is_binary(text) and byte_size(text) <= 16_384 do
    text =
      case String.split(text, "\n", parts: 2) do
        [header, body] ->
          if Regex.match?(
               ~r/\AFrom [A-Za-z][A-Za-z0-9 _-]{0,40}, not typed by the operator:\z/,
               header
             ), do: body, else: text

        _ ->
          text
      end

    with {:ok, %{} = message} <- Jason.decode(text),
         true <- Map.keys(message) |> Enum.all?(&(&1 in @keys)),
         true <- message["protocol"] == "trailblazer/1" and message["type"] in @types,
         true <- id?(message["id"]) and id?(message["request_id"]),
         true <- is_map(message["payload"]),
         true <- payload?(message["type"], message["payload"]) do
      {:ok, message}
    else
      _ -> {:error, :bad_envelope}
    end
  end

  def decode(_), do: {:error, :bad_envelope}

  def encode(message, sender \\ "Trailblazer") do
    body = "From #{sender}, not typed by the operator:\n" <> Jason.encode!(message)
    if byte_size(body) <= 16_384, do: {:ok, body}, else: {:error, :too_large}
  end

  def envelope(type, id, request_id, payload),
    do: %{
      "protocol" => "trailblazer/1",
      "type" => type,
      "id" => id,
      "request_id" => request_id,
      "payload" => payload
    }

  def peer(%{peer: peer, room: room}, peers) do
    case peers[peer] do
      %{room: ^room} = policy -> {:ok, policy}
      _ -> {:error, :unauthorized_peer}
    end
  end

  def peer(_, _), do: {:error, :unauthorized_peer}

  def task(%{"type" => "task", "payload" => payload}, %{role: role, repos: repos} = policy, peer)
      when role in [:caller, :collaborator] do
    with true <-
           Enum.all?(
             Map.keys(payload),
             &(&1 in ~w(repo request check files design planner read_rounds reasoning_budget_tokens replay_reply_from))
           ),
         repo when is_binary(repo) <- payload["repo"],
         {:ok, repo} <- Files.canonical_path(repo),
         checks when is_list(checks) <- repos[repo],
         check when is_binary(check) <- payload["check"],
         true <- check in checks,
         request when is_binary(request) and byte_size(request) > 0 <- payload["request"],
         files <- Map.get(payload, "files", []),
         true <- is_list(files) and Enum.all?(files, &relative?/1),
         design <- Map.get(payload, "design", []),
         true <- is_list(design) and Enum.all?(design, &is_binary/1),
         read_rounds <- Map.get(payload, "read_rounds", 6),
         true <- is_integer(read_rounds) and read_rounds in 0..6,
         true <-
           not Map.has_key?(payload, "reasoning_budget_tokens") or
             Trailblazer.Model.valid_reasoning_budget?(payload["reasoning_budget_tokens"]),
         true <-
           not Map.has_key?(payload, "replay_reply_from") or id?(payload["replay_reply_from"]),
         false <- Workspace.own_repo?(repo),
         {:ok, planner} <- planner(payload["planner"], repo) do
      task = %{
        repo: repo,
        request: request,
        check: check,
        files: files,
        design: design,
        from: "vortex:#{peer}"
      }

      task =
        if Map.has_key?(payload, "read_rounds"),
          do: Map.put(task, :read_rounds, read_rounds),
          else: task

      task =
        if Map.has_key?(payload, "reasoning_budget_tokens"),
          do: Map.put(task, :reasoning_budget_tokens, payload["reasoning_budget_tokens"]),
          else: task

      task =
        if Map.has_key?(payload, "replay_reply_from"),
          do: Map.put(task, :replay_reply_from, payload["replay_reply_from"]),
          else: task

      task =
        case Artifacts.select(Map.get(policy, :artifacts, %{}), repo, check) do
          nil -> task
          frozen -> Map.put(task, :artifacts, frozen)
        end

      task =
        case CompiledCheckpoint.select(Map.get(policy, :compilation, %{}), repo, check) do
          nil -> task
          command -> Map.put(task, :compilation, command)
        end

      {:ok, if(planner, do: Map.put(task, :planner, planner), else: task)}
    else
      _ -> {:error, :unauthorized_task}
    end
  end

  def task(_, _, _), do: {:error, :unauthorized_task}

  # Optional planner card (trailblazer:9fa7ba4): a card of the same admitted
  # repository, never a shared one, and an optional deadline. Nothing in it can
  # name an executable or a state path.
  defp planner(nil, _repo), do: {:ok, nil}

  defp planner(%{"ref" => ref} = planner, repo) when is_binary(ref) do
    seconds = Map.get(planner, "deadline_seconds")

    with true <- Enum.all?(Map.keys(planner), &(&1 in ~w(ref deadline_seconds))),
         [_, name] <- Regex.run(~r/\A([a-z0-9][a-z0-9_.-]*):[0-9a-f]{7,64}\z/, ref),
         true <- name != "shared" and name == repo_name(repo),
         true <- seconds == nil or (is_integer(seconds) and seconds > 0) do
      {:ok, %{ref: ref, deadline_ms: seconds && seconds * 1000}}
    else
      _ -> {:error, :bad_planner}
    end
  end

  defp planner(_, _), do: {:error, :bad_planner}

  # A card names its repository by the main checkout. A linked worktree shares that
  # repository's common git dir, so its name comes from there, not from its own
  # directory (trailblazer:c8813a0): vortex/.claude/worktrees/v6-impl is "vortex".
  # Outside a git repository the directory name stands, as before.
  @doc false
  def repo_name(repo) do
    case System.cmd(
           "git",
           ["-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"],
           stderr_to_stdout: true
         ) do
      {common, 0} ->
        common = String.trim(common)

        if Path.basename(common) == ".git",
          do: common |> Path.dirname() |> Path.basename(),
          else: common |> Path.basename() |> Path.rootname(".git")

      _ ->
        Path.basename(repo)
    end
  end

  defp payload?("receipt", payload),
    do: Map.keys(payload) == ["message_id"] and id?(payload["message_id"])

  defp payload?(type, payload) when type in ~w(claim cancel),
    do: Map.keys(payload) == ["case"] and id?(payload["case"])

  defp payload?("returned_fix", payload) do
    Enum.sort(Map.keys(payload)) == ~w(base case commit) and id?(payload["case"]) and
      Enum.all?(~w(base commit), fn key ->
        is_binary(payload[key]) and Regex.match?(~r/\A[0-9a-f]{40}\z/, payload[key])
      end)
  end

  defp payload?(_, _), do: true

  defp id?(id), do: is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9:._-]{0,127}\z/, id)

  defp relative?(p),
    do:
      is_binary(p) and Path.type(p) == :relative and ".." not in Path.split(p) and
        not String.contains?(p, "\0")
end
