defmodule Trailblazer.Trail.Rerank do
  @moduledoc """
  The trail's reranker: which of the ranked candidates a change really needs.

  By default (`:rerank_engine` `:d1`) LiquidAI d1-2B, a native decision model
  served on its own port (`/v1/systemone`), answers one yes/no question per
  candidate with a probability; the candidates at or over
  `:rerank_threshold` stay, most likely first. `:lfm` asks ranger's LFM3 for
  candidate numbers instead (listwise; live 2026-11-06 it often answered in
  prose with no numbers, ~35 s, and the trail fell back to the plain ranking).
  `ask/4` (Loop.Examples) stays on LFM3 until the history replay eval.

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
    case Keyword.get_lazy(opts, :rerank_engine, fn -> Config.get(:rerank_engine) end) do
      :d1 -> decide(request, candidates, opts)
      :lfm -> select_lfm(request, candidates, opts)
    end
  end

  @question "Does a programmer making this change need to read this code?"

  @doc """
  `select/3` with d1-2B: one `noul` question per candidate against the change
  request; the ids whose probability is at least `:rerank_threshold`, most
  likely first. Nothing over the threshold is `{:error, :nothing_named}` (the
  trail keeps its ranking), as for the listwise engine.
  """
  @spec decide(String.t(), [map()], keyword()) :: {:ok, [term()]} | {:error, term()}
  def decide(request, candidates, opts \\ []) do
    numbered = Enum.with_index(candidates, 1)

    questions =
      Map.new(numbered, fn {c, n} ->
        {"c#{n}",
         %{
           type: "noul",
           instructions:
             "#{@question} #{c.path}:#{c.start_line}-#{c.end_line} #{c.qualified}\n" <>
               String.slice(c.signature || "", 0, 200)
         }}
      end)

    body = %{state: "Change request:\n#{request}", questions: questions}
    post = Keyword.get(opts, :rerank_decide, &post_decide/1)
    threshold = Keyword.get_lazy(opts, :rerank_threshold, fn -> Config.get(:rerank_threshold) end)

    with {:ok, %{"answers" => answers}} when is_map(answers) <- post.(body) do
      kept =
        for {c, n} <- numbered,
            p = get_in(answers, ["c#{n}", "noul"]),
            is_number(p) and p >= threshold,
            do: {c.id, p}

      case kept do
        [] -> {:error, :nothing_named}
        _ -> {:ok, kept |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.map(&elem(&1, 0))}
      end
    else
      {:ok, _} -> {:error, :no_answer}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp post_decide(body) do
    case Req.post(Config.get(:rerank_decide_url),
           json: body,
           retry: false,
           receive_timeout: Config.get(:rerank_backstop_ms)
         ) do
      {:ok, %{status: 200, body: answer}} -> {:ok, answer}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, e} -> {:error, Exception.message(e)}
    end
  end

  defp select_lfm(request, candidates, opts) do
    numbered = Enum.with_index(candidates, 1)

    listing =
      Enum.map_join(numbered, "\n", fn {c, n} ->
        sim = if is_number(c[:sim]), do: " sim=#{Float.round(c.sim * 1.0, 2)}", else: ""

        "[#{n}] #{c.path}:#{c.start_line}-#{c.end_line} #{c.qualified}#{sim}\n    " <>
          String.slice(c.signature || "", 0, 200)
      end)

    ask(@system, "Change request:\n#{request}\n\nCandidates:\n#{listing}", numbered, opts)
  end

  @doc """
  One reranker call with any selection prompt (`Trailblazer.Loop.Examples`
  picks past changes with its own): `system` asks for candidate numbers, best
  first; `numbered` is `[{candidate, n}]`, each candidate with an `:id`. With
  `allow_none: true` an answer that names no candidate ("0", "None") is
  `{:ok, []}` (nothing fits); otherwise it is `{:error, :nothing_named}`, as
  for `select/3`.
  """
  @spec ask(String.t(), String.t(), [{map(), pos_integer()}], keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def ask(system, user, numbered, opts \\ []) do
    messages = [
      %{role: "system", content: String.trim(system)},
      %{role: "user", content: user}
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
      # a blank reply (thinking only, cut off) is no answer, never "none fits"
      {:ok, %{content: content}} when is_binary(content) ->
        if String.trim(content) == "",
          do: {:error, :no_answer},
          else: parse(content, numbered, Keyword.get(opts, :allow_none, false))

      {:ok, _} ->
        {:error, :no_answer}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse(content, numbered, allow_none?) do
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

    cond do
      ids != [] -> {:ok, ids}
      # "0", "None.", "0 - none fit": an answer that names no candidate is a
      # rejection where the caller allows one, never a fallback to all
      allow_none? -> {:ok, []}
      true -> {:error, :nothing_named}
    end
  end
end
