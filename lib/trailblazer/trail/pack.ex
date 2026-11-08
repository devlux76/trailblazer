defmodule Trailblazer.Trail.Pack do
  @moduledoc """
  Packs ranked definitions into a trail's text within a budget: full source first,
  then signatures, then the design sections they implement as excerpts.
  """

  alias Trailblazer.{Files, Store}
  alias Trailblazer.Trail

  @full_share 0.6
  @excerpt 600
  @summary ~w(id kind qualified path start_line end_line signature stale)a

  @doc false
  def pack(repo_id, path, ranked, budget, omit) do
    limit = max(budget, 0) * 4
    full_until = trunc(limit * @full_share)
    sources = %{}
    nodes = Map.new(Store.nodes(ranked), &{&1.id, &1})

    # No line is packed twice: a definition inside one already given in full
    # is there already, and one holding such a definition is given by its
    # signature only.
    {parts, items, used, _sources, _full} =
      ranked
      |> Enum.map(&Map.get(nodes, &1))
      |> Enum.reject(
        &(is_nil(&1) or Trail.doc?(&1) or Trail.file_node?(&1) or MapSet.member?(omit, &1.path))
      )
      |> Enum.reduce({[], [], 0, sources, []}, fn node, {parts, items, used, sources, full_at} ->
        {source, sources} = source_of(path, node, sources)
        head = "#{node.path}:#{node.start_line}-#{node.end_line}\n"
        full = head <> source <> "\n"
        short = head <> node.signature <> "\n"

        cond do
          Enum.any?(full_at, &within?(node, &1)) ->
            {parts, items, used, sources, full_at}

          used + cost(full) <= full_until and
              not Enum.any?(full_at, &within?(&1, node)) ->
            {[full | parts], [item(node, length(items) + 1, :full) | items], used + cost(full),
             sources, [node | full_at]}

          used + cost(short) <= limit ->
            {[short | parts], [item(node, length(items) + 1, :signature) | items],
             used + cost(short), sources, full_at}

          true ->
            {parts, items, used, sources, full_at}
        end
      end)

    packed_ids = Enum.map(items, & &1.node.id)

    {parts, items, _used} =
      packed_ids
      |> Store.edges_from(["implements"])
      |> Enum.map(& &1.to_id)
      |> Enum.uniq()
      |> Enum.map(&Trail.own_node(repo_id, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{&1.path, &1.start_line})
      |> Enum.reduce({parts, items, used}, fn section, {parts, items, used} ->
        {source, _} = source_of(path, section, %{})

        part =
          "#{section.path}:#{section.start_line}-#{section.end_line}\n" <>
            String.slice(source, 0, @excerpt) <> "\n"

        if used + cost(part) <= limit,
          do:
            {[part | parts], [item(section, length(items) + 1, :section) | items],
             used + cost(part)},
          else: {parts, items, used}
      end)

    text = parts |> Enum.reverse() |> Enum.join("\n") |> fit(limit)
    {text, Enum.reverse(items)}
  end

  # Parts are joined by a blank line; trimming the last newline keeps the
  # count honest, and nothing ever exceeds the budget.
  defp fit(text, limit) do
    text = String.trim_trailing(text, "\n")
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit)
  end

  defp source_of(path, node, cache) do
    case Map.fetch(cache, node.path) do
      {:ok, lines} ->
        {slice(lines, node), cache}

      :error ->
        lines =
          case Files.read(path, node.path) do
            {:ok, text} -> String.split(text, ~r/\r?\n/)
            _error -> []
          end

        {slice(lines, node), Map.put(cache, node.path, lines)}
    end
  end

  defp slice(lines, node),
    do: lines |> Enum.slice((node.start_line - 1)..(node.end_line - 1)//1) |> Enum.join("\n")

  # A part costs its own length and the newline that joins it to the next, so
  # the packed text never has to be cut to fit the budget.
  defp cost(part), do: String.length(part) + 1

  defp within?(inner, outer),
    do:
      inner.path == outer.path and outer.start_line <= inner.start_line and
        inner.end_line <= outer.end_line

  defp item(node, rank, form), do: %{node: Map.take(node, @summary), rank: rank, form: form}
end
