defmodule Trailblazer.Store do
  @moduledoc """
  The graph's store: repositories, their files, the definitions those files
  hold, the references the definitions make and the edges the resolver drew
  between them. All of it lives in one SQLite database.

  A demand queue feeds one writer and two read-only WAL connections. Every
  write commits before acknowledgement, and every read has one snapshot.

  A node's `key` is `"<lang>:<kind>:<path>#<qualified>"`, unique in its repo. A
  node's `id` is its row id, it stays the same while the key exists, and it is
  also the node's Qdrant point id.
  """

  alias Trailblazer.{Config, Files}
  alias Trailblazer.Store.Resolution

  @schema_path Path.expand("../../priv/migrations/001_graph.sql", __DIR__)
  @external_resource @schema_path
  @schema File.read!(@schema_path)

  @node_columns "id, repo_id, key, lang, kind, name, qualified, path, " <>
                  "start_line, end_line, signature, text_hash, stale, vector_hash"

  @node_select "SELECT #{@node_columns} FROM node"
  @edge_columns "id, repo_id, from_id, to_id, kind, uncertain, line"
  @edge_select "SELECT #{@edge_columns} FROM edge"

  @ref_select """
  SELECT r.id, r.repo_id, r.path, r.from_key, n.id AS from_id, r.kind, r.target, r.arity, r.line, r.ambiguous
  FROM ref r
  LEFT JOIN node n ON n.repo_id = r.repo_id AND n.key = r.from_key
  """

  @node_upsert """
  INSERT INTO node (repo_id, key, lang, kind, name, qualified, path, start_line, end_line,
                    signature, text_hash, ord, stale)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
  ON CONFLICT (repo_id, key) DO UPDATE SET
    ord = excluded.ord,
    lang = excluded.lang,
    kind = excluded.kind,
    name = excluded.name,
    qualified = excluded.qualified,
    path = excluded.path,
    start_line = excluded.start_line,
    end_line = excluded.end_line,
    signature = excluded.signature,
    text_hash = excluded.text_hash,
    stale = 0
  """

  @edge_batch 500

  ## Repositories

  @doc """
  Registers the repository at `path` and returns its id, which is the same id
  every time the same canonical path is added again, including symlinked and
  relative spellings. Missing paths may be registered; symlink loops return an error.
  """
  @spec add_repo(Path.t()) :: {:ok, integer()} | {:error, term()}
  def add_repo(path) do
    with {:ok, path} <- Files.canonical_path(path) do
      register_repo(Path.expand(path))
    end
  end

  defp register_repo(path) do
    run(fn conn ->
      write(
        conn,
        :repo_insert,
        "INSERT INTO repo (path) VALUES (?) ON CONFLICT (path) DO NOTHING",
        [
          path
        ]
      )

      case rows(conn, :repo_select, "SELECT id FROM repo WHERE path = ?", [path]) do
        [%{id: id}] -> {:ok, id}
        _other -> raise "no id for repo #{inspect(path)}"
      end
    end)
  end

  @doc """
  Every registered repository, as `%{id: id, path: path}`.
  """
  @spec repos() :: [%{id: integer(), path: Path.t()}]
  def repos do
    read(fn conn ->
      conn
      |> rows(:repos, "SELECT id, path FROM repo ORDER BY id")
      |> Enum.map(&Map.take(&1, [:id, :path]))
    end)
  end

  @doc """
  The repositories to watch again when the service starts (E11): those a watch
  succeeded on, as `%{id: id, path: path}`.
  """
  @spec watched_repos() :: [%{id: integer(), path: Path.t()}]
  def watched_repos do
    read(fn conn ->
      conn
      |> rows(:watched_repos, "SELECT id, path FROM repo WHERE watched = 1 ORDER BY id")
      |> Enum.map(&Map.take(&1, [:id, :path]))
    end)
  end

  @doc "Records whether `repo_id` is to be watched again when the service starts."
  @spec set_watched(integer(), boolean()) :: :ok
  def set_watched(repo_id, watched?) do
    run(fn conn ->
      write(conn, :set_watched, "UPDATE repo SET watched = ? WHERE id = ?", [
        if(watched?, do: 1, else: 0),
        repo_id
      ])
    end)
  end

  @doc """
  The HEAD commit the graph of `repo_id` was last brought up to, or nil when it
  has never been indexed from git (design §13.7).
  """
  @spec indexed_head(integer()) :: String.t() | nil
  def indexed_head(repo_id) do
    read(fn conn ->
      case rows(conn, :indexed_head, "SELECT indexed_head FROM repo WHERE id = ?", [repo_id]) do
        [%{indexed_head: head}] -> head
        _ -> nil
      end
    end)
  end

  @doc "Records the HEAD commit `repo_id`'s graph now matches; nil forgets it."
  @spec set_indexed_head(integer(), String.t() | nil) :: :ok
  def set_indexed_head(repo_id, head) do
    run(fn conn ->
      write(conn, :set_indexed_head, "UPDATE repo SET indexed_head = ? WHERE id = ?", [
        head,
        repo_id
      ])
    end)
  end

  @doc "Paths dirty at the last successful git reconciliation (J33)."
  def indexed_dirty(repo_id) do
    read(fn conn ->
      if indexed_dirty_column?(conn) do
        case rows(conn, :indexed_dirty, "SELECT indexed_dirty FROM repo WHERE id=?", [repo_id]) do
          [%{indexed_dirty: value}] when is_binary(value) ->
            :erlang.binary_to_term(value, [:safe])

          _ ->
            []
        end
      else
        []
      end
    end)
  end

  @doc "Atomically records the indexed HEAD and dirty paths after a successful git sync."
  def set_indexed_git_state(repo_id, head, paths) do
    run(fn conn ->
      # Hot-loaded writers may predate this column. No cached process fields.
      unless indexed_dirty_column?(conn),
        do: Exqlite.query!(conn, "ALTER TABLE repo ADD COLUMN indexed_dirty BLOB", [])

      write(
        conn,
        :set_indexed_git_state,
        "UPDATE repo SET indexed_head=?,indexed_dirty=? WHERE id=?",
        [
          head,
          {:blob, :erlang.term_to_binary(Enum.sort(paths))},
          repo_id
        ]
      )
    end)
  end

  defp indexed_dirty_column?(conn),
    do:
      Enum.any?(
        rows(conn, :indexed_dirty_columns, "PRAGMA table_info(repo)"),
        &(&1.name == "indexed_dirty")
      )

  @doc "The cached float32 vector blob for this model and exact input hash."
  def embedding_cache_get(model, hash) do
    read(fn conn ->
      case rows(
             conn,
             :embedding_cache_get,
             "SELECT vector FROM embedding_cache WHERE model = ? AND hash = ?",
             [model, hash]
           ) do
        [%{vector: blob}] -> blob
        [] -> nil
      end
    end)
  end

  @doc "Caches a float32 vector independently of a repository's point ids."
  def embedding_cache_put(model, hash, blob) do
    run(fn conn ->
      write(
        conn,
        :embedding_cache_put,
        "INSERT INTO embedding_cache (model, hash, vector) VALUES (?, ?, ?) " <>
          "ON CONFLICT (model, hash) DO UPDATE SET vector = excluded.vector",
        [model, hash, {:blob, blob}]
      )
    end)
  end

  # Case records have a database of their own: Trailblazer.CaseStore (E23).

  ## Files, nodes and refs

  @doc """
  Replaces everything `path` contributed to `repo_id`: its hash, its nodes and
  its refs, in one transaction. A node whose key is already there keeps its id
  and its `vector_hash`, so only a node whose text changed needs embedding
  again; nodes and refs that are gone are removed, and the file's nodes are no
  longer marked stale.
  """
  @spec replace_file(integer(), Path.t(), %{
          hash: term(),
          nodes: [map()],
          refs: [map()]
        }) :: :ok | {:error, {:bad_ref_target, map()}}
  def replace_file(repo_id, path, %{hash: hash, nodes: nodes, refs: refs}) do
    cond do
      Enum.any?(refs, &(not is_map(&1) or not is_binary(&1[:target]))) ->
        {:error,
         {:bad_ref_target, Enum.find(refs, &(not is_map(&1) or not is_binary(&1[:target])))}}

      Enum.any?(refs, &(not is_boolean(Map.get(&1, :ambiguous, false)))) ->
        {:error, {:bad_ref, Enum.find(refs, &(not is_boolean(Map.get(&1, :ambiguous, false))))}}

      true ->
        replace_valid_file(repo_id, path, hash, nodes, refs)
    end
  end

  defp replace_valid_file(repo_id, path, hash, nodes, refs) do
    run(fn conn ->
      transaction(conn, fn conn ->
        digest = batch_digest({hash, nodes, refs})

        unless same_batch?(conn, repo_id, "file", path, digest) do
          Resolution.ensure(conn)
          before = resolution_file(conn, repo_id, path)
          incoming = Resolution.incoming(conn, repo_id, path)
          upsert_nodes(conn, repo_id, nodes)
          drop_missing_nodes(conn, repo_id, path, nodes)

          write(conn, :refs_delete_file, "DELETE FROM ref WHERE repo_id = ? AND path = ?", [
            repo_id,
            path
          ])

          insert_refs(conn, repo_id, path, refs)

          write(
            conn,
            :file_upsert,
            "INSERT INTO file (repo_id, path, hash) VALUES (?, ?, ?) " <>
              "ON CONFLICT (repo_id, path) DO UPDATE SET hash = excluded.hash",
            [repo_id, path, hash]
          )

          Resolution.mutated(
            conn,
            repo_id,
            path,
            before,
            resolution_file(conn, repo_id, path),
            incoming
          )

          forget_batch(conn, repo_id, "edges", "")
          remember_batch(conn, repo_id, "file", path, digest)
        end
      end)
    end)
  end

  @doc """
  Marks the nodes of `path` stale, because the file no longer parses. They and
  their edges stay, so a file being edited does not empty the graph.
  """
  @spec mark_stale(integer(), Path.t()) :: :ok
  def mark_stale(repo_id, path) do
    run(fn conn ->
      forget_batch(conn, repo_id, "file", path)

      write(conn, :node_mark_stale, "UPDATE node SET stale = 1 WHERE repo_id = ? AND path = ?", [
        repo_id,
        path
      ])

      :ok
    end)
  end

  @doc """
  Forgets `path`: its nodes, its refs, and every edge to or from those nodes.
  An edge that pointed into the file from another file goes with it, so the
  graph holds no dangling ids; the reference that made it stays unresolved.
  """
  @spec delete_file(integer(), Path.t()) :: :ok
  def delete_file(repo_id, path) do
    run(fn conn ->
      transaction(conn, fn conn ->
        Resolution.ensure(conn)
        before = resolution_file(conn, repo_id, path)
        incoming = Resolution.incoming(conn, repo_id, path)
        forget_batch(conn, repo_id, "file", path)
        forget_batch(conn, repo_id, "edges", "")
        ids = ids_of_file(conn, repo_id, path)
        queue_vector_deletes(conn, repo_id, ids)
        delete_edges_touching(conn, ids)

        write(conn, :refs_delete_file, "DELETE FROM ref WHERE repo_id = ? AND path = ?", [
          repo_id,
          path
        ])

        write(conn, :node_delete_file, "DELETE FROM node WHERE repo_id = ? AND path = ?", [
          repo_id,
          path
        ])

        write(conn, :file_delete, "DELETE FROM file WHERE repo_id = ? AND path = ?", [
          repo_id,
          path
        ])

        Resolution.mutated(conn, repo_id, path, before, %{nodes: [], refs: []}, incoming)
      end)
    end)
  end

  # Resolution metadata is stored in SQLite, never in a long-lived closure.
  defp resolution_read(fun) do
    case read(fn conn ->
           if Resolution.installed?(conn), do: {:ready, fun.(conn)}, else: :needs_schema
         end) do
      {:ready, value} ->
        value

      :needs_schema ->
        run(&Resolution.ensure/1)
        read(fun)
    end
  end

  def resolution_state(repo), do: resolution_read(&Resolution.state(&1, repo))
  def resolution_current?(repo), do: resolution_read(&Resolution.current?(&1, repo))
  def resolution_readers(repo, tokens), do: resolution_read(&Resolution.readers(&1, repo, tokens))
  def resolution_dependencies(repo), do: resolution_read(&Resolution.dependencies(&1, repo))

  def replace_resolved_sources(repo, revision, batch),
    do: run(&Resolution.replace(&1, repo, revision, batch))

  defp resolution_file(conn, repo, path) do
    %{
      nodes:
        node_rows(
          conn,
          :resolution_nodes,
          @node_select <> " WHERE repo_id=? AND path=? ORDER BY id",
          [repo, path]
        ),
      refs:
        rows(
          conn,
          :resolution_refs,
          @ref_select <> " WHERE r.repo_id=? AND r.path=? ORDER BY r.id",
          [repo, path]
        )
    }
  end

  ## Edges

  @doc """
  Replaces `repo_id`'s resolved edges with `edges`.
  """
  @spec put_edges(integer(), [map()]) :: :ok | {:error, {:foreign_node, integer()}}
  def put_edges(repo_id, edges) do
    case Enum.find_index(edges, &(not valid_edge?(&1))) do
      nil -> put_valid_edges(repo_id, edges)
      index -> {:error, {:bad_edge, Enum.at(edges, index)}}
    end
  end

  defp valid_edge?(%{from_id: from, to_id: to, kind: kind, uncertain: uncertain} = edge) do
    is_integer(from) and from > 0 and is_integer(to) and to > 0 and
      is_binary(kind) and is_boolean(uncertain) and
      (is_nil(edge[:line]) or (is_integer(edge[:line]) and edge[:line] > 0))
  end

  defp valid_edge?(_), do: false

  defp put_valid_edges(repo_id, edges) do
    run(fn conn ->
      own_ids =
        rows(conn, :repo_node_ids, "SELECT id FROM node WHERE repo_id = ?", [repo_id])
        |> MapSet.new(& &1.id)

      case Enum.find(
             Enum.flat_map(edges, &[&1.from_id, &1.to_id]),
             &(not MapSet.member?(own_ids, &1))
           ) do
        nil ->
          digest = batch_digest(edges)

          unless same_batch?(conn, repo_id, "edges", "", digest) do
            replace_edges(conn, repo_id, edges)
            Resolution.untracked(conn, repo_id)
            remember_batch(conn, repo_id, "edges", "", digest)
          end

          :ok

        id ->
          {:error, {:foreign_node, id}}
      end
    end)
  end

  defp replace_edges(conn, repo_id, edges) do
    transaction(conn, fn conn ->
      write(conn, :edge_delete_repo, "DELETE FROM edge WHERE repo_id = ?", [repo_id])

      for batch <- Enum.chunk_every(edges, @edge_batch) do
        write(
          conn,
          :"edge_insert_#{length(batch)}",
          "INSERT INTO edge (repo_id, from_id, to_id, kind, uncertain, line) VALUES " <>
            Enum.map_join(batch, ", ", fn _ -> "(?, ?, ?, ?, ?, ?)" end),
          Enum.flat_map(batch, fn edge ->
            [repo_id, edge.from_id, edge.to_id, edge.kind, sql_bool(edge.uncertain), edge[:line]]
          end)
        )
      end
    end)
  end

  ## Reads

  @doc """
  The node with that id, or `nil`.
  """
  @spec node(integer()) :: map() | nil
  def node(id) do
    read(fn conn ->
      case node_rows(conn, :node_by_id, @node_select <> " WHERE id = ?", [id]) do
        [node] -> node
        [] -> nil
      end
    end)
  end

  @doc "The nodes with these ids, fetched in batches rather than one transaction per node."
  def nodes(ids) do
    read(fn conn ->
      ids
      |> Enum.uniq()
      |> Enum.chunk_every(400)
      |> Enum.flat_map(fn batch ->
        node_rows(
          conn,
          :nodes_by_ids,
          @node_select <> " WHERE id IN (#{placeholders(length(batch))})",
          batch
        )
      end)
    end)
  end

  @doc """
  Distinct graph links touching these ids, with both endpoints in the repo.
  Call-site lines are not needed by a graph walk: many calls to the same
  target contribute one weighted link, not repeated database round trips.

  `max_targets: n` leaves out uncertain calls from a site that resolved to
  more than `n` candidates.
  """
  def adjacent_edges(repo_id, ids, opts \\ []) do
    max_targets = Keyword.get(opts, :max_targets)
    true = is_nil(max_targets) or (is_integer(max_targets) and max_targets > 0)

    read(fn conn ->
      ids
      |> Enum.uniq()
      |> Enum.chunk_every(400)
      |> Enum.flat_map(fn batch ->
        slots = placeholders(length(batch))

        # With max_targets, an uncertain call whose site (from_id, line) resolved
        # to more candidates than that is left out: it says only that some
        # function of that name exists. On a TypeScript repository nearly all
        # call edges are such fan-out (every `.pipe(` linked to every `pipe`),
        # and walking through them reached most of the graph.
        ambiguous =
          if max_targets,
            do:
              " AND NOT (e.kind='calls' AND e.uncertain=1 AND " <>
                "(SELECT count(*) FROM edge s INDEXED BY edge_site " <>
                "WHERE s.from_id=e.from_id AND s.line IS e.line AND s.kind='calls') > #{max_targets})",
            else: ""

        # OR plus repo_id makes SQLite scan the whole repo for every batch.
        # Each direction must use its endpoint index; UNION removes repeated
        # call sites while retaining distinct kinds and uncertainty weights.
        direction = fn column, index ->
          "SELECT e.from_id, e.to_id, e.kind, e.uncertain FROM edge e INDEXED BY #{index} " <>
            "JOIN node f ON f.id=e.from_id JOIN node t ON t.id=e.to_id " <>
            "WHERE e.repo_id=? AND f.repo_id=? AND t.repo_id=? " <>
            "AND e.#{column} IN (#{slots})" <> ambiguous
        end

        params = [repo_id, repo_id, repo_id] ++ batch

        rows(
          conn,
          :adjacent_edges,
          direction.("from_id", "edge_from") <> " UNION " <> direction.("to_id", "edge_to"),
          params ++ params
        )
      end)
      |> Enum.uniq()
      |> Enum.map(fn edge -> Map.update!(edge, :uncertain, &flag/1) end)
    end)
  end

  @doc """
  The repo's nodes declared with that bare name, such as `"put"`.
  """
  @spec nodes_by_name(integer(), String.t()) :: [map()]
  def nodes_by_name(repo_id, name), do: nodes_where(repo_id, "name", name)

  @doc """
  The repo's nodes with that qualified name, such as `"Mini.Store.put/2"`.
  """
  @spec nodes_by_qualified(integer(), String.t()) :: [map()]
  def nodes_by_qualified(repo_id, qualified), do: nodes_where(repo_id, "qualified", qualified)

  @doc """
  The repo's nodes declared in that file.
  """
  @spec nodes_in_file(integer(), Path.t()) :: [map()]
  def nodes_in_file(repo_id, path), do: nodes_where(repo_id, "path", path)

  defp nodes_where(repo_id, column, value) do
    read(fn conn ->
      node_rows(
        conn,
        :"nodes_by_#{column}",
        @node_select <> " WHERE repo_id = ? AND #{column} = ? ORDER BY path, ord, id",
        [
          repo_id,
          value
        ]
      )
    end)
  end

  @doc """
  The edges leaving `ids`, of any kind or only those named in `kinds`.
  """
  @spec edges_from(integer() | [integer()], [String.t()] | nil) :: [map()]
  def edges_from(ids, kinds \\ nil), do: edges(:edges_from, "from_id", ids, kinds)

  @doc """
  The edges arriving at `ids`, of any kind or only those named in `kinds`.
  """
  @spec edges_to(integer() | [integer()], [String.t()] | nil) :: [map()]
  def edges_to(ids, kinds \\ nil), do: edges(:edges_to, "to_id", ids, kinds)

  defp edges(name, column, ids, kinds) do
    ids = List.wrap(ids)
    kinds = List.wrap(kinds)

    read(fn conn ->
      case ids do
        [] ->
          []

        _ ->
          sql =
            @edge_select <>
              " WHERE #{column} IN (#{placeholders(length(ids))})" <> kinds_sql(kinds)

          conn
          |> rows(name, sql, ids ++ kinds)
          |> Enum.map(fn edge -> Map.update!(edge, :uncertain, &flag/1) end)
      end
    end)
  end

  @doc """
  Every reference of the repo as it was parsed, each with the node it comes
  from as `from_id` when that node is still there. A reference outside any
  definition has a nil `from_key` and a nil `from_id`.
  """
  @spec refs(integer()) :: [map()]
  def refs(repo_id) do
    read(fn conn ->
      rows(conn, :refs, @ref_select <> " WHERE r.repo_id = ? ORDER BY r.id", [repo_id])
      |> Enum.map(&Map.update!(&1, :ambiguous, fn value -> flag(value) end))
    end)
  end

  @doc "A coherent view of all nodes and unresolved refs in one repository."
  def graph_snapshot(repo_id), do: read(&graph_snapshot(&1, repo_id))

  @doc false
  def resolution_selected(repo_id, resolver) do
    resolution_read(fn conn ->
      case Resolution.selection(conn, repo_id) do
        {:fallback, _} = fallback ->
          fallback

        plan ->
          resolver.(plan, fn token, limit -> Resolution.lookup(conn, repo_id, token, limit) end)
      end
    end)
  end

  def resolution_snapshot(repo_id) do
    resolution_read(fn conn ->
      state = Resolution.header(conn, repo_id)

      graph_snapshot(conn, repo_id)
      |> Map.merge(%{
        revision: state.revision,
        resolution: state,
        sources: Resolution.sources(conn, repo_id)
      })
    end)
  end

  defp graph_snapshot(conn, repo_id) do
    %{
      nodes:
        node_rows(conn, :snapshot_nodes, @node_select <> " WHERE repo_id = ? ORDER BY id", [
          repo_id
        ]),
      refs:
        rows(conn, :snapshot_refs, @ref_select <> " WHERE r.repo_id = ? ORDER BY r.id", [repo_id])
        |> Enum.map(&Map.update!(&1, :ambiguous, fn value -> flag(value) end))
    }
  end

  @doc "The last successfully parsed hash of each indexed file."
  def files(repo_id),
    do:
      read(fn conn ->
        rows(conn, :files, "SELECT path, hash FROM file WHERE repo_id = ? ORDER BY path", [
          repo_id
        ])
      end)

  @doc "The paths whose file is a module node of its own (`qualified` is the path)."
  def module_paths(repo_id),
    do:
      read(fn conn ->
        conn
        |> rows(
          :module_paths,
          "SELECT path FROM node WHERE repo_id = ? AND kind = 'module' AND qualified = path",
          [repo_id]
        )
        |> Enum.map(& &1.path)
      end)

  @doc "A repository's node and edge counts, counted by the database."
  def counts(repo_id),
    do:
      read(fn conn ->
        [%{n: nodes}] =
          rows(conn, :count_nodes, "SELECT COUNT(*) AS n FROM node WHERE repo_id = ?", [repo_id])

        [%{n: edges}] =
          rows(
            conn,
            :count_edges,
            "SELECT COUNT(*) AS n FROM edge e JOIN node f ON f.id = e.from_id WHERE f.repo_id = ?",
            [repo_id]
          )

        %{nodes: nodes, edges: edges}
      end)

  @doc "The paths with stale nodes in a repository, without loading its graph."
  def stale_paths(repo_id),
    do:
      read(fn conn ->
        conn
        |> rows(:stale_paths, "SELECT DISTINCT path FROM node WHERE repo_id = ? AND stale = 1", [
          repo_id
        ])
        |> Enum.map(& &1.path)
      end)

  def pending_vector_deletes(repo_id),
    do:
      read(fn conn ->
        rows(
          conn,
          :vector_deletes,
          "SELECT node_id FROM vector_delete WHERE repo_id = ? ORDER BY node_id",
          [repo_id]
        )
        |> Enum.map(& &1.node_id)
      end)

  def vector_deleted(repo_id, ids) do
    run(fn conn ->
      for id <- ids,
          do:
            write(
              conn,
              :vector_deleted,
              "DELETE FROM vector_delete WHERE repo_id = ? AND node_id = ?",
              [repo_id, id]
            )

      :ok
    end)
  end

  defp queue_vector_deletes(conn, repo_id, ids) do
    for id <- ids,
        do:
          write(
            conn,
            :vector_delete_queue,
            "INSERT OR IGNORE INTO vector_delete (repo_id,node_id) VALUES (?,?)",
            [repo_id, id]
          )
  end

  ## Vectors

  @doc """
  At most `limit` of the repo's nodes whose `vector_hash` is not their current
  `text_hash`, in the order they were indexed.
  """
  @spec pending_vectors(integer(), integer()) :: [map()]
  @spec pending_vectors(integer(), integer(), keyword()) :: [map()]
  def pending_vectors(repo_id, limit, opts \\ []) do
    read(fn conn ->
      node_rows(
        conn,
        :pending_vectors,
        @node_select <>
          " WHERE repo_id = ? AND (vector_hash IS NULL OR IFNULL(text_hash, '') <> IFNULL(vector_hash, ''))" <>
          if(Keyword.get(opts, :exclude_stale, false), do: " AND stale = 0", else: "") <>
          " AND id > ? ORDER BY id LIMIT ?",
        [repo_id, Keyword.get(opts, :after_id, 0), limit]
      )
    end)
  end

  @doc """
  Says that each node is embedded as the text whose hash it is given, so it is
  no longer pending.

  The hash is the one that was embedded, not the node's current one: a file
  may have been indexed again while the embedding was in flight, and then this
  node's vector is the old text's, so it has to stay pending for the new text.
  """
  @spec vector_done([{integer(), String.t() | nil}] | {integer(), String.t() | nil}) :: :ok
  def vector_done(pairs) do
    pairs = List.wrap(pairs)

    run(fn conn ->
      transaction(conn, fn conn ->
        for {id, hash} <- pairs do
          write(conn, :vector_done, "UPDATE node SET vector_hash = ? WHERE id = ?", [hash, id])
        end
      end)
    end)
  end

  ## Connection

  @doc """
  Starts the store, opening the database at `:db`, or at `trailblazer.db` in the
  state directory when no path is given.
  """
  def start_link(opts \\ []) do
    db = Keyword.get(opts, :db) || Path.join(Config.get(:state_dir), "trailblazer.db")
    File.mkdir_p!(Path.dirname(db))
    Trailblazer.Store.Connections.start_link(name: __MODULE__, db: db, setup: &migrate/1)
  end

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: :infinity}

  defp run(fun), do: request(:write, fun)
  defp read(fun), do: request(:read, fun)

  defp request(mode, fun) do
    case GenServer.call(__MODULE__, {:run, mode, fun}, :infinity) do
      {:returned, value} -> value
      {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  defp transaction(conn, fun) do
    {:ok, _result} = Exqlite.transaction(conn, fun, timeout: :infinity)
    :ok
  end

  ## Schema

  # Columns added to the schema after databases were already made with it.
  # `CREATE TABLE IF NOT EXISTS` leaves an existing table as it was, so each
  # is added in place when missing; a database is never erased to bring it up
  # to date (E8 in the register).
  @added_columns [
    {"ref", "ambiguous", "INTEGER NOT NULL DEFAULT 0"},
    {"node", "ord", "INTEGER NOT NULL DEFAULT 0"},
    {"repo", "watched", "INTEGER NOT NULL DEFAULT 0"},
    {"repo", "indexed_head", "TEXT"},
    {"repo", "indexed_dirty", "BLOB"}
  ]

  @doc false
  def migrate(conn) do
    for statement <- statements(@schema) do
      write(conn, :schema, statement)
    end

    for {table, column, declaration} <- @added_columns do
      present = conn |> rows(:table_info, "PRAGMA table_info(#{table})") |> Enum.map(& &1.name)

      unless column in present do
        write(conn, :add_column, "ALTER TABLE #{table} ADD COLUMN #{column} #{declaration}")
      end
    end

    Resolution.migrate(conn)
    :ok
  end

  defp statements(sql) do
    sql
    |> String.split(";")
    |> Enum.map(&(&1 |> lines() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp lines(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "--"))
    |> Enum.join("\n")
  end

  ## Writes

  # A node's place in its parser's output is kept (`ord`), so a file's nodes
  # come back in source order whatever ids earlier versions gave them (C4).
  defp upsert_nodes(conn, repo_id, nodes) do
    for {node, ord} <- Enum.with_index(nodes) do
      write(conn, :node_upsert, @node_upsert, [
        repo_id,
        node.key,
        node[:lang],
        node.kind,
        node[:name],
        node[:qualified],
        node.path,
        node.start_line,
        node.end_line,
        node[:signature],
        node[:text_hash],
        ord
      ])
    end

    :ok
  end

  defp drop_missing_nodes(conn, repo_id, path, nodes) do
    keep = MapSet.new(nodes, & &1.key)

    gone =
      conn
      |> node_rows(:nodes_of_file, @node_select <> " WHERE repo_id = ? AND path = ?", [
        repo_id,
        path
      ])
      |> Enum.reject(&MapSet.member?(keep, &1.key))
      |> Enum.map(& &1.id)

    queue_vector_deletes(conn, repo_id, gone)
    delete_edges_touching(conn, gone)

    case gone do
      [] ->
        :ok

      _ ->
        write(
          conn,
          :node_delete,
          "DELETE FROM node WHERE id IN (#{placeholders(length(gone))})",
          gone
        )
    end

    :ok
  end

  defp ids_of_file(conn, repo_id, path) do
    conn
    |> rows(:node_ids_of_file, "SELECT id FROM node WHERE repo_id = ? AND path = ?", [
      repo_id,
      path
    ])
    |> Enum.map(& &1.id)
  end

  defp delete_edges_touching(conn, ids) do
    case ids do
      [] ->
        :ok

      ids ->
        write(
          conn,
          :edge_delete_touching,
          "DELETE FROM edge WHERE from_id IN (#{placeholders(length(ids))}) " <>
            "OR to_id IN (#{placeholders(length(ids))})",
          ids ++ ids
        )

        :ok
    end
  end

  defp insert_refs(conn, repo_id, path, refs) do
    for ref <- refs do
      write(
        conn,
        :ref_insert,
        "INSERT INTO ref (repo_id, path, from_key, kind, target, arity, line, ambiguous) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [
          repo_id,
          path,
          ref[:from_key],
          ref.kind,
          ref.target,
          ref[:arity],
          ref[:line],
          if(ref[:ambiguous], do: 1, else: 0)
        ]
      )
    end

    :ok
  end

  # One durable fingerprint per current file/edge batch, committed with its data.
  # Retrying after a lost acknowledgement leaves row identities intact (J16).
  defp batch_digest(payload),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(payload, [:deterministic]))

  defp same_batch?(conn, repo, kind, path, digest) do
    rows(
      conn,
      :batch_match,
      "SELECT 1 AS present FROM write_batch WHERE repo_id = ? AND kind = ? AND path = ? AND digest = ?",
      [repo, kind, path, {:blob, digest}]
    ) != []
  end

  defp remember_batch(conn, repo, kind, path, digest) do
    write(
      conn,
      :batch_remember,
      "INSERT INTO write_batch(repo_id,kind,path,digest) VALUES (?,?,?,?) " <>
        "ON CONFLICT(repo_id,kind,path) DO UPDATE SET digest = excluded.digest",
      [repo, kind, path, {:blob, digest}]
    )
  end

  defp forget_batch(conn, repo, kind, path),
    do:
      write(
        conn,
        :batch_forget,
        "DELETE FROM write_batch WHERE repo_id = ? AND kind = ? AND path = ?",
        [repo, kind, path]
      )

  ## SQL

  defp write(conn, name, statement, params \\ []) do
    {_query, _result} =
      Exqlite.prepare_execute!(conn, name, statement, params, timeout: :infinity)

    :ok
  end

  defp rows(conn, name, statement, params \\ []) do
    {_query, %Exqlite.Result{columns: columns, rows: rows}} =
      Exqlite.prepare_execute!(conn, name, statement, params, timeout: :infinity)

    keys = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows, fn row -> keys |> Enum.zip(row) |> Map.new() end)
  end

  defp node_rows(conn, name, statement, params) do
    conn
    |> rows(name, statement, params)
    |> Enum.map(fn row -> Map.update!(row, :stale, &flag/1) end)
  end

  defp kinds_sql([]), do: ""
  defp kinds_sql(kinds), do: " AND kind IN (#{placeholders(length(kinds))})"

  defp placeholders(count) when count > 0, do: Enum.map_join(1..count, ",", fn _ -> "?" end)
  defp placeholders(_count), do: "NULL"

  defp sql_bool(value) when value in [true, 1, "1"], do: 1
  defp sql_bool(_other), do: 0

  defp flag(value) when value in [true, 1, "1"], do: true
  defp flag(_other), do: false
end
