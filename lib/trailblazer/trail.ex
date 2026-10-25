defmodule Trailblazer.Trail do
  @moduledoc """
  The trail: what a model should read for a request, packed to a budget.

  Seeds, in order: the definitions in `opts[:files]`; definitions the request
  names (words matched against names and qualified names); definitions at the
  `path:line` places the request quotes (stack traces, compiler errors); and
  the 8 nearest by vector.

  The walk is a personalized PageRank over the nodes within 3 hops of a seed,
  both edge directions, not through an uncertain call whose site resolved to
  more than 2 candidates, the restart mass split evenly over the seeds, damping
  0.85, 30 iterations, edge weight 1.0, uncertain 0.3, contains 0.5. A node's
  rank is its PageRank times `0.5 + 0.5 * similarity` to the request (0.5 for
  every node when vectors are unavailable), and a node that is not a seed is
  dropped below a similarity of 0.25.

  Packing, in rank order: full source until 60% of the budget is used, then
  signatures; then the design sections the packed definitions implement, as
  excerpts of at most 600 characters, in what remains. Each item is headed
  `path:start-end`. A budget is in tokens of 4 characters.

  `opts[:omit]` names files the reader already has in full (the loop's task
  files): nothing from them is packed again, though they still seed and rank.
  """

  alias Trailblazer.{Config, Embed, Files, Store, Vectors}

  defstruct text: "", items: [], tokens: 0, notes: []

  @type t :: %__MODULE__{
          text: String.t(),
          items: [map()],
          tokens: non_neg_integer(),
          notes: [String.t()]
        }

  @hops 3
  @max_targets 2
  @damping 0.85
  @iterations 30
  @nearest 8
  @floor 0.25
  @full_share 0.6
  @excerpt 600
  @summary ~w(id kind qualified path start_line end_line signature stale)a

  @spec build(Path.t(), String.t(), keyword()) :: t() | {:error, term()}
  def build(repo, request, opts \\ []) do
    with {:ok, repo_id, path} <- repo(repo) do
      files = Keyword.get(opts, :files, [])
      fresh(path, files, opts)

      {query_vector, embedded?} = query_vector(request, opts)
      {near, near_ok?} = nearest(repo_id, path, query_vector, opts)
      vectors_ok? = embedded? and near_ok?
      seeds = seeds(repo_id, request, files, near)

      graph = neighbourhood(repo_id, seeds)

      {sims, vectors_ok?} =
        similarities(path, query_vector, vectors_ok?, graph, opts)

      ranked = rank(graph, seeds, sims, vectors_ok?)
      budget = Keyword.get(opts, :budget, Config.get(:trail_tokens))
      omit = opts |> Keyword.get(:omit, []) |> MapSet.new()
      {text, items} = pack(repo_id, path, ranked, budget, omit)

      %__MODULE__{
        text: text,
        items: items,
        tokens: tokens(text),
        notes: if(vectors_ok?, do: [], else: ["no vectors"])
      }
    end
  end

  ## Seeds

  defp seeds(repo_id, request, files, near) do
    in_files = Enum.flat_map(files, &Store.nodes_in_file(repo_id, &1))
    named = request |> words() |> Enum.flat_map(&named(repo_id, &1))

    placed =
      request
      |> places()
      |> Enum.flat_map(fn {file, line} -> List.wrap(enclosing(repo_id, file, line)) end)

    (in_files ++ named ++ placed ++ near)
    |> Enum.reject(&doc?/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(& &1.id)
  end

  # The words of the request that name code: identifier-shaped ones (camelCase,
  # snake_case, Qualified.names, name/2, ready?) and anything in backticks.
  # Plain words ("add a new kind of weather") are left to the vectors; seeding
  # them by name pulled in every function called `add` (acceptance run, T17).
  defp words(request) do
    quoted = ~r/`([^`]+)`/u |> Regex.scan(request) |> Enum.map(&List.last/1)

    shaped =
      ~r/[A-Za-z_][\w.]*[?!]?(?:\/\d+)?/u
      |> Regex.scan(request)
      |> List.flatten()
      |> Enum.filter(&identifier?/1)

    Enum.uniq(quoted ++ shaped)
  end

  defp identifier?(word) do
    String.contains?(word, ["_", ".", "/"]) or String.match?(word, ~r/[?!\d]/u) or
      String.match?(word, ~r/^.+[A-Z]/u) or String.match?(word, ~r/^[A-Z][a-z]+[A-Z]/u)
  end

  defp named(repo_id, word) do
    (Store.nodes_by_qualified(repo_id, word) ++ Store.nodes_by_name(repo_id, word))
    |> case do
      [] ->
        last = word |> String.split(".") |> List.last() |> String.replace(~r{/\d+$}, "")

        Store.nodes_by_name(repo_id, last)
        |> Enum.filter(&String.starts_with?(&1.qualified, word <> "/"))

      found ->
        found
    end
  end

  defp places(request) do
    ~r/([\w.\/-]+\.[A-Za-z]+):(\d+)/u
    |> Regex.scan(request)
    |> Enum.map(fn [_, file, line] ->
      {String.replace_prefix(file, "./", ""), String.to_integer(line)}
    end)
  end

  # The 8 nearest by vector, and whether the vectors answered at all.
  defp nearest(_repo_id, _path, nil, _opts), do: {[], false}

  defp nearest(repo_id, path, vector, opts) do
    case vectors(opts).nearest(path, vector, @nearest, opts) do
      {:ok, hits} ->
        {Enum.flat_map(hits, fn {id, _score} -> List.wrap(own_node(repo_id, id)) end), true}

      _down ->
        {[], false}
    end
  end

  defp query_vector(request, opts) do
    case Keyword.get(opts, :embed, Embed).query(request, opts) do
      {:ok, vector} -> {vector, true}
      _down -> {nil, false}
    end
  end

  ## Walk and rank

  defp similarities(_path, nil, _ok?, _graph, _opts), do: {%{}, false}
  defp similarities(_path, _vector, false, _graph, _opts), do: {%{}, false}

  defp similarities(path, vector, true, graph, opts) do
    ids = Map.keys(graph)

    case vectors(opts).scores(path, vector, ids, opts) do
      {:ok, scores} -> {scores, true}
      _down -> {%{}, false}
    end
  end

  defp rank(_graph, [], _sims, _ok?), do: []

  defp rank(graph, seeds, sims, vectors_ok?) do
    pagerank = pagerank(graph, seeds)
    seed? = MapSet.new(seeds)

    pagerank
    |> Enum.flat_map(fn {id, pr} ->
      sim = if vectors_ok?, do: Map.get(sims, id, 0.5), else: 0.5

      if MapSet.member?(seed?, id) or sim >= @floor,
        do: [{id, pr * (0.5 + 0.5 * sim)}],
        else: []
    end)
    |> Enum.sort_by(fn {id, rank} -> {-rank, id} end)
    |> Enum.map(&elem(&1, 0))
  end

  # The nodes within 3 hops of a seed, with their weighted neighbours (both
  # directions). Nodes of other repositories never enter (D5); document
  # sections take part in the walk but are packed only as sections. A call that
  # resolved to more than 2 candidates is not walked: on the opencode repository
  # such fan-out made the walk reach 70% of the graph, and leaving it out kept
  # recall on 80 commits from its history (12/150 against 11/150) at a ninth of
  # the work.
  defp neighbourhood(repo_id, seeds) do
    Enum.reduce(1..@hops, {Map.new(seeds, &{&1, %{}}), seeds}, fn _hop, {graph, frontier} ->
      edges = Store.adjacent_edges(repo_id, frontier, max_targets: @max_targets)

      Enum.reduce(edges, {graph, []}, fn edge, {graph, next} ->
        w = weight(edge)
        new = Enum.reject([edge.from_id, edge.to_id], &Map.has_key?(graph, &1))

        graph =
          graph
          |> Map.update(
            edge.from_id,
            %{edge.to_id => w},
            &Map.update(&1, edge.to_id, w, fn v -> max(v, w) end)
          )
          |> Map.update(
            edge.to_id,
            %{edge.from_id => w},
            &Map.update(&1, edge.from_id, w, fn v -> max(v, w) end)
          )

        {graph, new ++ next}
      end)
    end)
    |> elem(0)
  end

  defp weight(%{kind: "contains"} = edge), do: 0.5 * if(edge.uncertain, do: 0.3, else: 1.0)
  defp weight(%{uncertain: true}), do: 0.3
  defp weight(_edge), do: 1.0

  defp pagerank(graph, seeds) do
    restart = 1.0 / length(seeds)
    teleport = Map.new(seeds, &{&1, restart})
    start = Map.new(graph, fn {id, _} -> {id, Map.get(teleport, id, 0.0)} end)

    # Gather each destination's contributions once. Scattering into a new
    # persistent map for every edge on all 30 iterations dominates dense
    # graphs. Keep each source's original total and order, so the arithmetic
    # and weighted PageRank remain the same.
    {incoming, dangling} =
      Enum.reduce(graph, {Map.new(graph, fn {id, _} -> {id, []} end), []}, fn
        {id, neighbours}, {incoming, dangling} ->
          total = neighbours |> Map.values() |> Enum.sum()

          if total == 0 do
            {incoming, [id | dangling]}
          else
            incoming =
              Enum.reduce(neighbours, incoming, fn {to, w}, acc ->
                Map.update!(acc, to, &[{id, w, total} | &1])
              end)

            {incoming, dangling}
          end
      end)

    incoming = Map.new(incoming, fn {id, links} -> {id, Enum.reverse(links)} end)
    dangling = Enum.reverse(dangling)

    Enum.reduce(1..@iterations, start, fn _i, ranks ->
      dangling_mass = Enum.reduce(dangling, 0.0, &(&2 + Map.get(ranks, &1, 0.0)))

      Map.new(incoming, fn {id, links} ->
        spread =
          Enum.reduce(links, 0.0, fn {from, w, total}, mass ->
            mass + Map.get(ranks, from, 0.0) * w / total
          end)

        back = (1 - @damping + @damping * dangling_mass) * Map.get(teleport, id, 0.0)
        {id, back + @damping * spread}
      end)
    end)
  end

  ## Packing

  defp pack(repo_id, path, ranked, budget, omit) do
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
      |> Enum.reject(&(is_nil(&1) or doc?(&1) or file_node?(&1) or MapSet.member?(omit, &1.path)))
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
      |> Enum.map(&own_node(repo_id, &1))
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

  defp tokens(text), do: div(String.length(text) + 3, 4)

  ## Helpers

  defp doc?(%{kind: "doc_section"}), do: true
  defp doc?(%{lang: "markdown"}), do: true
  defp doc?(_node), do: false

  # The node of a whole file (H1): its signature is the file's first line, and
  # it holds everything in the file, so it would only spend the budget.
  defp file_node?(%{kind: "module", qualified: path, path: path}), do: true
  defp file_node?(_node), do: false

  defp enclosing(repo_id, file, line) do
    repo_id
    |> Store.nodes_in_file(file)
    |> Enum.filter(&(&1.start_line <= line and line <= &1.end_line))
    |> Enum.reduce(nil, fn
      node, nil ->
        node

      node, best ->
        if node.end_line - node.start_line <= best.end_line - best.start_line,
          do: node,
          else: best
    end)
  end

  defp own_node(repo_id, id) do
    case Store.node(id) do
      %{repo_id: ^repo_id} = node -> node
      _other -> nil
    end
  end

  defp vectors(opts), do: Keyword.get(opts, :vectors, Vectors)

  defp repo(repo) when is_binary(repo) do
    with {:ok, canonical} <- Files.canonical_path(repo),
         canonical = Path.expand(canonical),
         %{id: id} <- Enum.find(Store.repos(), &(&1.path == canonical)) do
      {:ok, id, canonical}
    else
      _ -> {:error, :not_watched}
    end
  end

  defp repo(_other), do: {:error, :not_watched}

  defp fresh(_path, [], _opts), do: :ok

  defp fresh(path, files, opts) do
    indexer = Keyword.get(opts, :indexer, Trailblazer.Indexer)

    if Code.ensure_loaded?(indexer) and function_exported?(indexer, :ensure_fresh, 2),
      do: indexer.ensure_fresh(path, files)

    :ok
  end
end
