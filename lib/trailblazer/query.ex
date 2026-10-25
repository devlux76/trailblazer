defmodule Trailblazer.Query do
  @moduledoc """
  The questions the core answers without a model: where a name is declared,
  who uses a definition, what a change to it affects, the text of a range of
  lines, and a search over names, text and vectors.

  Every question takes the repository's path first and finds it among the
  registered repositories by its canonical path; one that is not registered is
  `{:error, :not_watched}`. A question that reads files first asks the indexer
  to bring them up to date (`opts[:indexer]`, default `Trailblazer.Indexer`).

  Answers come from the Store's graph; vector hits are mapped back through the
  Store, so a node is always reported where SQLite says it is (E6), and an id
  that is not one of this repository's nodes is dropped (D5).
  """

  alias Trailblazer.{Config, Embed, Files, Store, Vectors}

  @users ~w(calls references uses imports tests)
  @uses ~w(calls references uses imports aliases tests implements)
  @summary ~w(id kind qualified path start_line end_line signature stale)a

  @type summary :: %{
          id: integer(),
          kind: String.t(),
          qualified: String.t(),
          path: String.t(),
          start_line: integer(),
          end_line: integer(),
          signature: String.t(),
          stale: boolean()
        }

  @doc """
  The definitions a name or a position refers to. A name is a bare name
  (`"put"`), a qualified name with or without its arity (`"Mini.Store.put/2"`,
  `"Mini.Store.put"`), or a JS/Python name (`"saveHikes"`). A position
  `{path, line}` gives the definitions the references on that line lead to.
  """
  @spec where_declared(Path.t(), String.t() | {Path.t(), pos_integer()}, keyword()) ::
          [summary()] | {:error, term()}
  def where_declared(repo, name_or_position, opts \\ []) do
    with {:ok, repo_id, path} <- repo(repo) do
      case name_or_position do
        {file, line} ->
          fresh(path, [file], opts)
          positioned(repo_id, file, line)

        name when is_binary(name) ->
          named(repo_id, name)
      end
      |> Enum.map(&summary/1)
    end
  end

  @doc "Who uses a definition (an id or a name): one entry per edge into it."
  @spec who_uses(Path.t(), integer() | String.t(), keyword()) :: [map()] | {:error, term()}
  def who_uses(repo, node_ref, _opts \\ []) do
    with {:ok, repo_id, _path} <- repo(repo) do
      ids = targets(repo_id, node_ref)

      ids
      |> Store.edges_to(@uses)
      |> Enum.flat_map(fn edge ->
        with %{} = node <- own_node(repo_id, edge.from_id),
             %{} = target <- own_node(repo_id, edge.to_id) do
          # a name can stand for several definitions; each use says which
          [
            %{
              node: summary(node),
              target: summary(target),
              kind: edge.kind,
              line: edge.line,
              uncertain: edge.uncertain
            }
          ]
        else
          _other -> []
        end
      end)
      |> Enum.sort_by(&{&1.node.path, &1.line || 0, &1.node.id, &1.target.id})
    end
  end

  @doc """
  What a change to a definition affects: its users, their users and so on to
  `depth`, breadth first, each with the distance and the kind of the edge it
  was reached by. A node is visited once, by id, so cycles end the walk.
  """
  @spec impact_of(Path.t(), integer() | String.t(), pos_integer(), keyword()) ::
          [map()] | {:error, term()}
  def impact_of(repo, node_ref, depth \\ 3, _opts \\ []) do
    with {:ok, repo_id, _path} <- repo(repo) do
      start = targets(repo_id, node_ref)
      walk(repo_id, start, MapSet.new(start), 1, max(depth, 0), [])
    end
  end

  defp walk(_repo_id, [], _seen, _distance, _depth, found), do: Enum.reverse(found)

  defp walk(_repo_id, _frontier, _seen, distance, depth, found) when distance > depth,
    do: Enum.reverse(found)

  defp walk(repo_id, frontier, seen, distance, depth, found) do
    {next, seen, found} =
      frontier
      |> Store.edges_to(@users)
      |> Enum.sort_by(&{&1.from_id, &1.id})
      |> Enum.reduce({[], seen, found}, fn edge, {next, seen, found} ->
        node =
          if MapSet.member?(seen, edge.from_id), do: nil, else: own_node(repo_id, edge.from_id)

        if node do
          item = %{
            node: summary(node),
            distance: distance,
            via: edge.kind,
            uncertain: edge.uncertain
          }

          {[node.id | next], MapSet.put(seen, node.id), [item | found]}
        else
          {next, seen, found}
        end
      end)

    walk(repo_id, Enum.reverse(next), seen, distance + 1, depth, found)
  end

  @doc "Lines `first..last` of a file in the repository (a range past the end stops there)."
  @spec read_range(Path.t(), Path.t(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, :outside_repo | :enoent | :bad_range | term()}
  def read_range(repo, file, first, last, opts \\ [])

  def read_range(repo, file, first, last, opts)
      when is_integer(first) and is_integer(last) and first >= 1 and last >= first do
    with {:ok, _repo_id, path} <- repo(repo),
         :ok <- fresh(path, [file], opts),
         {:ok, text} <- Files.read(path, file) do
      # a file that ends in a newline has no line after it
      lines = text |> String.split(~r/\r?\n/) |> drop_last_empty()
      {:ok, lines |> Enum.slice((first - 1)..(last - 1)//1) |> Enum.join("\n")}
    end
  end

  def read_range(_repo, _file, _first, _last, _opts), do: {:error, :bad_range}

  defp drop_last_empty(lines) do
    if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
  end

  @doc """
  Definitions matching `text`: exact names first, then vector hits, then
  definitions holding a literal match of the text. Each hit is
  `%{node, score, via: :exact | :vector}`. With the embedder or Qdrant down
  the names and the text still answer.
  """
  @spec search(Path.t(), String.t(), pos_integer(), keyword()) :: [map()] | {:error, term()}
  def search(repo, text, limit \\ 10, opts \\ []) do
    with {:ok, repo_id, path} <- repo(repo) do
      names = Enum.map(named(repo_id, String.trim(text)), &{&1, 1.0, :exact})
      vectors = vector_hits(repo_id, path, text, limit, opts)
      literal = Enum.map(literal_hits(repo_id, path, text), &{&1, 0.5, :exact})

      (names ++ vectors ++ literal)
      |> Enum.uniq_by(fn {node, _score, _via} -> node.id end)
      |> Enum.take(limit)
      |> Enum.map(fn {node, score, via} -> %{node: summary(node), score: score, via: via} end)
    end
  end

  ## Names and positions

  defp named(repo_id, name) do
    exact = Store.nodes_by_qualified(repo_id, name) ++ Store.nodes_by_name(repo_id, name)

    case exact do
      [] ->
        last = name |> String.split(".") |> List.last() |> String.replace(~r{/\d+$}, "")

        Store.nodes_by_name(repo_id, last)
        |> Enum.filter(&(&1.qualified == name or String.starts_with?(&1.qualified, name <> "/")))

      found ->
        found
    end
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{&1.path, &1.start_line})
  end

  defp positioned(repo_id, file, line) do
    ids = repo_id |> Store.nodes_in_file(file) |> Enum.map(& &1.id)

    ids
    |> Store.edges_from(@uses)
    |> Enum.filter(&(&1.line == line))
    |> Enum.map(&own_node(repo_id, &1.to_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{&1.path, &1.start_line})
  end

  defp targets(repo_id, id) when is_integer(id),
    do: if(own_node(repo_id, id), do: [id], else: [])

  defp targets(repo_id, name) when is_binary(name), do: Enum.map(named(repo_id, name), & &1.id)
  defp targets(_repo_id, _other), do: []

  defp own_node(repo_id, id) do
    case Store.node(id) do
      %{repo_id: ^repo_id} = node -> node
      _other -> nil
    end
  end

  ## Search

  defp vector_hits(repo_id, path, text, limit, opts) do
    embed = Keyword.get(opts, :embed, Embed)
    vectors = Keyword.get(opts, :vectors, Vectors)

    # The embedder and Qdrant are asked with no client timeout; one backstop
    # guards both, and a search that loses it answers by name and text only.
    lookup = fn ->
      with {:ok, vector} <- embed.query(text, opts),
           do: vectors.nearest(path, vector, limit, opts)
    end

    limit_ms = {:ms, Config.get(:backstop_search_ms)}

    with {:ok, {:ok, hits}} <-
           Trailblazer.Backstop.guard(:search, path, limit_ms, fn -> %{text: text} end, lookup) do
      Enum.flat_map(hits, fn {id, score} ->
        case own_node(repo_id, id) do
          nil -> []
          node -> [{node, score, :vector}]
        end
      end)
    else
      _down -> []
    end
  end

  # A literal search with ripgrep. The text is given after -e and the paths
  # come back NUL-terminated, so neither a leading dash, shell syntax nor a
  # colon in a file name is read as anything but text (A9, A10).
  defp literal_hits(_repo_id, _path, ""), do: []

  defp literal_hits(repo_id, path, text) do
    args = [
      "--fixed-strings",
      "--line-number",
      "--no-heading",
      "--with-filename",
      "--null",
      "--max-count",
      "5",
      "--no-require-git",
      "-e",
      text,
      "--",
      "."
    ]

    case System.cmd("rg", args, cd: path, stderr_to_stdout: false) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&hit/1)
        |> Enum.flat_map(fn {file, line} -> List.wrap(enclosing(repo_id, file, line)) end)
        |> Enum.uniq_by(& &1.id)

      _none ->
        []
    end
  end

  defp hit(row) do
    with [file, rest] <- String.split(row, <<0>>, parts: 2),
         [line, _text] <- String.split(rest, ":", parts: 2),
         {line, ""} <- Integer.parse(line) do
      [{String.replace_prefix(file, "./", ""), line}]
    else
      _other -> []
    end
  end

  # The narrowest definition holding the line; of those sharing it, the last
  # listed (C4 in the register).
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

  ## Repositories, freshness, summaries

  defp repo(repo) when is_binary(repo) do
    with {:ok, canonical} <- Files.canonical_path(repo) do
      canonical = Path.expand(canonical)

      case Enum.find(Store.repos(), &(&1.path == canonical)) do
        %{id: id} -> {:ok, id, canonical}
        nil -> {:error, :not_watched}
      end
    else
      _error -> {:error, :not_watched}
    end
  end

  defp repo(_other), do: {:error, :not_watched}

  defp fresh(path, files, opts) do
    indexer = Keyword.get(opts, :indexer, Trailblazer.Indexer)

    if Code.ensure_loaded?(indexer) and function_exported?(indexer, :ensure_fresh, 2) do
      indexer.ensure_fresh(path, files)
    end

    :ok
  end

  defp summary(node), do: Map.take(node, @summary)
end
