defmodule Trailblazer.Memory do
  @moduledoc """
  The outcomes of finished cases, kept for recall: what was asked, which model
  and edit mode tried it, whether it ended fixed, failed or awaiting review,
  what the review said and the first concrete failure. Each outcome is one
  JSON line in `<state>/memory/outcomes.jsonl` and one vector (the embedder's
  768-wide document vector) in the memory's own collection, so `similar/3`
  finds the past cases closest to a request.

  The memory belongs to the harness, not to a repository (operator,
  2026-11-05): one store and one collection under the state directory, every
  outcome tagged with its repo, recall across all of them, so what any model
  learned anywhere helps the next task everywhere.

  This is recording and retrieval only. Nothing here reaches a coder prompt:
  lessons drawn from outcomes are reviewed before they are ever used, and an
  outcome carries the Trailblazer version that produced it so a lesson can
  expire when the tools change (design note in Resonant).
  """

  require Logger
  alias Trailblazer.{Config, Embed, Vectors}
  alias Trailblazer.Loop.CaseRecord

  @request_chars 600
  @signature_chars 400

  @doc "Where the memory lives; also the key of its vector collection."
  def root, do: Path.join(Config.get(:state_dir), "memory")
  defp file, do: Path.join(root(), "outcomes.jsonl")

  @doc """
  The outcome of a closed case, from its record: nil for an unknown or open
  case. `extra` adds what the record does not hold (e.g. `model`).
  """
  @spec outcome(String.t(), map()) :: map() | nil
  def outcome(id, extra \\ %{}) do
    with %{report: %{} = report} = rec <- CaseRecord.get(id) do
      events = rec.events

      %{
        case: id,
        at: rec.closed_at,
        repo: rec.repo,
        request: rec.task |> field("request") |> to_string() |> String.slice(0, @request_chars),
        from: field(rec.task, "from"),
        files: field(rec.task, "files") || [],
        edit_mode: last_value(events, "attempt", "format"),
        status: report["status"],
        reason: report["reason"],
        attempts: report["attempts"],
        reviews: for(e <- events, e.kind == "review", do: e.data["verdict"]),
        signature: signature(events, report),
        version: version()
      }
      |> Map.merge(extra)
    else
      _ -> nil
    end
  end

  @doc """
  Records a closed case's outcome: appends it and stores its vector. Errors
  are returned, never raised; `record_async/2` is what the loop calls.
  """
  @spec record(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def record(id, extra \\ %{}, opts \\ []) do
    with %{} = o <- outcome(id, extra) || {:error, :no_closed_case},
         {:ok, [vector]} <- embed(opts).documents([document(o)], opts),
         :ok <- vectors(opts).ensure(root(), opts),
         :ok <-
           vectors(opts).put(
             root(),
             [%{id: point_id(id), vector: vector, payload: %{case: id}}],
             opts
           ) do
      File.mkdir_p!(root())
      File.write!(file(), Jason.encode!(o) <> "\n", [:append])
      :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Records in the background; a failure is logged and never reaches the caller."
  def record_async(id, extra \\ %{}, opts \\ []) do
    Task.start(fn ->
      case record(id, extra, opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("trailblazer: memory skipped #{id}: #{inspect(reason)}")
      end
    end)
  end

  @doc "All recorded outcomes, latest record per case."
  @spec all() :: [map()]
  def all do
    case File.read(file()) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, o} -> [o]
            _ -> []
          end
        end)
        |> Enum.reverse()
        |> Enum.uniq_by(& &1["case"])
        |> Enum.reverse()

      {:error, _} ->
        []
    end
  end

  @doc "The `limit` recorded outcomes most similar to `text`, as `{score, outcome}`."
  @spec similar(String.t(), pos_integer(), keyword()) ::
          {:ok, [{float(), map()}]} | {:error, term()}
  def similar(text, limit \\ 5, opts \\ []) do
    by_case = Map.new(all(), &{point_id(&1["case"]), &1})

    with {:ok, vector} <- embed(opts).query(text, opts),
         {:ok, hits} <- vectors(opts).nearest(root(), vector, limit, opts) do
      {:ok, for({id, score} <- hits, o = by_case[id], do: {score, o})}
    end
  end

  @doc "Records every closed case not yet in memory (oldest first); returns the count."
  @spec backfill([String.t()], keyword()) :: non_neg_integer()
  def backfill(ids, opts \\ []) do
    known = MapSet.new(all(), & &1["case"])

    ids
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.count(&(record(&1, %{}, opts) == :ok))
  end

  # The text embedded for an outcome: what was asked, then how it went.
  defp document(o) do
    {"#{o.status} #{o.edit_mode} #{o[:model]}",
     "#{o.request}\noutcome: #{o.status} #{o.reason} after #{o.attempts} attempts; " <>
       "reviews: #{Enum.join(o.reviews, ", ")}; failure: #{o.signature}"}
  end

  # The first concrete failure: the first error line of the last failed check,
  # else the last edit refusal, else the report's summary.
  defp signature(events, report) do
    check =
      events
      |> Enum.filter(&(&1.kind == "check" and &1.data["status"] not in ["pass", :pass]))
      |> List.last()

    line =
      if check do
        (check.data["output_tail"] || "")
        |> String.split("\n")
        |> Enum.find(&Regex.match?(~r/error|fail|✗|assert/i, &1))
      end

    (line || report["summary"] || "")
    |> String.trim()
    |> String.slice(0, @signature_chars)
  end

  defp last_value(events, kind, key) do
    events
    |> Enum.filter(&(&1.kind == kind and Map.has_key?(&1.data, key)))
    |> List.last()
    |> case do
      nil -> nil
      e -> e.data[key]
    end
  end

  defp field(map, key) when is_map(map), do: map[key] || map[String.to_atom(key)]
  defp field(_, _), do: nil

  defp version, do: to_string(Application.spec(:trailblazer, :vsn) || "")

  # A stable positive id per case for the vector store.
  defp point_id(case_id), do: :erlang.phash2(case_id, 2_147_483_647) + 1

  defp embed(opts), do: Keyword.get(opts, :embed, Embed)
  defp vectors(opts), do: Keyword.get(opts, :vectors, Vectors)
end
