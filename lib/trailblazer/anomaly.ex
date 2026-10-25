defmodule Trailblazer.Anomaly do
  @moduledoc """
  Something took longer than it should, or stopped making progress (design
  §13.5). Taking longer is not by itself a fault; often it is the machine's
  load, which is why every anomaly carries it (J8).

  A report is recorded in `cases.db`, published on `:anomaly`, and, the first
  time for its kind and subject, sent to Claude and Codex as an investigation
  request (`Trailblazer.Investigate`). A repeat while it is open only counts
  (J6); once acknowledged, the next one is new. Requests that could not be
  sent are tried again on the next report (J9), never on a timer.
  """
  require Logger

  alias Trailblazer.{CaseStore, Events, Investigate, Load}

  @spec report(atom() | String.t(), term(), map()) :: {:ok, integer()}
  def report(kind, subject, evidence) do
    {kind, subject} = {to_string(kind), subject(subject)}
    load = Load.snapshot()
    at = System.os_time(:millisecond)

    result =
      CaseStore.anomaly_report(kind, subject, encode(evidence), encode(load), at)

    {id, count} =
      case result do
        {:new, id} -> {id, 1}
        {:repeat, id, count} -> {id, count}
      end

    anomaly = %{
      id: id,
      kind: kind,
      subject: subject,
      evidence: evidence,
      load: load,
      at: at,
      count: count
    }

    Logger.warning(
      "trailblazer: anomaly #{id} #{kind} #{subject} (#{count}x): #{inspect(evidence, limit: 10)} load #{inspect(load)}"
    )

    :ok = Events.publish(:anomaly, anomaly)
    resend_unsent(id)
    if count == 1, do: Investigate.request(anomaly)
    {:ok, id}
  end

  @doc "Anomalies, newest first, with evidence and load decoded."
  def list(opts \\ []) do
    opts |> Keyword.get(:open, false) |> CaseStore.anomaly_list() |> Enum.map(&decode/1)
  end

  def ack(id), do: CaseStore.anomaly_ack(id, System.os_time(:millisecond))

  # J9: a request that could not be sent goes again when the next anomaly
  # comes, the one event that says we are trying to reach VORTEX anyway
  defp resend_unsent(except) do
    for a <- list(open: true), a.sent == 0, a.id != except, do: Investigate.request(a)
    :ok
  end

  defp subject(s) when is_binary(s), do: s
  defp subject(s), do: inspect(s)

  # evidence is whatever the caller had at hand: tuples, pids and refs become
  # their inspected text, so recording an anomaly never fails on its evidence
  defp encode(term), do: term |> jsonable() |> Jason.encode!()

  defp jsonable(m) when is_map(m) and not is_struct(m),
    do: Map.new(m, fn {k, v} -> {jsonable_key(k), jsonable(v)} end)

  defp jsonable(l) when is_list(l), do: Enum.map(l, &jsonable/1)
  defp jsonable(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&jsonable/1)
  defp jsonable(x) when is_binary(x), do: if(String.valid?(x), do: x, else: inspect(x))

  defp jsonable(x) when is_number(x) or is_boolean(x) or is_nil(x) or is_atom(x), do: x
  defp jsonable(x), do: inspect(x)

  defp jsonable_key(k) when is_binary(k) or is_atom(k), do: k
  defp jsonable_key(k), do: inspect(k)

  defp decode(row) do
    %{
      row
      | evidence: Jason.decode!(row.evidence),
        load: Jason.decode!(row.load)
    }
  end
end
