defmodule Trailblazer.Trail.Rerank do
  @moduledoc """
  The trail's reranker: ranger's LFM3 reranker (same model, same role) asked
  once, without tools, which of the ranked candidates a change really needs.

  The embedder squeezes code into a narrow, high cosine band (0.6-0.8 for
  related and unrelated code alike), so a similarity floor cannot tell them
  apart; the reranker reads names, places and signatures and keeps what the
  request needs. It only filters: candidates it does not name are dropped,
  and any failure (model down, unparsable answer, nothing named) leaves the
  ranking untouched, so a trail is never worse than without it.
  """

  alias Trailblazer.{Config, Model}

  @max_tokens 200

  @system """
  You are a code search reranker. You get a change request and numbered candidate code locations from a code graph and semantic index, each with its path, lines, name, similarity and signature. Decide which candidates a programmer must see to make this change: the code to edit, what it calls or is called by when that matters, and types or helpers it uses. Leave out code that only shares words or topics with the request.

  Answer with the numbers of the needed candidates only, best first, separated by commas, for example: 3, 1, 7. No other text.
  """

  @doc """
  The ids of `candidates` (`%{id, path, start_line, end_line, qualified,
  signature, sim}`) the reranker keeps, in its order; `{:error, reason}` when
  it cannot say.
  """
  @spec select(String.t(), [map()], keyword()) :: {:ok, [term()]} | {:error, term()}
  def select(request, candidates, opts \\ [])
  def select(_request, [], _opts), do: {:error, :no_candidates}

  def select(request, candidates, opts) do
    numbered = Enum.with_index(candidates, 1)

    listing =
      Enum.map_join(numbered, "\n", fn {c, n} ->
        sim = if is_number(c[:sim]), do: " sim=#{Float.round(c.sim * 1.0, 2)}", else: ""

        "[#{n}] #{c.path}:#{c.start_line}-#{c.end_line} #{c.qualified}#{sim}\n    " <>
          String.slice(c.signature || "", 0, 200)
      end)

    messages = [
      %{role: "system", content: String.trim(@system)},
      %{role: "user", content: "Change request:\n#{request}\n\nCandidates:\n#{listing}"}
    ]

    chat = Keyword.get(opts, :rerank_chat, &Model.chat/2)

    case chat.(messages,
           model: Config.get(:rerank_model),
           model_url: Config.get(:rerank_model_url),
           max_tokens: @max_tokens,
           sampling: %{temperature: 0.2, top_p: 1.0, top_k: 0, thinking: false},
           backstop_ms: Config.get(:rerank_backstop_ms),
           backstop_kind: :rerank_call
         ) do
      {:ok, %{content: content}} when is_binary(content) -> parse(content, numbered)
      {:ok, _} -> {:error, :no_answer}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse(content, numbered) do
    by_n = Map.new(numbered, fn {c, n} -> {n, c.id} end)

    # The numbers of the first line that has any: an echoed "path:12-30"
    # further on must not add candidates.
    line = content |> String.split("\n") |> Enum.find("", &(&1 =~ ~r/\d/))

    ids =
      ~r/\d+/
      |> Regex.scan(line)
      |> Enum.map(fn [d] -> String.to_integer(d) end)
      |> Enum.flat_map(&List.wrap(by_n[&1]))
      |> Enum.uniq()

    if ids == [], do: {:error, :nothing_named}, else: {:ok, ids}
  end
end
