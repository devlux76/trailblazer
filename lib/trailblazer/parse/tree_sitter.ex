defmodule Trailblazer.Parse.TreeSitter do
  @moduledoc """
  JavaScript, TypeScript, Python, C, C++ and Go, parsed by tree-sitter in
  processes of their own.

  Elixir has its own parser and it is exact; tree-sitter is here for the
  languages it does not cover, and it is run behind Erlang Ports rather than
  as a NIF, so a parser crash costs that process and not the VM.

  This is a pool: `parse_workers` parsers (2 by default, so the model keeps
  most of the six threads), each a process owning one Port, and the queue that
  owns the callers waiting for one. A caller is given a free parser; when all
  are busy it waits in the pool's FIFO queue for as long as the work takes.
  Nothing is given up on because a time passed (design §13.2): the call waits
  with `:infinity`, the pool watches the caller, and a caller that dies while
  queued is dropped while one that dies mid-parse has its answer discarded —
  its file is still parsed and the queue goes on.

  Each parse arms one backstop (`backstop_parse_ms`, five minutes by default).
  It is the only way a parse ends without an answer: the Port's reply and the
  Port's death both answer it, and if the backstop fires the Port is closed,
  that one file is `{:error, :timeout}` and an anomaly says why. A worker or a
  Port that dies fails only its own file, `{:error, :parser_crashed}` (J14): the
  pool replaces the parser and serves the queue.

  A file that does not parse is not an error: the tree has everything that came
  before the error, and the file's definitions stay in the graph, marked stale
  by the indexer (Task 8).

  The signature and the text hash are computed here, in Elixir, as the plan
  says they are.
  """
  use GenServer

  alias Trailblazer.Config
  alias Trailblazer.Parse.TreeSitter.Worker

  @languages [:javascript, :typescript, :tsx, :python, :c, :cpp, :go]

  @doc """
  The definitions and references of `source`, as `{:ok, %{nodes:, refs:}}` or
  `{:error, reason}` with the same reasons it always had
  (`:parser_crashed | :parser_missing | :timeout | :invalid_encoding |
  {:unknown_lang, lang} | {:parser_failed, message} | :bad_reply`), where
  `lang` is `:javascript | :typescript | :tsx | :python | :c | :cpp | :go`.
  """
  @spec parse(Path.t(), term(), binary()) ::
          {:ok, %{nodes: [map()], refs: [map()]}} | {:error, term()}
  def parse(path, lang, source) do
    GenServer.call(__MODULE__, {:parse, path, lang, source}, :infinity)
  end

  @doc """
  The operating system process ids of the pool's parsers, one for each parser
  that has a Port open: none before the first parse, one per busy or used
  parser after.

  The tests kill them to see what happens to the file that was waiting on one,
  and to see that a killed parser is replaced; an operator may kill one to
  start afresh.
  """
  @spec os_pids() :: [integer()]
  def os_pids, do: GenServer.call(__MODULE__, :os_pids, :infinity)

  @doc """
  One of the pool's parser process ids, or `nil` when none is running.
  """
  @spec os_pid() :: integer() | nil
  def os_pid do
    case os_pids() do
      [] -> nil
      [pid | _rest] -> pid
    end
  end

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    # A worker is linked: without this the pool would go down with a worker.
    Process.flag(:trap_exit, true)

    {:ok,
     Enum.reduce(1..count(), %{workers: %{}, free: [], queue: :queue.new()}, fn id, state ->
       add(state, id)
     end)}
  end

  @impl GenServer
  def handle_call({:parse, _path, lang, _source}, _from, state) when lang not in @languages do
    {:reply, {:error, {:unknown_lang, lang}}, state}
  end

  def handle_call({:parse, path, lang, source}, {caller, _tag} = from, state) do
    if String.valid?(source) do
      # The caller is watched, because it may die before the pool answers.
      request = %{
        from: from,
        token: make_ref(),
        mon: Process.monitor(caller),
        path: path,
        lang: lang,
        source: source
      }

      {:noreply, take(%{state | queue: :queue.in(request, state.queue)})}
    else
      {:reply, {:error, :invalid_encoding}, state}
    end
  end

  def handle_call(:os_pids, _from, state), do: {:reply, parsers(state), state}

  @impl GenServer
  # The file is parsed; its worker is free again and takes the next request.
  def handle_info({:parsed, pid, token, result}, state) do
    case worker(state, pid) do
      # a message of a worker that a replacement already took over
      nil ->
        {:noreply, state}

      %{job: %{token: ^token} = job} = parser ->
        forget(job)
        GenServer.reply(job.from, result)

        {:noreply,
         take(%{
           state
           | free: state.free ++ [parser.id],
             workers: Map.put(state.workers, parser.id, %{parser | job: nil})
         })}

      _parser ->
        {:noreply, state}
    end
  end

  def handle_info({:worker_port, pid, os_pid}, state) do
    case worker(state, pid) do
      nil ->
        {:noreply, state}

      parser ->
        {:noreply,
         %{state | workers: Map.put(state.workers, parser.id, %{parser | os_pid: os_pid})}}
    end
  end

  # J14: a worker that died fails only its own file. The pool replaces it and
  # the queue goes on.
  def handle_info({:EXIT, pid, _reason}, state) do
    case worker(state, pid) do
      nil ->
        {:noreply, state}

      parser ->
        state = %{
          state
          | workers: Map.delete(state.workers, parser.id),
            free: List.delete(state.free, parser.id)
        }

        if parser.job do
          forget(parser.job)
          GenServer.reply(parser.job.from, {:error, :parser_crashed})
        end

        {:noreply, take(add(state, parser.id))}
    end
  end

  # A caller that died while its file was queued is dropped. One that died
  # while its file was being parsed is left to finish, and its answer goes
  # nowhere: `GenServer.reply/2` to a dead caller is a no-op.
  def handle_info({:DOWN, ref, :process, _caller, _reason}, state) do
    case Enum.find(:queue.to_list(state.queue), &(&1.mon == ref)) do
      nil -> {:noreply, state}
      _request -> {:noreply, %{state | queue: reject(state.queue, ref)}}
    end
  end

  ## The pool

  defp count do
    case Config.get(:parse_workers) do
      n when is_integer(n) and n > 0 -> n
      other -> raise ArgumentError, "parse_workers must be a positive integer: #{inspect(other)}"
    end
  end

  defp add(state, id) do
    {:ok, pid} = Worker.start_link(self(), id)

    %{
      state
      | workers: Map.put(state.workers, id, %{id: id, pid: pid, os_pid: nil, job: nil}),
        free: state.free ++ [id]
    }
  end

  # A free worker takes the next request (demand, design §13.2 rule 5). The
  # queue is FIFO and the pool owns it: callers come in on `parse/3` and go as
  # parsers finish.
  defp take(state) do
    case {state.free, :queue.out(state.queue)} do
      {[], _queue} ->
        state

      {_free, {:empty, queue}} ->
        %{state | queue: queue}

      {[id | free], {{:value, request}, queue}} ->
        parser = state.workers[id]

        GenServer.cast(
          parser.pid,
          {:parse, request.token, request.path, request.lang, request.source}
        )

        %{
          state
          | free: free,
            queue: queue,
            workers: Map.put(state.workers, id, %{parser | job: request})
        }
    end
  end

  defp worker(state, pid) do
    Enum.find_value(state.workers, fn {_id, parser} -> parser.pid == pid && parser end)
  end

  defp parsers(state) do
    state.workers
    |> Map.values()
    |> Enum.map(& &1.os_pid)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp reject(queue, ref) do
    queue |> :queue.to_list() |> Enum.reject(&(&1.mon == ref)) |> :queue.from_list()
  end

  defp forget(%{mon: mon}), do: Process.demonitor(mon, [:flush])

  ## The reply

  @doc false
  @spec build(binary(), Path.t(), term(), binary()) ::
          {:ok, %{nodes: [map()], refs: [map()]}} | {:error, term()}
  def build(data, path, lang, source) do
    case Jason.decode(data) do
      {:ok, %{"error" => message}} -> {:error, {:parser_failed, message}}
      {:ok, %{"nodes" => nodes, "refs" => refs}} -> parsed(nodes, refs, path, lang, source)
      {:ok, _other} -> {:error, :bad_reply}
      {:error, _reason} -> {:error, {:bad_reply, data}}
    end
  end

  defp parsed(nodes, refs, path, lang, source) do
    # numbered, so that reading a definition's own lines is a step and not a
    # walk of the whole file: a big file has tens of thousands of definitions
    lines = numbered(source)

    # one hash per line range, not per definition: a minified file has every
    # definition on the same line, and there are thousands of them
    hashes =
      nodes
      |> Enum.map(fn attrs -> {attrs["start_line"], attrs["end_line"]} end)
      |> Enum.uniq()
      |> Map.new(fn {first, last} -> {{first, last}, text_hash(lines, first, last)} end)

    nodes = Enum.map(nodes, &node(&1, path, lang, lines, hashes))
    {:ok, %{nodes: nodes, refs: Enum.map(refs, &ref/1)}}
  end

  defp node(attrs, path, lang, lines, hashes) do
    first = attrs["start_line"]
    last = attrs["end_line"]

    %{
      key: attrs["key"],
      lang: attrs["lang"] || Atom.to_string(lang),
      kind: attrs["kind"],
      name: attrs["name"],
      qualified: attrs["qualified"],
      path: attrs["path"] || path,
      start_line: first,
      end_line: last,
      signature: signature(lines, first),
      text_hash: Map.get(hashes, {first, last})
    }
  end

  defp ref(attrs) do
    %{
      from_key: attrs["from_key"],
      kind: attrs["kind"],
      target: attrs["target"],
      ambiguous: false,
      arity: attrs["arity"],
      line: attrs["line"]
    }
  end

  defp numbered(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, number} -> {number, line} end)
    |> Map.new()
  end

  # The plan's rule for every parser: the first source line, trimmed.
  defp signature(lines, first) do
    case Map.get(lines, first) do
      nil -> ""
      line -> line |> String.trim() |> String.slice(0, 200)
    end
  end

  defp text_hash(lines, first, last) do
    lines = for number <- first..max(last, first), do: Map.get(lines, number, "")

    lines
    |> Enum.map_join("\n", & &1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
