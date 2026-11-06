defmodule Trailblazer.Vectors do
  @moduledoc """
  One Qdrant collection per repository, holding one vector per definition,
  keyed by the node's id. Modelled on mirai-agent's `MiraiAgent.Memory.Index`.

  The collection is named for the embedding model and the repository's path,
  so vectors from two models never share one, and it is never a `ranger_*`
  collection. Writes wait for Qdrant to finish them: an operation it has only
  acknowledged is `{:error, {:not_completed, status}}`, not success (D6, E7 in
  the register).

  Every function returns `{:error, :qdrant_down}` when the connection is
  refused. `opts[:req_options]` is merged into every request.
  """

  alias Trailblazer.Config

  @dims 768

  @doc """
  The repository's collection. The store's state directory is part of the
  name: two stores give one repository's nodes different ids, so they must
  never share points (E10 in the register).
  """
  @spec collection(Path.t(), Path.t()) :: String.t()
  def collection(repo_path, state_dir \\ Config.get(:state_dir)) do
    key =
      Enum.join([Config.get(:embed_model), Path.expand(repo_path), Path.expand(state_dir)], "\n")

    hex =
      :crypto.hash(:sha, key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "trailblazer_" <> hex
  end

  @doc """
  Makes sure the repository's collection exists for vectors of 768 cosine;
  `{:error, {:dims, size}}` when it exists with another width.
  """
  @spec ensure(Path.t(), keyword()) :: :ok | {:error, term()}
  def ensure(repo_path, opts \\ []) do
    path = "/collections/#{collection(repo_path)}"

    case request(:get, path, nil, opts) do
      {:ok, 200, %{"result" => %{"config" => %{"params" => %{"vectors" => %{"size" => @dims}}}}}} ->
        :ok

      {:ok, 200, %{"result" => %{"config" => %{"params" => %{"vectors" => %{"size" => size}}}}}} ->
        {:error, {:dims, size}}

      {:ok, 404, _body} ->
        body = %{vectors: %{size: @dims, distance: "Cosine"}}

        case request(:put, path, body, opts) do
          {:ok, 200, _body} -> :ok
          other -> failure(other)
        end

      other ->
        failure(other)
    end
  end

  @doc """
  A stable point id for `key`: the first 63 bits of its sha256, never 0.
  Qdrant overwrites a point whose id repeats, so ids must not collide:
  `:erlang.phash2`'s 31 bits make a collision likely past about 10k points;
  63 bits keep it negligible far past any corpus here (callers still check).
  """
  @spec point_id(String.t()) :: pos_integer()
  def point_id(key) do
    <<n::unsigned-64, _::binary>> = :crypto.hash(:sha256, key)
    max(Bitwise.band(n, 0x7FFF_FFFF_FFFF_FFFF), 1)
  end

  @spec put(Path.t(), [%{id: pos_integer(), vector: [number()], payload: map()}], keyword()) ::
          :ok | {:error, term()}
  def put(repo_path, points, opts \\ [])
  def put(_repo_path, [], _opts), do: :ok

  def put(repo_path, points, opts) do
    case Enum.find(points, &(not (is_integer(&1.id) and &1.id > 0))) do
      nil ->
        body = %{points: Enum.map(points, &Map.take(&1, [:id, :vector, :payload]))}
        write(:put, "/collections/#{collection(repo_path)}/points?wait=true", body, opts)

      point ->
        {:error, {:bad_id, point.id}}
    end
  end

  @spec delete(Path.t(), [pos_integer()], keyword()) :: :ok | {:error, term()}
  def delete(repo_path, ids, opts \\ [])
  def delete(_repo_path, [], _opts), do: :ok

  def delete(repo_path, ids, opts) do
    path = "/collections/#{collection(repo_path)}/points/delete?wait=true"
    write(:post, path, %{points: ids}, opts)
  end

  @doc "The `limit` points nearest to `vector`, nearest first, as `{id, score}`."
  @spec nearest(Path.t(), [number()], pos_integer(), keyword()) ::
          {:ok, [{pos_integer(), float()}]} | {:error, term()}
  def nearest(repo_path, vector, limit, opts \\ []) do
    query(repo_path, %{query: vector, limit: limit, with_payload: false}, opts)
  end

  @doc "The score of each of `ids` against `vector`; ids without a vector are absent."
  @spec scores(Path.t(), [number()], [pos_integer()], keyword()) ::
          {:ok, %{pos_integer() => float()}} | {:error, term()}
  def scores(repo_path, vector, ids, opts \\ [])
  def scores(_repo_path, _vector, [], _opts), do: {:ok, %{}}

  def scores(repo_path, vector, ids, opts) do
    body = %{
      query: vector,
      limit: length(ids),
      filter: %{must: [%{has_id: ids}]},
      with_payload: false
    }

    with {:ok, hits} <- query(repo_path, body, opts), do: {:ok, Map.new(hits)}
  end

  @doc "Drops the repository's collection (used by the live test and by a reset)."
  @spec drop(Path.t(), keyword()) :: :ok | {:error, term()}
  def drop(repo_path, opts \\ []) do
    case request(:delete, "/collections/#{collection(repo_path)}", nil, opts) do
      {:ok, status, _body} when status in [200, 404] -> :ok
      other -> failure(other)
    end
  end

  defp query(repo_path, body, opts) do
    case request(:post, "/collections/#{collection(repo_path)}/points/query", body, opts) do
      {:ok, 200, %{"result" => %{"points" => points}}} when is_list(points) ->
        hits(points)

      other ->
        failure(other)
    end
  end

  defp hits(points) do
    if Enum.all?(points, &(is_map(&1) and is_integer(&1["id"]) and is_number(&1["score"]))),
      do: {:ok, Enum.map(points, &{&1["id"], &1["score"]})},
      else: {:error, {:bad_response, {:points, points}}}
  end

  defp write(method, path, body, opts) do
    case request(method, path, body, opts) do
      {:ok, 200, %{"result" => %{"status" => "completed"}}} -> :ok
      {:ok, 200, %{"result" => %{"status" => status}}} -> {:error, {:not_completed, status}}
      other -> failure(other)
    end
  end

  defp failure({:ok, 200, body}), do: {:error, {:bad_response, body}}
  defp failure({:ok, status, _body}), do: {:error, {:http, status}}
  defp failure({:error, _} = error), do: error

  defp request(method, path, body, opts) do
    request =
      Req.new(method: method, url: Config.get(:qdrant_url) <> path, receive_timeout: :infinity)
      |> then(fn request -> if body, do: Req.merge(request, json: body), else: request end)
      |> Req.merge(Keyword.get(opts, :req_options, []))

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, %Req.TransportError{reason: :econnrefused}} -> {:error, :qdrant_down}
      {:error, %Req.TransportError{reason: reason}} -> {:error, reason}
      {:error, error} -> {:error, error}
    end
  end
end
