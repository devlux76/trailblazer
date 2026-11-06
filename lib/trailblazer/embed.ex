defmodule Trailblazer.Embed do
  @moduledoc """
  Turns text into vectors with the local embedder (EmbeddingGemma on `:8091`),
  in the forms ranger uses: documents as `"title: <title> | text: <text>"`,
  queries as `"task: code retrieval | query: <query>"`.

  A reply counts only when it holds one vector of the right width per input,
  with every index once (D6 in the register): anything else is
  `{:error, {:bad_response, reason}}`, so nothing is marked embedded on the
  word of a reply that did not embed it.

  Documents are spread over a pool of embedders (`opts[:urls]`, else the
  `:embed_urls` setting) as a work queue: the inputs are cut into chunks and
  each embedder takes the next chunk as soon as it is free, so a faster device
  does more of them. When none are left, a free embedder takes a backup copy of
  a chunk still running elsewhere and the first answer wins, so the call never
  waits on a device many times slower than the rest (J30). A chunk an embedder
  failed is done by one that did not; the call fails only when every embedder
  has. Queries go to the first one.
  With a single embedder the chunks are the batches of 16, sent in turn.

  Queries come first (`Trailblazer.EmbedGate`): a query runs inside
  `EmbedGate.query/2`, and every document request first waits on
  `EmbedGate.clear/1`. The embedder serves requests in arrival order, so a
  query waits for at most the request already on it. `opts[:gate]` names the
  gate (false: none).

  `opts[:req_options]` is merged into every request (tests pass a `Req.Test`
  plug); `opts[:dims]` is the width expected (768).
  """

  alias Trailblazer.Config
  require Logger

  @batch 16
  # Small, so a backup copy of a straggler's chunk is cheap for a fast device.
  @pool_chunk 4
  @dims 768
  @limit 2_400
  @calls 8

  @spec documents([{String.t(), String.t()}], keyword()) ::
          {:ok, [[float()]]} | {:error, :embedder_down | term()}
  def documents(docs, opts \\ []) do
    urls = urls(opts)
    size = if length(urls) == 1, do: @batch, else: @pool_chunk
    chunks = docs |> Enum.map(&document_input/1) |> Enum.chunk_every(size)

    with {:ok, vectors} <- queue(chunks, urls, opts), do: {:ok, Enum.concat(vectors)}
  end

  @doc "The embedders documents are spread over; the first also answers queries."
  @spec urls(keyword()) :: [String.t()]
  def urls(opts \\ []), do: Keyword.get_lazy(opts, :urls, fn -> Config.get(:embed_urls) end)

  # The calling process deals the chunks out, one request per embedder at a
  # time. An embedder that finds none left takes a backup copy of a chunk
  # still running elsewhere (the one with the fewest copies, then the oldest),
  # so a device many times slower than the rest never holds up the call: the
  # first answer for a chunk is kept and the copies still running are stopped.
  # An embedder that fails gets no more chunks, and its chunk is dealt again
  # unless a copy is still running. The call fails only when every embedder has.
  defp queue([], _urls, _opts), do: {:ok, []}
  defp queue(chunks, [url], opts), do: in_turn(chunks, url, opts)

  defp queue(chunks, urls, opts) do
    pool = %{
      chunks: List.to_tuple(chunks),
      todo: Enum.to_list(0..(length(chunks) - 1)),
      done: %{},
      running: %{},
      idle: urls,
      failed: [],
      backups: 0,
      opts: opts
    }

    pool |> deal() |> await()
  end

  defp await(%{done: done, chunks: chunks} = pool) when map_size(done) == tuple_size(chunks) do
    Enum.each(Map.values(pool.running), fn {task, _i, _url, _at} ->
      Task.shutdown(task, :brutal_kill)
    end)

    if pool.backups > 0,
      do: Logger.info("embed pool: #{tuple_size(chunks)} chunks, #{pool.backups} backup copies")

    {:ok, Enum.map(0..(tuple_size(chunks) - 1)//1, &Map.fetch!(done, &1))}
  end

  defp await(%{running: running} = pool) when map_size(running) == 0 do
    {_url, reason} = List.last(pool.failed)
    {:error, reason}
  end

  defp await(pool) do
    receive do
      {ref, result} when is_map_key(pool.running, ref) ->
        Process.demonitor(ref, [:flush])
        {{_task, i, url, _at}, running} = Map.pop(pool.running, ref)
        pool = %{pool | running: running}

        pool =
          case result do
            {:ok, vectors} ->
              stop_copies(
                %{pool | done: Map.put_new(pool.done, i, vectors), idle: [url | pool.idle]},
                i
              )

            {:error, reason} ->
              retry_chunk(%{pool | failed: pool.failed ++ [{url, reason}]}, i)
          end

        pool |> deal() |> await()
    end
  end

  # The chunk is answered: copies still running elsewhere are stopped, and
  # their embedders are free again.
  defp stop_copies(pool, i) do
    {copies, running} = Map.split_with(pool.running, fn {_ref, {_t, j, _u, _at}} -> j == i end)
    Enum.each(Map.values(copies), fn {task, _, _, _} -> Task.shutdown(task, :brutal_kill) end)
    %{pool | running: running, idle: Enum.map(Map.values(copies), &elem(&1, 2)) ++ pool.idle}
  end

  defp retry_chunk(pool, i) do
    copy_running? = Enum.any?(Map.values(pool.running), fn {_t, j, _u, _at} -> j == i end)

    if Map.has_key?(pool.done, i) or copy_running?,
      do: pool,
      else: %{pool | todo: [i | pool.todo]}
  end

  # Every free embedder takes a chunk if there is one it can take; the ones
  # that cannot stay free.
  defp deal(pool), do: deal(pool, pool.idle, [])

  defp deal(pool, [], free), do: %{pool | idle: Enum.reverse(free)}

  defp deal(pool, [url | rest], free) do
    case next_chunk(pool, url) do
      nil ->
        deal(pool, rest, [url | free])

      {i, kind, todo} ->
        # A named function, not a closure, so a hot load mid-call purges nothing it runs.
        task = Task.async(__MODULE__, :chunk, [elem(pool.chunks, i), url, pool.opts])
        running = Map.put(pool.running, task.ref, {task, i, url, System.monotonic_time()})
        backups = if kind == :backup, do: pool.backups + 1, else: pool.backups
        deal(%{pool | todo: todo, running: running, backups: backups}, rest, free)
    end
  end

  defp next_chunk(%{todo: [i | todo]}, _url), do: {i, :first, todo}

  defp next_chunk(pool, url) do
    runs = Map.values(pool.running)
    mine = for {_t, i, ^url, _at} <- runs, into: MapSet.new(), do: i
    copies = Enum.frequencies_by(runs, &elem(&1, 1))

    runs
    |> Enum.reject(fn {_t, i, _u, _at} -> i in mine or Map.has_key?(pool.done, i) end)
    |> Enum.min_by(fn {_t, i, _u, at} -> {copies[i], at} end, fn -> nil end)
    |> case do
      nil -> nil
      {_t, i, _u, _at} -> {i, :backup, pool.todo}
    end
  end

  @doc false
  def chunk(inputs, url, opts), do: document_request(inputs, url, opts)

  # A document request waits while any query runs: queries come first.
  defp document_request(inputs, url, opts) do
    case Keyword.get(opts, :gate, Trailblazer.EmbedGate) do
      false -> :ok
      gate -> Trailblazer.EmbedGate.clear(gate)
    end

    embed(inputs, url, opts)
  end

  defp in_turn(chunks, url, opts) do
    chunks
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, done} ->
      case document_request(chunk, url, opts) do
        {:ok, vectors} -> {:cont, {:ok, [vectors | done]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  @doc false
  def document_input({title, text}), do: "title: #{title} | text: #{text}"

  @spec query(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def query(text, opts \\ []) do
    run = fn -> embed(["task: code retrieval | query: #{text}"], hd(urls(opts)), opts) end

    result =
      case Keyword.get(opts, :gate, Trailblazer.EmbedGate) do
        false -> run.()
        gate -> Trailblazer.EmbedGate.query(run, gate)
      end

    with {:ok, [vector]} <- result, do: {:ok, vector}
  end

  @doc """
  The title and text embedded for a definition: its qualified name, then a
  header `"<kind> <qualified> · <signature> · calls: <up to 8 names>"`, a
  newline and its source, the whole at most `limit` characters (2,400; a
  repository under a compact root gets `Config.doc_limit/1`'s shorter one).
  """
  @spec node_text(map(), String.t(), [String.t()], pos_integer()) :: {String.t(), String.t()}
  def node_text(node, source, calls, limit \\ @limit) do
    header =
      "#{node.kind} #{node.qualified} · #{node.signature} · calls: " <>
        Enum.join(Enum.take(calls, @calls), ", ")

    {node.qualified, String.slice(header <> "\n" <> source, 0, limit)}
  end

  defp embed(inputs, url, opts) do
    request =
      Req.new(
        url: url,
        json: %{model: Config.get(:embed_model), input: inputs},
        receive_timeout: :infinity
      )
      |> Req.merge(Keyword.get(opts, :req_options, []))

    started = System.monotonic_time(:millisecond)

    case Req.post(request) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        log_throughput(url, length(inputs), body, System.monotonic_time(:millisecond) - started)
        vectors(body, length(inputs), Keyword.get(opts, :dims, @dims))

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :embedder_down}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, reason}

      {:error, error} ->
        {:error, error}
    end
  end

  # One line per request, so throughput is measured per embedder in tokens,
  # not guessed from vectors/s (which swings with document size and cache hits).
  defp log_throughput(url, docs, body, ms) do
    tokens = get_in(body, ["usage", "prompt_tokens"])
    host = URI.parse(url).port

    rate =
      if is_integer(tokens) and ms > 0, do: " #{round(tokens * 1000 / ms)} tokens/s", else: ""

    Logger.info("embed :#{host} #{docs} docs #{inspect(tokens)} tokens #{ms} ms#{rate}")
  end

  # One vector per input, each index once, each of the expected width and
  # made of numbers; given back in the inputs' order.
  defp vectors(%{"data" => data}, count, dims) when is_list(data) do
    indices = Enum.map(data, &(is_map(&1) && &1["index"]))

    cond do
      Enum.sort(indices) != Enum.to_list(0..(count - 1)//1) ->
        {:error, {:bad_response, {:indices, indices}}}

      not Enum.all?(data, &vector?(&1["embedding"], dims)) ->
        {:error, {:bad_response, :vector}}

      true ->
        {:ok, data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])}
    end
  end

  defp vectors(body, _count, _dims), do: {:error, {:bad_response, {:body, body}}}

  defp vector?(vector, dims) when is_list(vector),
    do: length(vector) == dims and Enum.all?(vector, &is_number/1)

  defp vector?(_other, _dims), do: false
end
