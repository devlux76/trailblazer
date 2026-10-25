defmodule Trailblazer.Events do
  @moduledoc """
  Local publish/subscribe (design §13.3): facts that have happened, sent to
  whoever subscribed to their topic, so work moves on events and not clocks.

  Topics: `{:repo, path}`, `{:case, id}`, `:model`, `:embedder`, `:anomaly`.
  A subscriber receives `{:trailblazer_event, topic, event}`. Publishing never
  waits for a subscriber; events from one publisher arrive in the order it
  sent them (J1), and a subscriber that dies is dropped by the registry
  without the publisher noticing (J3).
  """

  @registry __MODULE__

  def child_spec(_opts),
    do: Registry.child_spec(keys: :duplicate, name: @registry, partitions: 1)

  @spec subscribe(term()) :: :ok
  def subscribe(topic) do
    {:ok, _} = Registry.register(@registry, topic, nil)
    :ok
  end

  @spec unsubscribe(term()) :: :ok
  def unsubscribe(topic), do: Registry.unregister(@registry, topic)

  @spec publish(term(), term()) :: :ok
  def publish(topic, event) do
    Registry.dispatch(@registry, topic, fn subscribers ->
      for {pid, _} <- subscribers, do: send(pid, {:trailblazer_event, topic, event})
    end)
  end
end
