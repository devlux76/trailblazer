defmodule Trailblazer.Store.Resolution do
  @moduledoc false
  alias Trailblazer.Graph.Inputs
  @schema_path Path.expand("../../../priv/migrations/003_resolution.sql", __DIR__)
  @external_resource @schema_path
  @schema File.read!(@schema_path)

  # A running writer can load this code without being restarted. The enclosing
  # Store write transaction makes the marker and all tables appear atomically.
  def ensure(conn) do
    if not installed?(conn), do: migrate(conn)
    :ok
  end

  def installed?(conn),
    do:
      rows(conn, "SELECT name FROM sqlite_master WHERE type='table' AND name='resolve_revision'") !=
        []

  def migrate(conn) do
    @schema
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "--"))
    |> Enum.join("\n")
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&query(conn, &1))

    :ok
  end

  def header(conn, repo) do
    defaults = %{
      revision: 0,
      resolved_revision: 0,
      version: 0,
      complete: false,
      lookup_version: 0
    }

    case rows(
           conn,
           "SELECT revision,resolved_revision,version,complete,lookup_version FROM resolve_revision WHERE repo_id=?",
           [repo]
         ) do
      [] -> defaults
      [s] -> %{s | complete: s.complete == 1}
    end
  end

  def state(conn, repo) do
    Map.merge(header(conn, repo), %{
      pending:
        rows(conn, "SELECT owner_key FROM resolve_pending WHERE repo_id=? ORDER BY owner_key", [
          repo
        ])
        |> Enum.map(& &1.owner_key),
      changed:
        rows(conn, "SELECT token FROM resolve_changed WHERE repo_id=? ORDER BY token", [repo])
        |> Enum.map(&Inputs.decode(&1.token))
        |> Enum.sort()
    })
  end

  # J31 currentness only: the stage 2 selector must also require complete
  # coverage at Inputs.version(), including immediately after a hot-load.
  def current?(conn, repo) do
    rows(
      conn,
      "SELECT 1 AS dirty FROM resolve_revision WHERE repo_id=? AND revision<>resolved_revision UNION ALL SELECT 1 FROM resolve_pending WHERE repo_id=? LIMIT 1",
      [repo, repo]
    ) == []
  end

  def sources(conn, repo) do
    rows(
      conn,
      "SELECT key AS owner_key FROM node WHERE repo_id=? UNION SELECT from_key FROM ref WHERE repo_id=? AND from_key IS NOT NULL UNION SELECT owner_key FROM resolve_pending WHERE repo_id=? UNION SELECT owner_key FROM resolve_source WHERE repo_id=? ORDER BY owner_key",
      [repo, repo, repo, repo]
    )
    |> Enum.map(& &1.owner_key)
  end

  # File mutations already enqueue L/R(K)/T atomically. This read and all
  # lookups run inside the same Store read transaction, never on the writer.
  def selection(conn, repo) do
    state = header(conn, repo)

    if state.complete and state.version == Inputs.version() and
         state.lookup_version == Inputs.version() do
      sources =
        rows(conn, "SELECT owner_key FROM resolve_pending WHERE repo_id=? ORDER BY owner_key", [
          repo
        ])
        |> Enum.map(& &1.owner_key)

      [[total]] = query(conn, "SELECT count(*) FROM resolve_source WHERE repo_id=?", [repo]).rows

      selected_refs =
        scoped(conn, "SELECT count(*) AS n FROM ref", repo, "from_key", sources)
        |> Enum.map(& &1.n)
        |> Enum.sum()

      [[total_refs]] =
        query(conn, "SELECT coalesce(sum(ref_count),0) FROM resolve_path WHERE repo_id=?", [repo]).rows

      cond do
        sources == [] and state.revision != state.resolved_revision ->
          {:fallback, :ledger_gap}

        length(sources) * 4 > total or selected_refs > max(128, div(total_refs, 4)) ->
          {:fallback, :workload}

        true ->
          refs =
            scoped(
              conn,
              "SELECT from_key,path,kind,target,arity,line,ambiguous FROM ref",
              repo,
              "from_key",
              sources
            )
            |> Enum.map(&Map.update!(&1, :ambiguous, fn value -> value == 1 end))

          %{
            revision: state.revision,
            sources: sources,
            refs: refs,
            budget: max(128, total),
            total_sources: total
          }
      end
    else
      {:fallback, :coverage}
    end
  end

  def lookup(conn, repo, token, limit) do
    nodes = "SELECT id,key,lang,kind,name,qualified,path,signature FROM node"

    case token do
      {:source, key} ->
        List.first(rows(conn, nodes <> " WHERE repo_id=? AND key=?", [repo, key]))

      {:qualified, key} ->
        rows(conn, nodes <> " WHERE repo_id=? AND qualified=? LIMIT ?", [repo, key, limit])

      {:name, "c-family", name} ->
        rows(conn, nodes <> " WHERE repo_id=? AND name=? AND lang IN ('c','cpp') LIMIT ?", [
          repo,
          name,
          limit
        ])

      {:name, family, name} ->
        rows(conn, nodes <> " WHERE repo_id=? AND name=? AND lang IS ? LIMIT ?", [
          repo,
          name,
          family,
          limit
        ])

      {:nodes, path} ->
        rows(conn, nodes <> " WHERE repo_id=? AND path=? LIMIT ?", [repo, path, limit])

      {:imports, path, member} ->
        rows(
          conn,
          "SELECT path,target FROM resolve_import WHERE repo_id=? AND path=? AND member=? LIMIT ?",
          [repo, path, member, limit]
        )

      {:exists, path} ->
        rows(
          conn,
          "SELECT 1 FROM resolve_path WHERE repo_id=? AND path=? AND node_count+ref_count>0",
          [repo, path]
        ) != []

      {:file_suffix, suffix} ->
        rows(conn, "SELECT path FROM resolve_file_suffix WHERE repo_id=? AND suffix=? LIMIT ?", [
          repo,
          suffix,
          limit
        ])
        |> Enum.map(& &1.path)

      {:doc_suffix, suffix} ->
        rows(
          conn,
          "SELECT n.id,n.key,n.lang,n.kind,n.name,n.qualified,n.path,n.signature FROM resolve_doc_suffix d JOIN node n ON n.id=d.node_id WHERE d.repo_id=? AND d.suffix=? AND n.repo_id=? LIMIT ?",
          [repo, suffix, repo, limit]
        )

      _ ->
        throw({:resolve_fallback, :untrackable_lookup})
    end
  end

  defp publication_rows(conn, select, repo, column, keys, full) do
    if full,
      do: rows(conn, select <> " WHERE repo_id=?", [repo]),
      else: scoped(conn, select, repo, column, keys)
  end

  defp scoped(conn, select, repo, column, keys) do
    keys
    |> Enum.chunk_every(200)
    |> Enum.flat_map(fn chunk ->
      rows(conn, select <> " WHERE repo_id=? AND #{column} IN (#{marks(chunk)})", [repo | chunk])
    end)
  end

  def dependencies(conn, repo) do
    empty =
      Map.new(
        rows(conn, "SELECT owner_key FROM resolve_source WHERE repo_id=?", [repo]),
        &{&1.owner_key, []}
      )

    rows(
      conn,
      "SELECT s.owner_key,t.token FROM resolve_dependency d JOIN resolve_source s ON s.id=d.source_id JOIN resolve_token t ON t.id=d.token_id WHERE s.repo_id=? ORDER BY s.owner_key,t.token",
      [repo]
    )
    |> Enum.reduce(empty, fn r, acc ->
      Map.update(acc, r.owner_key, [Inputs.decode(r.token)], &[Inputs.decode(r.token) | &1])
    end)
  end

  def readers(conn, repo, tokens) do
    Enum.flat_map(tokens, fn token ->
      rows(
        conn,
        "SELECT s.owner_key FROM resolve_token t JOIN resolve_dependency d ON d.token_id=t.id JOIN resolve_source s ON s.id=d.source_id WHERE t.repo_id=? AND t.token=?",
        [
          repo,
          blob(token)
        ]
      )
      |> Enum.map(& &1.owner_key)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def incoming(conn, repo, path) do
    rows(
      conn,
      "SELECT e.to_id,n.key FROM edge e JOIN node n ON n.id=e.from_id JOIN node target ON target.id=e.to_id WHERE e.repo_id=? AND target.path=?",
      [repo, path]
    )
  end

  def mutated(conn, repo, path, before, after_graph, incoming) do
    tokens = Inputs.changed(before, after_graph)
    current_ids = MapSet.new(after_graph.nodes, & &1.id)

    retired_readers =
      Enum.reject(incoming, &MapSet.member?(current_ids, &1.to_id)) |> Enum.map(& &1.key)

    local =
      Enum.map(before.nodes ++ after_graph.nodes, & &1.key) ++
        Enum.map(before.refs ++ after_graph.refs, & &1.from_key)

    pending =
      (local ++ retired_readers ++ readers(conn, repo, tokens))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    bump(conn, repo)

    insert(
      conn,
      "resolve_pending",
      ["repo_id", "owner_key"],
      Enum.map(pending, &[repo, &1]),
      "OR IGNORE"
    )

    insert(
      conn,
      "resolve_changed",
      ["repo_id", "token"],
      Enum.map(tokens, &[repo, blob(&1)]),
      "OR IGNORE"
    )

    replace_tables(conn, repo, Inputs.tables(after_graph), path)
    :ok
  end

  def untracked(conn, repo) do
    ensure(conn)
    bump(conn, repo)
    query(conn, "UPDATE resolve_revision SET complete=0 WHERE repo_id=?", [repo])
    query(conn, "UPDATE resolve_source SET digest=NULL WHERE repo_id=?", [repo])

    insert(
      conn,
      "resolve_pending",
      ["repo_id", "owner_key"],
      Enum.map(sources(conn, repo), &[repo, &1]),
      "OR IGNORE"
    )
  end

  defp bump(conn, repo) do
    query(
      conn,
      "INSERT INTO resolve_revision(repo_id,revision) VALUES (?,1) ON CONFLICT(repo_id) DO UPDATE SET revision=revision+1",
      [repo]
    )
  end

  def replace(conn, repo, revision, batch) do
    ensure(conn)
    s = header(conn, repo)

    cond do
      revision != s.revision ->
        {:error, :stale_revision}

      not valid_batch?(batch) ->
        {:error, :bad_resolution}

      batch.version != Inputs.version() ->
        {:error, :resolver_version}

      batch.full and
          not MapSet.subset?(MapSet.new(sources(conn, repo)), MapSet.new(batch.sources)) ->
        {:error, :incomplete_full_scope}

      batch.full and s.lookup_version != Inputs.version() and not is_map(batch[:lookups]) ->
        {:error, :lookup_baseline_required}

      true ->
        case validate_edges(conn, repo, batch) do
          :ok -> publish(conn, repo, revision, batch, s)
          error -> error
        end
    end
  end

  defp valid_batch?(%{version: v, sources: ss, edges: es, dependencies: ds, full: full})
       when is_integer(v) and is_list(ss) and is_list(es) and is_map(ds) and is_boolean(full) do
    Enum.all?(ss, &is_binary/1) and length(ss) == MapSet.size(MapSet.new(ss)) and
      MapSet.new(Map.keys(ds)) == MapSet.new(ss) and
      Enum.all?(ds, fn {_, ts} -> is_list(ts) and Enum.all?(ts, &Inputs.valid_token?/1) end) and
      Enum.all?(es, &valid_edge?/1)
  end

  defp valid_batch?(_), do: false

  defp valid_edge?(%{from_id: a, to_id: b, kind: k, uncertain: u} = e),
    do:
      is_integer(a) and a > 0 and is_integer(b) and b > 0 and is_binary(k) and is_boolean(u) and
        (is_nil(e[:line]) or (is_integer(e.line) and e.line > 0))

  defp valid_edge?(_), do: false

  defp validate_edges(conn, repo, batch) do
    owners = owner_ids(conn, repo, batch.sources)
    ids = batch.edges |> Enum.flat_map(&[&1.from_id, &1.to_id]) |> Enum.uniq()

    found =
      ids
      |> Enum.chunk_every(500)
      |> Enum.flat_map(fn chunk ->
        rows(conn, "SELECT id FROM node WHERE repo_id=? AND id IN (#{marks(chunk)})", [
          repo | chunk
        ])
      end)
      |> MapSet.new(& &1.id)

    cond do
      Enum.any?(ids, &(not MapSet.member?(found, &1))) -> {:error, :foreign_node}
      Enum.any?(batch.edges, &(not MapSet.member?(owners, &1.from_id))) -> {:error, :source_scope}
      true -> :ok
    end
  end

  defp owner_ids(conn, repo, ss) do
    ss
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      rows(conn, "SELECT id FROM node WHERE repo_id=? AND key IN (#{marks(chunk)})", [
        repo | chunk
      ])
    end)
    |> MapSet.new(& &1.id)
  end

  defp publish(conn, repo, revision, batch, state) do
    ss = Enum.sort(batch.sources)

    deps =
      Map.new(batch.dependencies, fn {owner, ts} -> {owner, Enum.uniq(ts) |> Enum.sort()} end)

    owners = publication_rows(conn, "SELECT id,key FROM node", repo, "key", ss, batch.full)
    keys = Map.new(owners, &{&1.id, &1.key})

    by_owner =
      batch.edges
      |> Enum.map(&{&1.from_id, &1.to_id, &1.kind, &1.uncertain, &1[:line]})
      |> Enum.group_by(fn {from, _, _, _, _} -> Map.fetch!(keys, from) end)
      |> Map.new(fn {key, edges} -> {key, edges |> Enum.uniq() |> Enum.sort()} end)

    old =
      publication_rows(
        conn,
        "SELECT id,owner_key,digest FROM resolve_source",
        repo,
        "owner_key",
        ss,
        batch.full
      )
      |> Map.new(&{&1.owner_key, &1})

    digests =
      Map.new(ss, fn owner ->
        {owner,
         :crypto.hash(
           :sha256,
           Inputs.encode({batch.version, Map.get(by_owner, owner, []), deps[owner]})
         )}
      end)

    changed =
      Enum.filter(ss, fn owner ->
        case old[owner] do
          nil -> true
          previous -> previous.digest != digests[owner]
        end
      end)

    changed_set = MapSet.new(changed)
    ids = for n <- owners, MapSet.member?(changed_set, n.key), do: n.id

    # On first coverage (or a read-set-only change), existing edges may already
    # be correct. Read only the changed owners, then retain identical edge rows.
    existing =
      ids
      |> Enum.chunk_every(500)
      |> Enum.flat_map(fn chunk ->
        query(
          conn,
          "SELECT from_id,to_id,kind,uncertain,line FROM edge WHERE from_id IN (#{marks(chunk)})",
          chunk
        ).rows
      end)
      |> Enum.map(fn [from, to, kind, uncertain, line] ->
        {from, to, kind, uncertain == 1, line}
      end)
      |> Enum.group_by(fn {from, _, _, _, _} -> Map.fetch!(keys, from) end)
      |> Map.new(fn {key, edges} -> {key, Enum.sort(edges)} end)

    edge_changed = Enum.filter(changed, &(Map.get(existing, &1, []) != Map.get(by_owner, &1, [])))
    edge_set = MapSet.new(edge_changed)
    edge_ids = for n <- owners, MapSet.member?(edge_set, n.key), do: n.id
    # IDs are globally unique and checked against this repo above. Including a
    # repo predicate here made SQLite scan the repo index once per chunk.
    for chunk <- Enum.chunk_every(edge_ids, 500),
        do: query(conn, "DELETE FROM edge WHERE from_id IN (#{marks(chunk)})", chunk)

    insert(
      conn,
      "edge",
      ~w(repo_id from_id to_id kind uncertain line),
      for(
        owner <- edge_changed,
        {from, to, kind, uncertain, line} <- Map.get(by_owner, owner, []),
        do: [repo, from, to, kind, if(uncertain, do: 1, else: 0), line]
      )
    )

    live =
      MapSet.new(
        Enum.map(owners, & &1.key) ++
          Enum.map(
            scoped(conn, "SELECT DISTINCT from_key FROM ref", repo, "from_key", ss),
            & &1.from_key
          )
      )

    # Only changed sources replace their read sets. Coverage revision is the
    # revision at which the output changed, not the latest full pass.
    old_ids = for owner <- changed, old[owner], do: old[owner].id

    for chunk <- Enum.chunk_every(old_ids, 500),
        do:
          query(
            conn,
            "DELETE FROM resolve_dependency WHERE source_id IN (#{marks(chunk)})",
            chunk
          )

    retired = Enum.reject(changed, &MapSet.member?(live, &1))

    for chunk <- Enum.chunk_every(retired, 200),
        do:
          query(
            conn,
            "DELETE FROM resolve_source WHERE repo_id=? AND owner_key IN (#{marks(chunk)})",
            [repo | chunk]
          )

    live_changed = Enum.filter(changed, &MapSet.member?(live, &1))

    insert(
      conn,
      "resolve_source",
      ~w(repo_id owner_key revision version digest),
      Enum.map(live_changed, &[repo, &1, revision, batch.version, {:blob, digests[&1]}]),
      "",
      " ON CONFLICT(repo_id,owner_key) DO UPDATE SET revision=excluded.revision,version=excluded.version,digest=excluded.digest"
    )

    tokens = live_changed |> Enum.flat_map(&deps[&1]) |> Enum.uniq()

    insert(
      conn,
      "resolve_token",
      ~w(repo_id token),
      Enum.map(tokens, &[repo, blob(&1)]),
      "OR IGNORE"
    )

    if live_changed != [] do
      token_ids =
        publication_rows(
          conn,
          "SELECT id,token FROM resolve_token",
          repo,
          "token",
          Enum.map(tokens, &blob/1),
          batch.full
        )
        |> Map.new(&{&1.token, &1.id})

      source_ids =
        publication_rows(
          conn,
          "SELECT id,owner_key FROM resolve_source",
          repo,
          "owner_key",
          live_changed,
          batch.full
        )
        |> Map.new(&{&1.owner_key, &1.id})

      insert(
        conn,
        "resolve_dependency",
        ~w(source_id token_id),
        for(
          owner <- live_changed,
          token <- deps[owner],
          do: [source_ids[owner], Map.fetch!(token_ids, Inputs.encode(token))]
        )
      )
    end

    for chunk <- Enum.chunk_every(ss, 200),
        do:
          query(
            conn,
            "DELETE FROM resolve_pending WHERE repo_id=? AND owner_key IN (#{marks(chunk)})",
            [repo | chunk]
          )

    if batch.full and state.lookup_version != Inputs.version(),
      do: replace_tables(conn, repo, batch.lookups, :all)

    query(
      conn,
      "INSERT INTO resolve_revision(repo_id) VALUES (?) ON CONFLICT(repo_id) DO NOTHING",
      [repo]
    )

    if batch.full,
      do:
        query(
          conn,
          "UPDATE resolve_revision SET complete=1,version=?,lookup_version=? WHERE repo_id=?",
          [batch.version, Inputs.version(), repo]
        )

    if (batch.full or (state.complete and state.version == batch.version)) and
         rows(conn, "SELECT 1 FROM resolve_pending WHERE repo_id=? LIMIT 1", [repo]) == [] do
      query(conn, "UPDATE resolve_revision SET resolved_revision=revision WHERE repo_id=?", [
        repo
      ])

      query(conn, "DELETE FROM resolve_changed WHERE repo_id=?", [repo])
    end

    query(conn, "DELETE FROM write_batch WHERE repo_id=? AND kind='edges'", [repo])

    :ok
  end

  defp replace_tables(conn, repo, tables, path) do
    for {name, cols, key} <- [
          {"resolve_import", ~w(path member target), :imports},
          {"resolve_path", ~w(path node_count ref_count), :paths},
          {"resolve_file_suffix", ~w(suffix path), :file_suffixes},
          {"resolve_doc_suffix", ~w(suffix node_id path), :doc_suffixes}
        ] do
      if path == :all,
        do: query(conn, "DELETE FROM #{name} WHERE repo_id=?", [repo]),
        else: query(conn, "DELETE FROM #{name} WHERE repo_id=? AND path=?", [repo, path])

      insert(
        conn,
        name,
        ["repo_id" | cols],
        Enum.map(Map.fetch!(tables, key), &[repo | &1]),
        "OR IGNORE"
      )
    end
  end

  defp blob(token), do: {:blob, Inputs.encode(token)}
  defp marks(values), do: Enum.map_join(values, ",", fn _ -> "?" end)

  defp insert(conn, table, columns, data, modifier \\ "", suffix \\ "") do
    for chunk <- Enum.chunk_every(data, 200) do
      tuple = "(" <> marks(columns) <> ")"

      query(
        conn,
        "INSERT #{modifier} INTO #{table} (#{Enum.join(columns, ",")}) VALUES " <>
          Enum.map_join(chunk, ",", fn _ -> tuple end) <> suffix,
        List.flatten(chunk)
      )
    end

    :ok
  end

  defp query(conn, sql, args \\ []), do: Exqlite.query!(conn, sql, args, timeout: :infinity)

  defp rows(conn, sql, args \\ []) do
    %{columns: cols, rows: rs} = query(conn, sql, args)
    keys = Enum.map(cols, &String.to_atom/1)
    Enum.map(rs, &(Enum.zip(keys, &1) |> Map.new()))
  end
end
