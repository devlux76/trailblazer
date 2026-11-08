defmodule Trailblazer.Store.Resolution.Publish do
  @moduledoc "Publishes a resolver batch: checks it against the stored revision and graph, then writes its edges, sources, dependencies and tokens in one transaction."

  alias Trailblazer.Graph.Inputs
  import Trailblazer.Store.Resolution, only: [ensure: 1, header: 2, sources: 2]
  import Trailblazer.Store.Resolution.Sql

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
      |> Enum.map(&{&1.from_id, &1.to_id, &1.kind, &1.uncertain, &1[:line], &1[:provenance]})
      |> Enum.group_by(fn {from, _, _, _, _, _} -> Map.fetch!(keys, from) end)
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
          "SELECT from_id,to_id,kind,uncertain,line,provenance FROM edge WHERE from_id IN (#{marks(chunk)})",
          chunk
        ).rows
      end)
      |> Enum.map(fn [from, to, kind, uncertain, line, provenance] ->
        {from, to, kind, uncertain == 1, line, provenance}
      end)
      |> Enum.group_by(fn {from, _, _, _, _, _} -> Map.fetch!(keys, from) end)
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
      ~w(repo_id from_id to_id kind uncertain line provenance),
      for(
        owner <- edge_changed,
        {from, to, kind, uncertain, line, provenance} <- Map.get(by_owner, owner, []),
        do: [repo, from, to, kind, if(uncertain, do: 1, else: 0), line, provenance]
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
end
