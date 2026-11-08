defmodule Trailblazer.Vortex.Bridge.Inbound do
  @moduledoc """
  Reads one VORTEX page into the bridge: each event becomes a conference reply, a
  task, a cancel, a receipt, or a claim, and is classified when it cannot be used.
  """

  require Logger
  alias Trailblazer.Events
  alias Trailblazer.Loop.CaseRecord
  alias Trailblazer.Vortex.{Protocol, Store}
  alias Trailblazer.Vortex.Bridge.Outbox

  # Conference messages are the research route's reply channel (trailblazer:4cc63df):
  # they lift unaltered to the planner, and an authorized peer's message also says
  # it recovered, which wakes a held card's retry. They are not protocol intake.
  @doc false
  def process_event(
        %{"kind" => "conference_message", "room" => "conference:" <> id} = raw,
        state
      ) do
    peer = value(raw, "peer")

    Events.publish(:planner, {
      :research_conference,
      %{
        "conference" => id,
        "peer" => peer,
        "body" => value(raw, "body"),
        "cursor" => value(raw, "cursor")
      }
    })

    if Map.has_key?(state.peers, peer),
      do: Events.publish(:planner, {:research_recovered, peer})
  end

  def process_event(raw, state) do
    event = %{peer: value(raw, "peer"), room: value(raw, "room")}

    with "message" <- value(raw, "kind"),
         {:ok, policy} <- Protocol.peer(event, state.peers),
         {:ok, message} <- Protocol.decode(value(raw, "body")) do
      result = receive_message(event, policy, message, state)

      case result do
        :ok ->
          :ok

        {:error, reason} ->
          Store.classify(event.peer, value(raw, "cursor"), reason)
          Logger.warning("trailblazer: VORTEX event refused: #{inspect(reason)}")
      end
    else
      _ -> Store.classify(event.peer, value(raw, "cursor"), :ignored)
    end
  end

  defp receive_message(event, policy, %{"type" => "task"} = message, state) do
    result =
      with {:ok, task} <- Protocol.task(message, policy, event.peer),
           {planner, task} = Map.pop(task, :planner),
           {:ok, id, fresh} <-
             Store.admit(event.peer, event.room, message["request_id"], task, planner) do
        Events.subscribe({:case, id})
        if planner && fresh == :new, do: Events.publish(:planner, {:assigned, id})
        :ok
      end

    # Only a decoded task from an already-authorized peer reaches here: tell that
    # peer it was refused, so its client records a definite refusal instead of an
    # uncertain timeout (trailblazer:c8813a0). Only the reason name travels. No case
    # exists, so the reply is not durable: if it is lost the client times out, as
    # before. Its id derives from the request, so a redelivery repeats the same reply.
    with {:error, reason} <- result,
         do: Outbox.reject(state, policy, message["request_id"], reason)

    result
  end

  defp receive_message(
         event,
         %{role: role},
         %{"type" => "cancel", "payload" => %{"case" => id}} = message,
         _
       )
       when role in [:caller, :collaborator] do
    request_id = message["request_id"]

    case Store.get(id) do
      %{peer: peer, request_id: request, state: "waiting_resource"}
      when peer == event.peer and request == request_id ->
        CaseRecord.close(id, %{
          case: id,
          status: :cancelled,
          summary: "Cancelled by the caller before execution."
        })

      _ ->
        {:error, :cannot_cancel}
    end
  end

  defp receive_message(event, _, %{"type" => "receipt", "payload" => payload}, _),
    do: Store.receipt(event.peer, payload["message_id"])

  defp receive_message(event, %{role: role}, %{"type" => type, "payload" => payload} = message, _)
       when type in ~w(claim returned_fix) and role in [:frontier, :collaborator] do
    id = payload["case"]
    request = if is_binary(id), do: Store.get(id)

    with %{request_id: request_id} <- request,
         true <- request_id == message["request_id"],
         :ok <-
           if(type == "claim",
             do: Store.claim(event.peer, id),
             else: Store.returned_fix(event.peer, id, payload)
           ) do
      Store.acknowledgment(id, event.peer, event.room, request_id, message["id"])
    else
      _ -> {:error, :not_assigned}
    end
  end

  defp receive_message(_, _, _, _), do: {:error, :unexpected_message}

  @doc false
  def value(map, key) do
    fields = %{
      "peer" => :peer,
      "room" => :room,
      "events" => :events,
      "cursor" => :cursor,
      "kind" => :kind,
      "body" => :body
    }

    case map do
      %{^key => value} -> value
      _ -> Map.get(map, fields[key])
    end
  end
end
