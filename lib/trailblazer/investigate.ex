defmodule Trailblazer.Investigate do
  @moduledoc """
  Sends an anomaly to the locally configured frontier collaborator over VORTEX
  without a local model (design §13.5). Availability is local policy; an offline
  collaborator is not selected merely because its identity is known.

  Production uses `:vortex_bridge`: the model-free bridge subscribes to anomaly
  events, restores unsent records and queues a durable escalation. Only an
  application receipt marks delivery. `{:fun, f}` and `:none` are test seams;
  `:unavailable` leaves the anomaly unsent.

  Sending runs in a process of its own, so a slow or absent VORTEX never holds
  up the work (J9). It is not given a backstop of its own: a send that hangs
  holds only itself, and a backstop on it would report an anomaly about
  reporting anomalies. Until it succeeds the anomaly stays unsent and is sent
  again on the next report.
  """
  require Logger

  alias Trailblazer.{CaseStore, Config}

  @spec request(map()) :: :ok
  def request(anomaly) do
    {:ok, _pid} = Task.start(fn -> deliver(anomaly) end)
    :ok
  end

  @doc false
  def deliver(anomaly) do
    case send_text(text(anomaly), Config.get(:investigate_transport)) do
      :ok ->
        CaseStore.anomaly_mark_sent(anomaly.id)

      :queued ->
        :ok

      {:error, reason} ->
        Logger.error(
          "trailblazer: investigation request for anomaly #{anomaly.id} not sent: #{inspect(reason)}"
        )
    end
  end

  @doc "The request's text."
  def text(a) do
    at = a.at |> DateTime.from_unix!(:millisecond) |> DateTime.to_string()

    """
    From Trailblazer, not typed by the operator: investigation request, anomaly #{a.id}.

    #{a.kind} for #{a.subject}#{if a[:count] && a.count > 1, do: " (#{a.count} times)"}, at #{at}.
    Evidence: #{brief(a.evidence)}
    Load: #{load(a.load)}

    It may just be load. Look at: journalctl --user -u trailblazer --since "#{at}"; trailblazer anomalies.
    When understood: trailblazer ack #{a.id}
    """
  end

  defp brief(evidence),
    do: evidence |> inspect(limit: 20, printable_limit: 600) |> String.slice(0, 1200)

  defp load(load) do
    get = fn key -> load[key] || load[to_string(key)] end

    "load #{get.(:loadavg)}, #{get.(:mem_available_mb)} MB available, " <>
      "#{get.(:swap_used_mb)} MB swap in use, model #{inspect(get.(:model))}, " <>
      "embedder #{inspect(get.(:embedder))}"
  end

  defp send_text(_text, :none), do: :ok

  defp send_text(text, {:fun, f}) when is_function(f, 1), do: f.(text)

  defp send_text(_text, :unavailable), do: {:error, :vortex_not_configured}

  defp send_text(_text, :vortex_bridge) do
    # The anomaly is durable already; the bridge restores unsent records and
    # handles the :anomaly event. Only a receiver receipt marks it sent.
    :queued
  end
end
