defmodule Trailblazer.StoreUpgradeTest do
  use ExUnit.Case, async: false

  alias Trailblazer.{Query, Store}

  # E8 in the register: a database made by an earlier build is brought up to
  # date in place, never erased.
  test "E8: columns added since a database was made are added to it, rows kept" do
    db = Path.join(System.tmp_dir!(), "trailblazer-old-#{System.unique_integer([:positive])}.db")
    {:ok, conn} = Exqlite.start_link(database: db, pool_size: 1)

    for sql <- [
          "CREATE TABLE repo (id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL UNIQUE)",
          "CREATE TABLE node (id INTEGER PRIMARY KEY AUTOINCREMENT, repo_id INTEGER NOT NULL, key TEXT NOT NULL, lang TEXT, kind TEXT NOT NULL, name TEXT, qualified TEXT, path TEXT NOT NULL, start_line INTEGER NOT NULL, end_line INTEGER NOT NULL, signature TEXT, text_hash TEXT, stale INTEGER NOT NULL DEFAULT 0, vector_hash TEXT, UNIQUE (repo_id, key))",
          "CREATE TABLE ref (id INTEGER PRIMARY KEY AUTOINCREMENT, repo_id INTEGER NOT NULL, path TEXT NOT NULL, from_key TEXT, kind TEXT NOT NULL, target TEXT NOT NULL, arity INTEGER, line INTEGER)",
          "INSERT INTO repo (path) VALUES ('/old')",
          "INSERT INTO ref (repo_id, path, kind, target) VALUES (1, 'a.ex', 'calls', 'M.f')"
        ] do
      Exqlite.query!(conn, sql, [])
    end

    assert :ok = Store.migrate(conn)
    assert :ok = Store.migrate(conn)

    columns = fn table ->
      %{rows: rows} = Exqlite.query!(conn, "PRAGMA table_info(#{table})", [])
      Enum.map(rows, &Enum.at(&1, 1))
    end

    assert "revision" in columns.("resolve_revision")
    assert "token_id" in columns.("resolve_dependency")
    assert "token" in columns.("resolve_token")
    assert "ref_count" in columns.("resolve_path")
    assert %{rows: []} = Exqlite.query!(conn, "SELECT * FROM resolve_revision", [])

    assert %{rows: [["ref_repo_source"], ["resolve_readers"]]} =
             Exqlite.query!(
               conn,
               "SELECT name FROM sqlite_master WHERE type='index' AND name IN ('ref_repo_source','resolve_readers') ORDER BY name",
               []
             )

    assert "ambiguous" in columns.("ref")
    assert "ord" in columns.("node")
    assert "watched" in columns.("repo")
    assert "indexed_dirty" in columns.("repo")
    assert %{rows: [[0]]} = Exqlite.query!(conn, "SELECT watched FROM repo", [])
    assert %{rows: [["M.f", 0]]} = Exqlite.query!(conn, "SELECT target, ambiguous FROM ref", [])
    assert %{rows: [["/old"]]} = Exqlite.query!(conn, "SELECT path FROM repo", [])

    GenServer.stop(conn)
    File.rm(db)
  end

  # C4, Codex's repro of 2109f6a: stable ids must not decide which of two
  # definitions sharing a line is the later one; the parser's order does.
  test "C4: nodes come back in the parser's order after the file is reordered" do
    dir = Path.join(System.tmp_dir!(), "trailblazer-order-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {:ok, repo_id} = Store.add_repo(dir)

    index = fn source ->
      File.write!(Path.join(dir, "m.ex"), source)
      {:ok, parsed} = Trailblazer.Parse.Elixir.parse("m.ex", source)
      :ok = Store.replace_file(repo_id, "m.ex", Map.put(parsed, :hash, source))
    end

    index.("defmodule M do\n  def z, do: :ok; def a, do: :ok # needle\nend\n")
    index.("defmodule M do\n  def a, do: :ok; def z, do: :ok # needle\nend\n")

    assert Enum.map(Store.nodes_in_file(repo_id, "m.ex"), & &1.qualified) == [
             "M",
             "M.a/0",
             "M.z/0"
           ]

    down = [embed: __MODULE__.DownEmbed, indexer: __MODULE__.NoFresh]
    assert [%{node: %{qualified: "M.z/0"}} | _] = Query.search(dir, "needle", 10, down)
    File.rm_rf!(dir)
  end

  defmodule DownEmbed do
    def query(_text, _opts), do: {:error, :embedder_down}
  end

  defmodule NoFresh do
    def ensure_fresh(_repo, _files), do: :ok
  end
end
