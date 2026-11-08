defmodule Trailblazer.Loop.Ledger do
  @moduledoc "Shared bookkeeping for one task: its running tally, the case record, the budgets and small helpers."

  require Logger
  alias Trailblazer.Loop.{CaseRecord, TextAnswers}

  @tally {Trailblazer.Loop, :tally}

  @doc false
  def verification_remaining(st),
    do: max(0, Keyword.get(st.opts, :verification_limit_ms, 900_000) - tally(:verification_ms))

  @doc false
  def budget_remaining! do
    {phase, deadline} = tally(:phase)
    remaining = deadline - now()
    if remaining <= 0, do: throw({:budget_expired, phase})
    remaining
  end

  @doc false
  def tracked(path) do
    case System.cmd("git", ["ls-files", "-z"], cd: path, stderr_to_stdout: true) do
      {out, 0} -> String.split(out, "\0", trim: true)
      _ -> []
    end
  end

  @doc false
  def git(dir, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null" | args],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  end

  @doc false
  def lifecycle({:ok, record}), do: record

  def lifecycle({:error, reason}), do: throw({:lifecycle_error, reason})

  # a record that cannot be written stops the task: no case is kept partially;
  # each one is also logged as it happens, so a run can be followed live
  @doc false
  def record(st, kind, data) do
    :ok = CaseRecord.event(st.id, kind, data)
    Logger.info("trailblazer: case #{st.id} #{kind} #{brief(kind, data)}")
  end

  @doc false
  def brief(:prompt, data), do: "#{data[:role]}, #{length(data[:messages] || [])} messages"

  def brief(:reply, data) do
    "#{data[:role]}#{if data[:partial], do: " (partial)"} finish=#{data[:finish_reason]} " <>
      "#{data[:ms]} ms, reasoning #{byte_size(data[:reasoning] || "")} B, " <>
      "content #{inspect(String.slice(data[:content] || "", 0, 200))}"
  end

  def brief(_, data),
    do: data |> inspect(printable_limit: 200, limit: 20) |> String.slice(0, 400)

  @doc false
  def submit_how(%{task: %{edit_mode: :text}} = st) when is_map_key(st, :id) do
    if TextAnswers.whole_file?(st.task),
      do:
        "as each changed file written out complete: its path on a line, then one fenced block with every line",
      else:
        ~s[as plain-text <edit path start end> blocks with <first>, <last> and <replace> (<create path> for a new file)]
  end

  def submit_how(%{task: %{edit_mode: :text}}),
    do:
      ~s[as plain-text <edit path start end> blocks with <first>, <last> and <replace> (<create path> for a new file)]

  def submit_how(_st), do: "with submit_edits or edit"

  @doc false
  def tally(key), do: Process.get(@tally, %{}) |> Map.get(key, 0)

  @doc false
  def served_reads do
    case tally(:served_reads) do
      %{} = served -> served
      _ -> %{}
    end
  end

  def tally(key, value), do: Process.put(@tally, Map.put(Process.get(@tally, %{}), key, value))

  @doc false
  def mod(st, key, default), do: Keyword.get(st.opts, key, default)

  @doc false
  def query_opts(st), do: Keyword.get(st.opts, :query_opts, [])

  @doc false
  def now, do: System.monotonic_time(:millisecond)

  @doc false
  def describe(reason) when is_binary(reason), do: reason

  def describe(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  def describe({:check, status}), do: "check #{status}"

  def describe({:model, reason}), do: "model #{describe(reason)}"

  def describe({:backstop, id}),
    do: "it did not finish within its backstop (anomaly #{id})"

  def describe({:backstop, id, late: _}),
    do: "it finished only as its backstop fired (anomaly #{id})"

  def describe(reason), do: inspect(reason)
end
