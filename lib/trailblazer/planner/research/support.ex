defmodule Trailblazer.Planner.Research.Support do
  @moduledoc "Small shared helpers of the research route: the research config entry, card titles, term formatting and map reads."

  @doc false
  def research_of(%{research: research}), do: research
  def research_of(_), do: nil

  @doc false
  def title_of(%{context: %{"title" => title}}) when is_binary(title) and title != "",
    do: String.slice(String.trim(title), 0, 200)

  def title_of(card), do: card.ref

  @doc false
  def format(term) when is_binary(term), do: String.slice(term, 0, 300)
  def format(term), do: String.slice(inspect(term), 0, 300)

  @doc false
  def value(map, key) when is_map(map), do: Map.get(map, key)
  def value(_, _), do: nil
end
