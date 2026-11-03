-- Case records (design §8), in cases.db, apart from the graph (E23): every task
-- the loop runs, whole and in order, for training the local model later. An
-- event is written before the loop moves on, and large or non-UTF-8 text is a
-- file under <state_dir>/cases/<id>/, written before the row that names it.
CREATE TABLE IF NOT EXISTS task_case (
  id TEXT PRIMARY KEY,
  repo TEXT NOT NULL,
  task TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open',
  report TEXT,
  opened_at INTEGER NOT NULL,
  closed_at INTEGER
);

CREATE TABLE IF NOT EXISTS case_event (
  case_id TEXT NOT NULL REFERENCES task_case(id),
  seq INTEGER NOT NULL,
  kind TEXT NOT NULL,
  at INTEGER NOT NULL,
  data TEXT NOT NULL,
  PRIMARY KEY (case_id, seq)
);

-- Anomalies (design §13.5): a backstop that fired, or a progress limit hit.
-- One open row per kind and subject until it is acknowledged, so a repeating
-- fault is one investigation request with a count, never a flood (J6).
CREATE TABLE IF NOT EXISTS anomaly (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,
  subject TEXT NOT NULL,
  evidence TEXT NOT NULL,
  load TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 1,
  at INTEGER NOT NULL,
  last_at INTEGER NOT NULL,
  sent INTEGER NOT NULL DEFAULT 0,
  acked_at INTEGER
);

-- VORTEX admission and response delivery share the case transaction.
CREATE TABLE IF NOT EXISTS vortex_request (
  case_id TEXT PRIMARY KEY REFERENCES task_case(id),
  peer TEXT NOT NULL,
  room TEXT NOT NULL,
  request_id TEXT NOT NULL,
  task TEXT NOT NULL,
  state TEXT NOT NULL,
  frontier TEXT,
  returned_fix TEXT,
  lease TEXT,
  released INTEGER NOT NULL DEFAULT 1,
  UNIQUE(peer, request_id)
);
CREATE TABLE IF NOT EXISTS vortex_outbox (
  id TEXT PRIMARY KEY,
  case_id TEXT NOT NULL REFERENCES task_case(id),
  peer TEXT NOT NULL,
  room TEXT NOT NULL,
  type TEXT NOT NULL,
  body TEXT NOT NULL,
  receipt INTEGER NOT NULL DEFAULT 1,
  acked INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS vortex_classification (
  peer TEXT NOT NULL,
  cursor INTEGER NOT NULL,
  reason TEXT NOT NULL,
  PRIMARY KEY(peer,cursor)
);

-- Generic permission request lifetime is independent of the preserved case.
CREATE TABLE IF NOT EXISTS permission_request (
  id TEXT PRIMARY KEY,
  case_id TEXT NOT NULL REFERENCES task_case(id),
  version INTEGER NOT NULL,
  state TEXT NOT NULL,
  deadline_at INTEGER NOT NULL,
  record TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS permission_case ON permission_request(case_id);
