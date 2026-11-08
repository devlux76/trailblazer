defmodule Trailblazer.Store.Repos do
  @moduledoc "Registered repositories and each one's indexed state: its id, whether it is watched, the HEAD its graph matches and the paths dirty at that HEAD."

  alias Trailblazer.Files
  import Trailblazer.Store, only: [read: 1, run: 1]
  import Trailblazer.Store.Sql

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
end
