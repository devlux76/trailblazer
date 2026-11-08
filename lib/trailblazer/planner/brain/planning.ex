defmodule Trailblazer.Planner.Brain.Planning do
  @moduledoc "One planning attempt of the brain: lease recovery, the model decision, the currency check and the dispatch."

  require Logger
  alias Trailblazer.Planner.{Brain, Journal, Route}
  alias Trailblazer.Planner.Brain.Drain

  # Terminal for a snapshot: never inferred again automatically. Only
  # `unavailable` invites a retry, on a later real event.
  @terminal ~w(wait error interrupted dispatched stale assign_failed)

  # A lease left by an interrupted cycle: release it, then dispatch the
  # retained decision only if the board still reads the same. No model call.
  @doc false
  def recover([], state), do: state

  def recover([row | rest], state) do
    case state.release_fun.(row.lease) do
      :ok ->
        state =
          if is_binary(row.ref) and row.ref != "" do
            resume(%{fp: row.fingerprint, ref: row.ref, reason: row.reason}, state)
          else
            Journal.record(row.fingerprint, "", "interrupted", row.ref, row.reason)
            state
          end

        recover(rest, state)

      {:error, :release_unconfirmed} ->
        outcome = if row.ref in [nil, ""], do: :interrupted, else: :decided
        Drain.arm_drain(row.fingerprint, row.lease, outcome, row.ref, row.reason, state)

      {:error, reason} ->
        Logger.warning("trailblazer: planner lease recovery failed: #{inspect(reason)}")
        Drain.fence(%{state | last_error: "lease recovery failed: #{inspect(reason)}"})
    end
  end

  @doc false
  def attempt(fp, cards, state) do
    case Journal.get(fp) do
      %{lease: "", state: row_state} when row_state in @terminal ->
        :ok

      %{lease: lease} when lease != "" ->
        settle_row(fp, lease, %{fingerprint: fp, cards: cards}, state)

      _ ->
        infer(fp, cards, state)
    end
  end

  # A left-over lease from an interrupted cycle: release it first, then the
  # retained decision dispatches only if the board still reads the same. No
  # model call.
  defp settle_row(fp, lease, snapshot, state) do
    row = Journal.get(fp)

    case state.release_fun.(lease) do
      :ok ->
        if is_binary(row.ref) and row.ref != "" do
          retain(fp, row.ref, nil, row.reason, snapshot, state)
        else
          Journal.record(fp, "", "interrupted", row.ref, row.reason)
        end

      {:error, :release_unconfirmed} ->
        outcome = if row.ref in [nil, ""], do: :interrupted, else: :decided
        send(state.pid, {:drain, fp, lease, outcome, row.ref, row.reason})

      {:error, reason} ->
        send(state.pid, {:fence, "release failed: #{inspect(reason)}"})
    end
  end

  # The only place the model is called. The lease intent is durable BEFORE
  # the acquire — a crash between the two leaves the row a restart must
  # settle — and the lease is unique per attempt, never a reused constant.
  defp infer(fp, cards, state) do
    lease = "planner-brain-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    Journal.record(fp, lease, "intent", nil, "planning")

    case state.acquire_fun.(lease) do
      :blocked ->
        Journal.record(fp, "", "unavailable", nil, "the local model resource is busy")

      {:ok, held} ->
        unless held == lease, do: Journal.record(fp, held, "intent", nil, "planning")

        case state.choose_fun.(cards) do
          {:ok, :wait} ->
            conclude(fp, held, "wait", nil, nil, "waited", state)

          {:ok, %{ref: ref, reason: reason} = choice} ->
            Journal.record(fp, held, "intent", ref, reason)
            conclude(fp, held, :decided, ref, Map.get(choice, :target), reason, state)

          {:error, reason} ->
            conclude(fp, held, "error", nil, nil, format(reason), state)
        end
    end
  end

  # Releases the lease, then journals the outcome — or, for a decision,
  # verifies currency against a fresh board read and dispatches.
  defp conclude(fp, lease, outcome, ref, target, reason, state) do
    case state.release_fun.(lease) do
      :ok ->
        if outcome == :decided do
          retain(fp, ref, target, reason, snapshot_now(state), state)
        else
          Journal.record(fp, "", outcome, ref, reason)
        end

      {:error, :release_unconfirmed} ->
        send(state.pid, {:drain, fp, lease, outcome, ref, reason})

      {:error, other} ->
        send(state.pid, {:fence, "release failed: #{inspect(other)}"})
    end
  end

  # A fresh read for a decision's currency check: a model call takes minutes,
  # so the cycle's own snapshot is too old to dispatch from.
  defp snapshot_now(state) do
    case state.board_fun.(state.config) do
      {:ok, snapshot} -> snapshot
      _ -> nil
    end
  end

  # A decision dispatches only when the fresh board reads exactly as it did
  # when the decision was made: the same fingerprint and the same ref. An
  # edited context or check is a different board, however similar the ref.
  # The card's own routing check decides the destination: a `dispatch:research`
  # or markerless card never reaches the coder, a checked card never carries
  # the model's research choice, and only a tie is decided by the model's
  # target. Trailblazer dispatch never waits for research; Research holds
  # its own errors.
  defp retain(fp, ref, target, reason, fresh, state) do
    card = fresh && Enum.find(fresh[:cards] || [], &(&1.ref == ref))

    cond do
      fresh == nil ->
        Journal.record(fp, "", "interrupted", ref, reason)

      fresh[:fingerprint] == fp and card != nil ->
        route = retention_route(Route.classify(card.context), target)

        cond do
          route == :trailblazer and target == "research" ->
            Journal.record(
              fp,
              "",
              "error",
              ref,
              "model target research contradicts the checked card"
            )

          route == :research ->
            research_dispatch(fp, ref, card, reason, state)

          not Brain.worker_busy?(state) ->
            case state.assign_fun.(state.config, card) do
              :ok -> Journal.record(fp, "", "dispatched", ref, reason)
              {:error, why} -> Journal.record(fp, "", "assign_failed", ref, format(why))
            end

          true ->
            Journal.record(fp, "", "stale", ref, reason)
        end

      true ->
        Journal.record(fp, "", "stale", ref, reason)
    end
  end

  # A tie decidable only by the model's target: a "research" pick makes its
  # route research; every other pick keeps the checked route.
  defp retention_route(:tie, "research"), do: :research
  defp retention_route(route, _target), do: route

  # OpenCode runs one research job at a time: a busy reply is retried by a
  # later event, any other failure holds the card in Research.
  defp research_dispatch(fp, ref, card, reason, state) do
    case state.research_fun do
      nil ->
        Journal.record(fp, "", "assign_failed", ref, "research is not configured")

      fun ->
        case fun.(card) do
          :ok -> Journal.record(fp, "", "dispatched", ref, reason)
          {:error, :busy} -> Journal.record(fp, "", "unavailable", ref, "research is busy")
          {:error, other} -> Journal.record(fp, "", "assign_failed", ref, format(other))
        end
    end
  end

  # A retained decision from a previous run resumes in its own task.
  @doc false
  def resume(pending, state) do
    Brain.start_cycle(state, fn ->
      retain(pending.fp, pending.ref, nil, pending.reason, snapshot_now(state), state)
      :ok
    end)
  end

  defp format(term) when is_binary(term), do: String.slice(term, 0, 900)
  defp format(term), do: String.slice(inspect(term), 0, 900)
end
