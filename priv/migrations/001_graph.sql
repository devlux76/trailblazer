-- Trailblazer's graph. One repository's land: its files, the definitions they
-- hold, the references those definitions make, and the edges the resolver drew
-- between them.
--
-- A node's id is its row id and is also its Qdrant point id, so a vector hit is
-- a graph node with no lookup in between. It stays the same while the node's key
-- exists, so a definition that moves inside a file keeps its identity.

PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS repo (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS file (
  repo_id INTEGER NOT NULL REFERENCES repo(id) ON DELETE CASCADE,
  path TEXT NOT NULL,
  hash TEXT,
  PRIMARY KEY (repo_id, path)
);

CREATE TABLE IF NOT EXISTS node (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo_id INTEGER NOT NULL REFERENCES repo(id) ON DELETE CASCADE,
  key TEXT NOT NULL,
  lang TEXT,
  kind TEXT NOT NULL,
  name TEXT,
  qualified TEXT,
  path TEXT NOT NULL,
  start_line INTEGER NOT NULL,
  end_line INTEGER NOT NULL,
  signature TEXT,
  text_hash TEXT,
  stale INTEGER NOT NULL DEFAULT 0,
  vector_hash TEXT,
  UNIQUE (repo_id, key)
);

CREATE INDEX IF NOT EXISTS node_repo_name ON node (repo_id, name);
CREATE INDEX IF NOT EXISTS node_repo_qualified ON node (repo_id, qualified);
CREATE INDEX IF NOT EXISTS node_repo_path ON node (repo_id, path);

-- A ref is a reference as it was parsed: named, not yet resolved. The file it
-- came from is kept on it, so replacing or deleting that file takes the refs
-- it contributed with it, whether or not they sit inside a definition.
CREATE TABLE IF NOT EXISTS ref (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo_id INTEGER NOT NULL REFERENCES repo(id) ON DELETE CASCADE,
  path TEXT NOT NULL,
  from_key TEXT,
  kind TEXT NOT NULL,
  target TEXT NOT NULL,
  ambiguous INTEGER NOT NULL DEFAULT 0,
  arity INTEGER,
  line INTEGER
);

CREATE INDEX IF NOT EXISTS ref_repo_path ON ref (repo_id, path);

CREATE TABLE IF NOT EXISTS edge (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo_id INTEGER NOT NULL REFERENCES repo(id) ON DELETE CASCADE,
  from_id INTEGER NOT NULL REFERENCES node(id) ON DELETE CASCADE,
  to_id INTEGER NOT NULL REFERENCES node(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  uncertain INTEGER NOT NULL DEFAULT 0,
  line INTEGER
);

CREATE INDEX IF NOT EXISTS edge_from ON edge (from_id);
CREATE INDEX IF NOT EXISTS edge_to ON edge (to_id);
CREATE INDEX IF NOT EXISTS edge_repo ON edge (repo_id);
-- A call site is (from_id, line): counting its targets is how the trail walk
-- tells an ambiguous name resolution from a real link.
CREATE INDEX IF NOT EXISTS edge_site ON edge (from_id, line);
-- Tombstones survive service outages and indexer restarts.
CREATE TABLE IF NOT EXISTS vector_delete (
  repo_id INTEGER NOT NULL REFERENCES repo(id),
  node_id INTEGER NOT NULL,
  PRIMARY KEY (repo_id, node_id)
);

-- Shared across repositories and retained when a repository changes or goes away.
CREATE TABLE IF NOT EXISTS embedding_cache (
  model TEXT NOT NULL,
  hash TEXT NOT NULL,
  vector BLOB NOT NULL,
  PRIMARY KEY (model, hash)
);

-- Case records moved to 002_cases.sql, a database of their own (E23). Tables
-- made here before are left in place, never erased (E8).

-- Last applied payload per logical write, retained across commit/ack gaps.
CREATE TABLE IF NOT EXISTS write_batch (
  repo_id INTEGER NOT NULL REFERENCES repo(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  path TEXT NOT NULL,
  digest BLOB NOT NULL,
  PRIMARY KEY (repo_id, kind, path)
);
