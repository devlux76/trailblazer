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
  alias Trailblazer.Config
  alias Trailblazer.Store.{Edges, Reads, Repos, Resolution, ResolutionAccess, Vectors, Writes}
  import Trailblazer.Store.Sql

  @schema_path Path.expand("../../priv/migrations/001_graph.sql", __DIR__)
  @external_resource @schema_path
  @schema File.read!(@schema_path)

  # Case records have a database of their own: Trailblazer.CaseStore (E23).

  # Repositories and their indexed state (Store.Repos)
  defdelegate add_repo(path), to: Repos
  defdelegate repos(), to: Repos
  defdelegate watched_repos(), to: Repos
  defdelegate set_watched(repo_id, watched?), to: Repos
  defdelegate indexed_head(repo_id), to: Repos
  defdelegate set_indexed_head(repo_id, head), to: Repos
  defdelegate indexed_dirty(repo_id), to: Repos
  defdelegate set_indexed_git_state(repo_id, head, paths), to: Repos

  # Files and their definitions (Store.Writes)
  defdelegate replace_file(repo_id, path, file), to: Writes
  defdelegate mark_stale(repo_id, path), to: Writes
  defdelegate delete_file(repo_id, path), to: Writes

  # Resolution state (Store.ResolutionAccess)
  defdelegate resolution_state(repo), to: ResolutionAccess
  defdelegate resolution_current?(repo), to: ResolutionAccess
  defdelegate resolution_readers(repo, tokens), to: ResolutionAccess
  defdelegate resolution_dependencies(repo), to: ResolutionAccess
  defdelegate replace_resolved_sources(repo, revision, batch), to: ResolutionAccess
  defdelegate resolution_selected(repo_id, resolver), to: ResolutionAccess
  defdelegate resolution_snapshot(repo_id), to: ResolutionAccess

  # Edges (Store.Edges)
  defdelegate put_edges(repo_id, edges), to: Edges
  defdelegate adjacent_edges(repo_id, ids, opts \\ []), to: Edges
  defdelegate edges_from(ids, kinds \\ nil), to: Edges
  defdelegate edges_to(ids, kinds \\ nil), to: Edges

  # Reads (Store.Reads)
  defdelegate node(id), to: Reads
  defdelegate nodes(ids), to: Reads
  defdelegate nodes_by_name(repo_id, name), to: Reads
  defdelegate nodes_by_qualified(repo_id, qualified), to: Reads
  defdelegate nodes_in_file(repo_id, path), to: Reads
  defdelegate refs(repo_id), to: Reads
  defdelegate graph_snapshot(repo_id), to: Reads
  defdelegate files(repo_id), to: Reads
  defdelegate module_paths(repo_id), to: Reads
  defdelegate counts(repo_id), to: Reads
  defdelegate stale_paths(repo_id), to: Reads

  # Vectors (Store.Vectors)
  defdelegate embedding_cache_get(model, hash), to: Vectors
  defdelegate embedding_cache_put(model, hash, blob), to: Vectors
  defdelegate pending_vectors(repo_id, limit, opts \\ []), to: Vectors
  defdelegate vector_done(pairs), to: Vectors
  defdelegate pending_vector_deletes(repo_id), to: Vectors
  defdelegate vector_deleted(repo_id, ids), to: Vectors

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

  @doc false
  def run(fun), do: request(:write, fun)
  @doc false
  def read(fun), do: request(:read, fun)

  defp request(mode, fun) do
    case GenServer.call(__MODULE__, {:run, mode, fun}, :infinity) do
      {:returned, value} -> value
      {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
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
end
