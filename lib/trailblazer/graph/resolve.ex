defmodule Trailblazer.Graph.Resolve do
  @moduledoc "Resolves one coherent repository snapshot; unresolved references stay in the store."
  alias Trailblazer.Store
  alias Trailblazer.Graph.Inputs
  @extensions ~w(.ts .tsx .js .jsx .mjs .cjs)

  def edges(repo_id) do
    resolve(index(Store.graph_snapshot(repo_id)))
  end

  @doc "Full resolution plus source-scoped lookup coverage for one durable revision."
  def tracked(repo_id) do
    graph = index(Store.resolution_snapshot(repo_id))
    trace = :ets.new(:resolve_reads, [:bag, :private])

    try do
      edges = resolve(Map.put(graph, :trace, trace))

      dependencies =
        Enum.reduce(:ets.tab2list(trace), Map.new(graph.sources, &{&1, []}), fn {owner, token},
                                                                                acc ->
          Map.update(acc, owner, [token], &[token | &1])
        end)
        |> Map.new(fn {owner, tokens} -> {owner, Enum.sort(tokens)} end)

      %{
        revision: graph.revision,
        version: Inputs.version(),
        sources: graph.sources,
        edges: edges,
        dependencies: dependencies,
        full: true,
        stats: %{
          mode: :full,
          sources: length(graph.sources),
          refs: length(graph.refs),
          fallback: nil
        },
        lookups:
          if(graph.resolution.lookup_version == Inputs.version(),
            do: nil,
            else: Inputs.tables(graph)
          )
      }
    after
      :ets.delete(trace)
    end
  end

  @doc "Resolve the durable affected set, or rebuild full coverage when unsafe/too broad."
  def next(repo_id) do
    case Store.resolution_selected(repo_id, &selected/2) do
      {:fallback, reason} ->
        result = tracked(repo_id)
        Map.update!(result, :stats, &Map.put(&1, :fallback, reason))

      result ->
        result
    end
  end

  defp selected(plan, fetch) do
    trace = :ets.new(:resolve_reads, [:bag, :private])
    cache = :ets.new(:resolve_cache, [:set, :private])
    :ets.insert(cache, {:rows, 0})
    graph = Map.merge(plan, %{trace: trace, cache: cache, fetch: fetch})

    try do
      edges = resolve(graph)

      deps =
        Enum.reduce(:ets.tab2list(trace), Map.new(plan.sources, &{&1, []}), fn {owner, token},
                                                                               acc ->
          Map.update!(acc, owner, &[token | &1])
        end)

      %{
        revision: plan.revision,
        version: Inputs.version(),
        sources: plan.sources,
        edges: edges,
        dependencies: deps,
        full: false,
        stats: %{
          mode: :incremental,
          sources: length(plan.sources),
          refs: length(plan.refs),
          lookups: :ets.info(cache, :size) - 1,
          rows: :ets.lookup_element(cache, :rows, 2)
        }
      }
    catch
      {:resolve_fallback, reason} -> {:fallback, reason}
    after
      :ets.delete(trace)
      :ets.delete(cache)
    end
  end

  defp resolve(graph) do
    Enum.flat_map(graph.refs, fn ref ->
      graph = Map.put(graph, :owner, ref.from_key)

      case if(is_nil(ref.from_key), do: nil, else: lookup(graph, {:source, ref.from_key})) do
        nil ->
          []

        from ->
          candidates =
            candidates(graph, from, ref)
            |> Enum.uniq_by(& &1.id)
            |> Enum.sort_by(&{&1.path, &1.qualified, &1.id})

          fallback =
            from.lang !=
              "elixir" and ref.kind not in ["contains", "implements", "imports"] and
              not String.contains?(ref.target, "#") and
              not Enum.any?(candidates, &(&1.path == from.path and &1.qualified == ref.target))

          imported = lookup(graph, {:imports, from.path, ref.target}) != []
          uncertain = ref.ambiguous or length(candidates) != 1 or (fallback and not imported)

          candidates
          |> Enum.take(8)
          |> Enum.map(fn to ->
            %{
              from_id: from.id,
              to_id: to.id,
              kind: ref.kind,
              line: ref.line,
              uncertain: uncertain
            }
          end)
      end
    end)
    |> Enum.uniq()
  end

  def stale_citations(repo_id) do
    graph = index(Store.graph_snapshot(repo_id))
    Enum.filter(graph.refs, &(&1.kind == "implements" and citation(graph, &1.target) == []))
  end

  defp index(graph), do: Inputs.index(graph)
  defp family(lang), do: Inputs.family(lang)

  defp lookup(graph, token) do
    if table = Map.get(graph, :trace), do: :ets.insert(table, {graph.owner, token})

    if fetch = Map.get(graph, :fetch) do
      case :ets.lookup(graph.cache, token) do
        [{_, value}] ->
          value

        [] ->
          value = fetch.(token, graph.budget + 1)
          count = if is_list(value), do: length(value), else: if(is_map(value), do: 1, else: 0)

          if :ets.update_counter(graph.cache, :rows, count) > graph.budget or
               :ets.info(graph.cache, :size) > graph.budget,
             do: throw({:resolve_fallback, :lookup_volume})

          :ets.insert(graph.cache, {token, value})
          value
      end
    else
      Inputs.get(graph, token)
    end
  end

  defp citation(graph, target) do
    case Enum.filter(lookup(graph, {:qualified, target}), &(&1.kind == "doc_section")) do
      [] -> lookup(graph, {:doc_suffix, target})
      exact -> exact
    end
  end

  defp candidates(graph, _, %{kind: "implements", target: target}), do: citation(graph, target)

  defp candidates(graph, from, %{kind: "contains", target: target}),
    do: Enum.filter(lookup(graph, {:qualified, target}), &(&1.path == from.path))

  defp candidates(graph, %{lang: "elixir"}, ref) do
    target = if is_integer(ref.arity), do: ref.target <> "/#{ref.arity}", else: ref.target
    Enum.filter(lookup(graph, {:qualified, target}), &(&1.lang == "elixir"))
  end

  defp candidates(graph, %{lang: lang} = from, %{kind: "imports", target: spec})
       when lang in ["c", "cpp"] do
    local = normalize(Path.join(Path.dirname(from.path), spec))
    root = normalize(spec)
    exact = Enum.find([local, root], &(&1 && lookup(graph, {:exists, &1})))

    paths =
      if exact,
        do: [exact],
        else: if(root, do: lookup(graph, {:file_suffix, root}), else: [])

    Enum.flat_map(paths, fn path ->
      Enum.filter(
        lookup(graph, {:nodes, path}),
        &(&1.kind == "module" and &1.qualified == path)
      )
    end)
  end

  defp candidates(graph, from, %{kind: "imports", target: spec}) do
    case module_file(graph, from.path, from.lang, spec) do
      nil ->
        []

      path ->
        Enum.filter(
          lookup(graph, {:nodes, path}),
          &(&1.kind == "module" and &1.qualified == path)
        )
    end
  end

  defp candidates(graph, from, ref) do
    if String.contains?(ref.target, "#") do
      [spec, name] = split_target(ref.target)
      module_member(graph, from.path, from.lang, spec, name, MapSet.new())
    else
      case lookup(graph, {:imports, from.path, ref.target}) do
        [_ | _] = imports ->
          Enum.flat_map(imports, fn r ->
            [spec, name] = split_target(r.target)
            module_member(graph, from.path, from.lang, spec, name, MapSet.new())
          end)

        [] ->
          local =
            Enum.filter(lookup(graph, {:qualified, ref.target}), &(&1.path == from.path))

          if local == [],
            do: lookup(graph, {:name, family(from.lang), ref.target}),
            else: local
      end
    end
  end

  defp module_member(graph, path, lang, spec, name, seen) do
    file = module_file(graph, path, lang, spec)
    key = {file, name}

    if is_nil(file) or MapSet.member?(seen, key) do
      []
    else
      seen = MapSet.put(seen, key)

      direct =
        Enum.filter(lookup(graph, {:nodes, file}), fn n ->
          n.qualified == name or n.name == name or
            (name == "default" and String.contains?(n.signature || "", "export default"))
        end)

      forwarded =
        lookup(graph, {:imports, file, name})
        |> Enum.flat_map(fn r ->
          [next, export] = split_target(r.target)
          module_member(graph, r.path, lang, next, export, seen)
        end)

      direct ++ forwarded
    end
  end

  defp module_file(graph, path, lang, spec),
    do: Enum.find(module_paths(path, lang, spec), &lookup(graph, {:exists, &1}))

  defp module_paths(path, "python", spec) do
    dots = byte_size(spec) - byte_size(String.trim_leading(spec, "."))
    tail = spec |> String.trim_leading(".") |> String.replace(".", "/")

    bases =
      if dots == 0,
        do: [Path.join(Path.dirname(path), tail), tail],
        else: [Path.join([Path.dirname(path) | List.duplicate("..", dots - 1)] ++ [tail])]

    Enum.flat_map(bases, fn base ->
      case normalize(base) do
        nil -> []
        normalized -> [normalized <> ".py", Path.join(normalized, "__init__.py")]
      end
    end)
    |> Enum.uniq()
  end

  defp module_paths(path, _, spec) do
    if String.starts_with?(spec, ".") do
      case normalize(Path.join(Path.dirname(path), spec)) do
        nil ->
          []

        base ->
          root = if Path.extname(base) in @extensions, do: Path.rootname(base), else: base

          [base] ++
            Enum.map(@extensions, &(root <> &1)) ++
            Enum.map(@extensions, &(Path.join(base, "index") <> &1))
      end
    else
      []
    end
  end

  defp normalize(path) do
    expanded = Path.expand(path, "/repo")
    if String.starts_with?(expanded, "/repo/"), do: Path.relative_to(expanded, "/repo"), else: nil
  end

  defp split_target(target), do: Inputs.split_target(target)
end
