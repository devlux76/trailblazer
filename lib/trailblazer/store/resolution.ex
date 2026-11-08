defmodule Trailblazer.Store.Resolution do
  @moduledoc false
  alias Trailblazer.Graph.Inputs
  alias Trailblazer.Store.Resolution.Publish
  import Trailblazer.Store.Resolution.Sql
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

  defdelegate replace(conn, repo, revision, batch), to: Publish
end
