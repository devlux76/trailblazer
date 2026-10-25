defmodule Trailblazer.Load do
  @moduledoc """
  The machine's load at a moment, as evidence for an anomaly (J8): load
  average, available memory and swap in use from `/proc`, and what the model
  and the embedder were last reported doing. It follows the `:model` and
  `:embedder` topics, keeping only each one's last event; nothing is sampled
  on a timer.
  """
  use GenServer

  alias Trailblazer.Events

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "A snapshot; the `/proc` parts are left out where they cannot be read."
  @spec snapshot() :: map()
  def snapshot do
    seen =
      case Process.whereis(__MODULE__) do
        nil -> %{}
        _pid -> GenServer.call(__MODULE__, :seen, :infinity)
      end

    Map.merge(proc(), %{model: seen[:model] || :unknown, embedder: seen[:embedder] || :unknown})
  end

  @impl true
  def init(_opts) do
    :ok = Events.subscribe(:model)
    :ok = Events.subscribe(:embedder)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:seen, _from, seen), do: {:reply, seen, seen}

  @impl true
  def handle_info({:trailblazer_event, topic, event}, seen),
    do: {:noreply, Map.put(seen, topic, event)}

  defp proc do
    loadavg =
      case File.read("/proc/loadavg") do
        {:ok, text} -> text |> String.split() |> Enum.take(3) |> Enum.join(" ")
        _ -> nil
      end

    mem =
      case File.read("/proc/meminfo") do
        {:ok, text} ->
          for line <- String.split(text, "\n"),
              [key, kb | _] <- [String.split(line, [":", " "], trim: true)],
              into: %{},
              do: {key, String.to_integer(kb)}

        _ ->
          %{}
      end

    mb = fn key -> if kb = mem[key], do: div(kb, 1024) end

    swap_used =
      if mem["SwapTotal"] && mem["SwapFree"], do: div(mem["SwapTotal"] - mem["SwapFree"], 1024)

    %{loadavg: loadavg, mem_available_mb: mb.("MemAvailable"), swap_used_mb: swap_used}
  end
end
