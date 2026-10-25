-- Stage 1 records resolver inputs; it does not enable incremental selection.
CREATE INDEX IF NOT EXISTS ref_repo_source ON ref(repo_id,from_key);
CREATE TABLE IF NOT EXISTS resolve_import (
 repo_id INTEGER NOT NULL REFERENCES repo(id), path TEXT NOT NULL,
 member TEXT NOT NULL, target TEXT NOT NULL, PRIMARY KEY(repo_id,path,member,target)
);
CREATE TABLE IF NOT EXISTS resolve_path (
 repo_id INTEGER NOT NULL REFERENCES repo(id), path TEXT NOT NULL,
 node_count INTEGER NOT NULL, ref_count INTEGER NOT NULL, PRIMARY KEY(repo_id,path)
);
CREATE TABLE IF NOT EXISTS resolve_file_suffix (
 repo_id INTEGER NOT NULL REFERENCES repo(id), suffix TEXT NOT NULL,
 path TEXT NOT NULL, PRIMARY KEY(repo_id,suffix,path)
);
CREATE INDEX IF NOT EXISTS resolve_file_suffix_path ON resolve_file_suffix(repo_id,path);
CREATE TABLE IF NOT EXISTS resolve_doc_suffix (
 repo_id INTEGER NOT NULL REFERENCES repo(id), suffix TEXT NOT NULL,
 node_id INTEGER NOT NULL, path TEXT NOT NULL, PRIMARY KEY(repo_id,suffix,node_id)
);
CREATE INDEX IF NOT EXISTS resolve_doc_suffix_path ON resolve_doc_suffix(repo_id,path);
-- Intern repeated lookup tokens and owners once; the read relation holds only IDs.
CREATE TABLE IF NOT EXISTS resolve_token (
 id INTEGER PRIMARY KEY, repo_id INTEGER NOT NULL REFERENCES repo(id),
 token BLOB NOT NULL, UNIQUE(repo_id,token)
);
CREATE TABLE IF NOT EXISTS resolve_source (
 id INTEGER PRIMARY KEY, repo_id INTEGER NOT NULL REFERENCES repo(id), owner_key TEXT NOT NULL,
 revision INTEGER NOT NULL, version INTEGER NOT NULL, digest BLOB,
 UNIQUE(repo_id,owner_key)
);
CREATE TABLE IF NOT EXISTS resolve_dependency (
 source_id INTEGER NOT NULL REFERENCES resolve_source(id) ON DELETE CASCADE,
 token_id INTEGER NOT NULL REFERENCES resolve_token(id), PRIMARY KEY(source_id,token_id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS resolve_readers ON resolve_dependency(token_id,source_id);
CREATE TABLE IF NOT EXISTS resolve_pending (
 repo_id INTEGER NOT NULL REFERENCES repo(id), owner_key TEXT NOT NULL,
 PRIMARY KEY(repo_id,owner_key)
);
CREATE TABLE IF NOT EXISTS resolve_changed (
 repo_id INTEGER NOT NULL REFERENCES repo(id), token BLOB NOT NULL,
 PRIMARY KEY(repo_id,token)
);
-- Created last: this is also the marker for the atomic migration on hot-load.
CREATE TABLE IF NOT EXISTS resolve_revision (
 repo_id INTEGER PRIMARY KEY REFERENCES repo(id), revision INTEGER NOT NULL DEFAULT 0,
 resolved_revision INTEGER NOT NULL DEFAULT 0, version INTEGER NOT NULL DEFAULT 0,
 complete INTEGER NOT NULL DEFAULT 0, lookup_version INTEGER NOT NULL DEFAULT 0
);
