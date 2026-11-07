defmodule Trailblazer.Trail.RerankTest do
  use ExUnit.Case, async: true

  test "d1 keeps the candidates at or over the threshold, most likely first" do
    cands =
      for {id, n} <- [{7, 1}, {8, 2}, {9, 3}],
          do: %{
            id: id,
            path: "a.ex",
            start_line: n,
            end_line: n,
            qualified: "A.f#{n}/0",
            signature: "def f"
          }

    answers = fn ps ->
      fn _body -> {:ok, %{"answers" => Map.new(ps, fn {k, p} -> {k, %{"noul" => p}} end)}} end
    end

    select = fn decide ->
      Trailblazer.Trail.Rerank.select("x", cands, rerank_decide: decide, rerank_threshold: 0.35)
    end

    assert {:ok, [9, 7]} = select.(answers.([{"c1", 0.4}, {"c2", 0.34}, {"c3", 0.8}]))
    assert {:error, :nothing_named} = select.(answers.([{"c1", 0.1}, {"c2", 0.2}]))
    assert {:error, :no_answer} = select.(fn _ -> {:ok, %{"error" => "x"}} end)
    assert {:error, {:http, 500}} = select.(fn _ -> {:error, {:http, 500}} end)
  end

  test "an answer naming no candidate is a failure, not an empty trail" do
    cands = [
      %{id: 7, path: "a.ex", start_line: 1, end_line: 2, qualified: "A.f/0", signature: "def f"}
    ]

    lfm = fn chat ->
      Trailblazer.Trail.Rerank.select("x", cands, rerank_engine: :lfm, rerank_chat: chat)
    end

    assert {:error, :nothing_named} = lfm.(fn _m, _o -> {:ok, %{content: "none of them"}} end)
    assert {:ok, [7]} = lfm.(fn _m, _o -> {:ok, %{content: "1, 1, 5"}} end)

    # "0" is "none fits" only where a caller allows it (Loop.Examples)
    chat = fn _m, _o -> {:ok, %{content: "0"}} end
    assert {:error, :nothing_named} = lfm.(chat)

    assert {:ok, []} =
             Trailblazer.Trail.Rerank.ask("pick", "x", [{hd(cands), 1}],
               rerank_chat: chat,
               allow_none: true
             )
  end
end
