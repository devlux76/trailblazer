defmodule Trailblazer.Vortex.Bridge.Outbox do
  @moduledoc """
  The durable outbox: sends queued messages to their peers, records receipts, and
  replies to a refused task.
  """

  alias Trailblazer.Vortex.{Protocol, Store}
  alias Trailblazer.Vortex.Bridge

  # A message that awaits an application receipt stays in the durable outbox
  # until the receipt arrives, but it is transmitted once per run: resending it
  # on every later flush (each anomaly, each closed case) flooded the frontier
  # with its whole backlog (2026-10-23). A restart's restore sends it again once.
  @doc false
  def transmitted(state), do: Map.get(state, :transmitted, MapSet.new())

  # Everything awaiting a receipt when older code ran was already sent, many
  # times over (see the handle_call/handle_info guards).
  @doc false
  def seed_transmitted(state) do
    Map.put(
      state,
      :transmitted,
      for(m <- Store.outbox(), m.receipt, into: MapSet.new(), do: m.id)
    )
  end

  @doc false
  def flush(state, excluded \\ [], only_peer \\ nil) do
    sent = transmitted(state)

    Store.outbox()
    |> Enum.reject(&(&1.id in excluded or (only_peer != nil and &1.peer != only_peer)))
    |> Enum.reject(&(&1.receipt and MapSet.member?(sent, &1.id)))
    |> Enum.group_by(& &1.peer)
    |> Enum.reduce(state, fn {peer, messages}, state ->
      case state.peers[peer] do
        %{room: room} when not is_map_key(state.senders, peer) ->
          messages = Enum.filter(messages, &(&1.room == room))

          if messages == [] do
            state
          else
            state =
              Bridge.job(
                state,
                {:send, peer, Enum.uniq(excluded ++ Enum.map(messages, & &1.id))},
                fn ->
                  ok =
                    Enum.filter(messages, fn message ->
                      match?(
                        {:ok, _},
                        Bridge.call(state, "send", %{"room" => room, "text" => message.body})
                      )
                    end)

                  %{
                    receipted: Enum.reject(ok, & &1.receipt),
                    transmitted: for(m <- ok, m.receipt, do: m.id)
                  }
                end
              )

            %{state | senders: Map.put(state.senders, peer, true)}
          end

        _ ->
          state
      end
    end)
  end

  # A refused task's reply to its authorized peer (see receive_message/4 for "task").
  @doc false
  def reject(state, %{room: room}, request_id, reason) when is_binary(request_id) do
    id = "rejected:" <> Base.encode16(:crypto.hash(:sha256, request_id), case: :lower)
    payload = %{"reason" => if(is_atom(reason), do: Atom.to_string(reason), else: "refused")}

    with {:ok, body} <- Protocol.encode(Protocol.envelope("rejected", id, request_id, payload)) do
      Task.start(fn -> Bridge.call(state, "send", %{"room" => room, "text" => body}) end)
    end

    :ok
  end

  def reject(_, _, _, _), do: :ok
end
