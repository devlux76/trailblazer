defmodule Trailblazer.Loop.Request do
  @moduledoc "Normalizes a task's options into the map the loop works from."

  alias Trailblazer.{Config, Model}

  @tool_rounds 6

  @doc false
  def normalize(task) do
    get = fn key -> task[key] || task[to_string(key)] end
    read_rounds = Map.get(task, :read_rounds, Map.get(task, "read_rounds", @tool_rounds))

    reasoning_budget =
      Map.get(task, :reasoning_budget_tokens, Map.get(task, "reasoning_budget_tokens"))

    replay = Map.get(task, :replay_reply_from, Map.get(task, "replay_reply_from"))

    unless is_nil(replay) or
             (is_binary(replay) and
                Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9:._-]{0,127}\z/, replay)),
           do: raise(ArgumentError, "invalid replay_reply_from")

    unless is_integer(read_rounds) and read_rounds in 0..@tool_rounds,
      do: raise(ArgumentError, "read_rounds must be an integer from 0 to #{@tool_rounds}")

    unless is_nil(reasoning_budget) or Model.valid_reasoning_budget?(reasoning_budget),
      do: raise(ArgumentError, "invalid reasoning_budget_tokens")

    # Similar past changes in the coder prompt: the task's own say, else config.
    examples =
      case Map.get(task, :examples, Map.get(task, "examples")) do
        nil -> Config.get(:history_examples) == true
        value when is_boolean(value) -> value
        _ -> raise(ArgumentError, "examples must be true or false")
      end

    edit_mode =
      case Map.get(task, :edit_mode, Map.get(task, "edit_mode")) || Config.get(:code_edit_mode) do
        mode when mode in [:tool, "tool"] -> :tool
        mode when mode in [:text, "text"] -> :text
        _ -> raise(ArgumentError, "edit_mode must be tool or text")
      end

    %{
      repo: get.(:repo),
      request: get.(:request),
      files: get.(:files) || [],
      design: get.(:design),
      check: get.(:check),
      primary: get.(:primary),
      # Atom-only internal metadata; JSON request fields cannot grant commands.
      artifacts: Map.get(task, :artifacts),
      compilation: Map.get(task, :compilation),
      read_rounds: read_rounds,
      reasoning_budget_tokens: reasoning_budget,
      edit_mode: edit_mode,
      replay_reply_from: replay,
      examples: examples,
      from: get.(:from) || "cli"
    }
  end
end
