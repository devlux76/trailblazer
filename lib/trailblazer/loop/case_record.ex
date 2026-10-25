defmodule Trailblazer.Loop.CaseRecord do
  @moduledoc """
  The record of one task (design §8): the task, every prompt and reply
  verbatim, every tool call, edit, check and review, and the report, in the
  order they happened. It is what the local model will be trained on, so no
  case may be lost or recorded partially.

  Every event is written, and on disk, before `event/3` returns, so the loop
  moves on only after the record has caught up with it: a task killed
  mid-attempt leaves a record that is whole up to its last event (E9). Text
  longer than #{4096} bytes, and text that is not valid UTF-8 (a model can
  emit that, A4), goes to a file under `<state_dir>/cases/<id>/`, written
  before the row that names it; the row holds `%{"$file" => name, "bytes" =>
  n, "sha256" => hex}` in its place, and `get/1` reads it back.

  Data is stored as JSON: atoms become strings and tuples lists, so a record
  reads back with string keys. A key of the caller's that starts with `$` is
  stored with one more `$` and read back as it was, so only a pointer this
  module wrote has the key `"$file"`; a pointer is followed only when its name
  is one this module makes and the file's hash matches (Codex's review of L5:
  model data must never become a path).
  """

  alias Trailblazer.{CaseStore, Config, Events}

  @kinds ~w(prompt reply tool_call edit check review attempt report dossier error)
  @inline_limit 4096

  @type case_id :: String.t()

  @doc "Opens a case for `task` (design §7.1) and gives its id."
  @spec open(map()) :: {:ok, case_id()}
  def open(task) do
    id = new_id()
    repo = to_string(task[:repo] || task["repo"] || "")
    now = System.os_time(:millisecond)

    case CaseStore.case_insert(id, repo, encode(task), now) do
      :ok -> {:ok, id}
      {:error, :exists} -> open(task)
    end
  end

  @doc """
  Appends an event of `kind` (#{Enum.join(@kinds, ", ")}) to an open case.
  """
  @spec event(case_id(), atom() | String.t(), term()) ::
          :ok | {:error, :no_case | :closed | {:bad_kind, term()}}
  def event(id, kind, data), do: append(id, kind, data, nil)

  @doc "Records the report as the case's last event and closes the case."
  @spec close(case_id(), map()) :: :ok | {:error, :no_case | :closed}
  def close(id, report) do
    status = to_string(report[:status] || report["status"] || "failed")
    append(id, :report, report, {status, encode(report)})
  end

  @doc """
  The whole record, events in order, or nil for an unknown id. With
  `inline: false`, text kept in files is left as its placeholder.
  """
  @spec get(case_id(), keyword()) :: map() | nil
  def get(id, opts \\ []) do
    inline? = Keyword.get(opts, :inline, true)

    with %{} = row <- CaseStore.case_get(id) do
      %{
        id: row.id,
        repo: row.repo,
        status: row.status,
        lifecycle: CaseStore.lifecycle_get(id),
        task: row.task |> Jason.decode!() |> unescape(),
        report: row.report && row.report |> Jason.decode!() |> unescape(),
        opened_at: row.opened_at,
        closed_at: row.closed_at,
        events: Enum.map(row.events, &decode_event(id, &1, inline?))
      }
    end
  end

  @doc "The events after `seq`, decoded as in `get/2`."
  @spec events_after(case_id(), non_neg_integer(), keyword()) :: [map()]
  def events_after(id, seq, opts \\ []) do
    inline? = Keyword.get(opts, :inline, true)
    id |> CaseStore.case_events_after(seq) |> Enum.map(&decode_event(id, &1, inline?))
  end

  defp decode_event(id, e, inline?) do
    data = Jason.decode!(e.data)
    data = if inline?, do: inline(id, data), else: data
    %{seq: e.seq, kind: e.kind, at: e.at, data: unescape(data)}
  end

  @doc "Ids of cases that were opened and never closed, oldest first."
  @spec open_cases() :: [case_id()]
  def open_cases, do: CaseStore.case_open_ids()

  @doc "Where a case's files are kept."
  @spec dir(case_id()) :: Path.t()
  def dir(id), do: Path.join([Config.get(:state_dir), "cases", id])

  ## Writing

  defp append(id, kind, data, close) do
    kind = to_string(kind)

    cond do
      kind not in @kinds ->
        {:error, {:bad_kind, kind_term(kind)}}

      not is_binary(id) or CaseStore.case_get(id) == nil ->
        {:error, :no_case}

      true ->
        data = data |> normalize() |> spill(id, kind)

        case CaseStore.case_append(
               id,
               kind,
               System.os_time(:millisecond),
               Jason.encode!(data),
               close
             ) do
          # recorded first, then announced (design §13.3): a follower that
          # hears of it can read it
          {:ok, seq} ->
            Events.publish({:case, id}, %{seq: seq, kind: kind, closed: close != nil})

          error ->
            error
        end
    end
  end

  defp kind_term(kind) do
    String.to_existing_atom(kind)
  rescue
    ArgumentError -> kind
  end

  # Ids sort by time and are safe as a git branch name: 20261018-170512-a3f9c1.
  defp new_id do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    stamp <> "-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
  end

  defp encode(term), do: term |> normalize() |> Jason.encode!()

  # JSON's words for Elixir terms. Strings stay byte for byte here; the ones
  # JSON cannot hold go to files in spill/3.
  defp normalize(value) when is_binary(value) or is_number(value), do: value
  defp normalize(value) when is_boolean(value) or is_nil(value), do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value) when is_tuple(value), do: value |> Tuple.to_list() |> normalize()
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(%_{} = struct) do
    if String.Chars.impl_for(struct), do: to_string(struct), else: inspect(struct)
  end

  defp normalize(%{} = map), do: Map.new(map, fn {k, v} -> {key(k), normalize(v)} end)
  defp normalize(other), do: inspect(other)

  defp key("$" <> _ = k), do: "$" <> k
  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: k |> Atom.to_string() |> key()
  defp key(k), do: inspect(k)

  defp spill(value, id, kind) when is_binary(value) do
    if byte_size(value) > @inline_limit or not String.valid?(value) do
      write_file(id, kind, value)
    else
      value
    end
  end

  defp spill(value, id, kind) when is_list(value), do: Enum.map(value, &spill(&1, id, kind))

  defp spill(%{} = map, id, kind),
    do: Map.new(map, fn {k, v} -> {k, spill(v, id, kind)} end)

  defp spill(value, _id, _kind), do: value

  defp write_file(id, kind, text) do
    dir = dir(id)
    File.mkdir_p!(dir)

    name =
      "#{System.os_time(:microsecond)}-#{kind}-#{Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)}.txt"

    File.write!(Path.join(dir, name), text, [:sync])

    %{
      "$file" => name,
      "bytes" => byte_size(text),
      "sha256" => Base.encode16(:crypto.hash(:sha256, text), case: :lower)
    }
  end

  ## Reading

  defp inline(id, %{"$file" => name, "sha256" => sha} = pointer) do
    with true <- is_binary(name) and Regex.match?(~r/^\d+-[a-z_]+-[0-9a-f]{6}\.txt$/, name),
         {:ok, text} <- File.read(Path.join(dir(id), name)),
         true <- Base.encode16(:crypto.hash(:sha256, text), case: :lower) == sha do
      text
    else
      _ -> Map.put(pointer, "missing", true)
    end
  end

  defp inline(id, list) when is_list(list), do: Enum.map(list, &inline(id, &1))
  defp inline(id, %{} = map), do: Map.new(map, fn {k, v} -> {k, inline(id, v)} end)
  defp inline(_id, value), do: value

  defp unescape(list) when is_list(list), do: Enum.map(list, &unescape/1)

  defp unescape(%{} = map) do
    Map.new(map, fn
      {"$$" <> rest, v} -> {"$" <> rest, unescape(v)}
      {k, v} -> {k, unescape(v)}
    end)
  end

  defp unescape(value), do: value
end
