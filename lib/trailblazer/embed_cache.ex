defmodule Trailblazer.EmbedCache do
  @moduledoc """
  Persistent vectors keyed by model and the exact document input's SHA256.
  Used inside EmbedGate's permit, so equal misses in different repositories
  cannot race. Points still use each repository's own node ids and payloads.
  """
  alias Trailblazer.{Config, Embed, Store}

  def documents(docs, embed, opts) do
    model = Config.get(:embed_model)
    dims = Keyword.get(opts, :dims, 768)
    keyed = Enum.map(docs, &{hash(&1), &1})

    cached =
      Map.new(keyed, fn {key, _} ->
        vector =
          case Store.embedding_cache_get(model, key) do
            blob when is_binary(blob) and byte_size(blob) == dims * 4 ->
              for <<v::float-little-32 <- blob>>, do: v

            _ ->
              nil
          end

        {key, vector}
      end)

    missing =
      keyed |> Enum.uniq_by(&elem(&1, 0)) |> Enum.filter(fn {key, _} -> is_nil(cached[key]) end)

    with {:ok, values} <- misses(missing, embed, opts),
         true <- length(values) == length(missing) do
      merged =
        Enum.zip(missing, values)
        |> Enum.reduce(cached, fn {{key, _}, vector}, acc ->
          if length(vector) == dims do
            blob = for v <- vector, into: <<>>, do: <<v::float-little-32>>
            :ok = Store.embedding_cache_put(model, key, blob)
          end

          Map.put(acc, key, vector)
        end)

      {:ok, Enum.map(keyed, fn {key, _} -> Map.fetch!(merged, key) end)}
    else
      false -> {:error, :bad_batch}
      error -> error
    end
  end

  defp misses([], _, _), do: {:ok, []}
  defp misses(keyed, embed, opts), do: embed.documents(Enum.map(keyed, &elem(&1, 1)), opts)

  defp hash(doc),
    do: :crypto.hash(:sha256, Embed.document_input(doc)) |> Base.encode16(case: :lower)
end
