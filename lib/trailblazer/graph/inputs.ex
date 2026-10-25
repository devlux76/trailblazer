defmodule Trailblazer.Graph.Inputs do
  @moduledoc false
  @version 1
  def version, do: @version
  def family(lang) when lang in ["c", "cpp"], do: "c-family"
  def family(lang), do: lang

  def split_target(target) do
    [name | spec] = target |> String.split("#") |> Enum.reverse()
    [spec |> Enum.reverse() |> Enum.join("#"), name]
  end

  def suffixes(path),
    do:
      for(
        drop <- 0..(length(Path.split(path)) - 1),
        do: path |> Path.split() |> Enum.drop(drop) |> Path.join()
      )

  def index(graph) do
    imports =
      graph.refs
      |> Enum.filter(&(&1.kind == "references" and String.contains?(&1.target, "#")))
      |> Enum.group_by(&{&1.path, List.last(split_target(&1.target))})

    docs =
      for n <- graph.nodes,
          n.kind == "doc_section",
          suffix <- suffixes(n.path),
          do: {suffix <> "#" <> String.replace_prefix(n.qualified, n.path <> "#", ""), n}

    files =
      for path <- Enum.uniq_by(graph.nodes, & &1.path) |> Enum.map(& &1.path),
          suffix <- suffixes(path),
          do: {suffix, path}

    Map.merge(graph, %{
      by_key: Map.new(graph.nodes, &{&1.key, &1}),
      by_qualified: Enum.group_by(graph.nodes, & &1.qualified),
      by_name: Enum.group_by(graph.nodes, &{family(&1.lang), &1.name}),
      by_path: Enum.group_by(graph.nodes, & &1.path),
      imports: imports,
      doc_suffixes: Enum.group_by(docs, &elem(&1, 0), &elem(&1, 1)),
      file_suffixes: Enum.group_by(files, &elem(&1, 0), &elem(&1, 1)),
      paths: MapSet.new(Enum.map(graph.nodes, & &1.path) ++ Enum.map(graph.refs, & &1.path))
    })
  end

  def get(graph, {:source, key}), do: graph.by_key[key]
  def get(graph, {:qualified, key}), do: Map.get(graph.by_qualified, key, [])
  def get(graph, {:name, family, name}), do: Map.get(graph.by_name, {family, name}, [])
  def get(graph, {:nodes, path}), do: Map.get(graph.by_path, path, [])
  def get(graph, {:imports, path, name}), do: Map.get(graph.imports, {path, name}, [])
  def get(graph, {:exists, path}), do: MapSet.member?(graph.paths, path)
  def get(graph, {:doc_suffix, key}), do: Map.get(graph.doc_suffixes, key, [])
  def get(graph, {:file_suffix, key}), do: Map.get(graph.file_suffixes, key, [])

  def valid_token?({:name, family, name}),
    do: (is_binary(family) or is_nil(family)) and is_binary(name)

  def valid_token?({:imports, path, name}), do: is_binary(path) and is_binary(name)

  def valid_token?({kind, key})
      when kind in [:source, :qualified, :nodes, :exists, :doc_suffix, :file_suffix],
      do: is_binary(key)

  def valid_token?(_), do: false
  def encode(token), do: :erlang.term_to_binary(token, [:deterministic])
  def decode(token), do: :erlang.binary_to_term(token, [:safe])

  # Compare file-local contributions, never hashes/body text of unaffected definitions.
  def changed(before, after_graph) do
    a = contributions(index(before))
    b = contributions(index(after_graph))

    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(a, &1) != Map.get(b, &1)))
  end

  defp contributions(g) do
    Enum.concat([
      Enum.map(g.by_key, fn {k, n} -> {{:source, k}, {n.id, n.path, n.lang}} end),
      Enum.map(g.by_qualified, fn {k, ns} -> {{:qualified, k}, project(ns)} end),
      Enum.map(g.by_name, fn {{f, n}, ns} -> {{:name, f, n}, project(ns)} end),
      Enum.map(g.by_path, fn {p, ns} -> {{:nodes, p}, project(ns)} end),
      Enum.map(g.imports, fn {{p, n}, rs} ->
        {{:imports, p, n}, rs |> Enum.map(&{&1.path, &1.target}) |> Enum.uniq() |> Enum.sort()}
      end),
      Enum.map(g.paths, &{{:exists, &1}, true}),
      Enum.map(g.doc_suffixes, fn {k, ns} -> {{:doc_suffix, k}, project(ns)} end),
      Enum.map(g.file_suffixes, fn {k, ps} -> {{:file_suffix, k}, Enum.sort(ps)} end)
    ])
    |> Map.new()
  end

  defp project(ns) do
    ns
    |> Enum.map(
      &{&1.id, &1.key, &1.lang, &1.kind, &1.name, &1.qualified, &1.path,
       String.contains?(&1.signature || "", "export default")}
    )
    |> Enum.sort()
  end

  def tables(graph) do
    g = index(graph)
    ref_counts = Enum.frequencies_by(g.refs, & &1.path)

    %{
      imports: for({{p, n}, rs} <- g.imports, r <- rs, do: [p, n, r.target]) |> Enum.uniq(),
      paths:
        for(p <- g.paths, do: [p, length(Map.get(g.by_path, p, [])), Map.get(ref_counts, p, 0)]),
      file_suffixes: for({s, ps} <- g.file_suffixes, p <- ps, do: [s, p]),
      doc_suffixes: for({s, ns} <- g.doc_suffixes, n <- ns, do: [s, n.id, n.path])
    }
  end
end
