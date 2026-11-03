# Retrieval consolidation: one index, separate from messaging

Date: 2026-11-02. Author: Claude (proposal; Codex to review). Status: proposed.

Bugs: trailblazer:7c6fdfc (p1), trailblazer:565c539 (p2, existing),
ranger:0131422 (p2), scout:3df441f (p2).

## 1. Intent

Everything in this stack rests on one idea: vectors plus a code map make a
coding model much smarter and more grounded. Today that idea is implemented
twice — Trailblazer core in Elixir, and ranger's original index in Python that
Trailblazer was ported from (design.md §9) — and the Python copy is itself
duplicated between the scout and ranger repositories.

The Python index survived by omission, not for reliability. Evidence
(2026-11-02): `trailblazer.service` NRestarts=0; the only failure since
2026-10-20 is a start refusal at 18:31:48 from an invalid VORTEX config
(`erl_crash.dump`, trailblazer:7c6fdfc), not an Elixir fault. The fallback is
also not faster where it claims to help: on a fresh repository it uses the same
EmbeddingGemma 2 server (~30 min on sojourney) and competes with Trailblazer
for it.

The operator's ruling (2026-11-02): **indexing and messaging are separate
services.** The index must start and answer with VORTEX absent or broken.

After this change there is one index (Trailblazer core), one Python client for
it (scout), and ranger depends on scout instead of carrying copies.

## 2. Current state (from code, not specs)

- `Trailblazer.Application.start/2` (application.ex:27) calls
  `Config.get(:vortex)`; a malformed config makes `Vortex.Settings.load!/1`
  raise `ArgumentError` (settings.ex:56) and the whole node stops: Store,
  Indexer, API, Loop.Runner.
- `Planner.Supervisor` is started only when `:vortex` is configured, so
  autonomous dispatch is also coupled to messaging.
- `Watcher` reports `following: :polling` when no file watcher starts, but
  nothing polls (trailblazer:565c539); the index silently goes stale until the
  next request.
- `~/projects/scout` is canonical for `scout.py`, `index.py`,
  `trailblazer.py` (scout:b9c1385). `ranger/` still holds byte-identical
  copies plus `scout.SKILL.md.in`; `ranger/tests/test_index.py` and
  `test_trailblazer.py` test the copies; `install.sh` copies scout's files
  next to `ranger.py` at install time (ranger:0131422).
- `scout.index_candidates` asks Trailblazer, and on unavailable / not watched /
  no hits falls back to `index.sync` + `index.search` (Qdrant collection per
  repo, content-hash incremental) (scout:3df441f).

## 3. Goals, non-goals, anti-goals

Goals
1. Trailblazer starts, indexes and answers `status`, `trail`, `where`, `uses`,
   `impact`, `search` with VORTEX config missing or invalid.
2. One retrieval implementation (Trailblazer core); `index.py` and its Qdrant
   collections are deleted.
3. One copy of the scout client; ranger imports it.
4. When the index cannot answer, callers are told exactly why and what to run,
   rather than silently served a different index.

Non-goals
- Splitting Trailblazer into separate OS processes or repositories. The
  boundary here is supervision and startup, not packaging (packaging is the
  later product question).
- Changing models, the coding loop, or the VORTEX protocol.
- Making scout/ranger portable off Linux (systemctl, inotifywait remain).

Anti-goals — this fails even if it works when
- a VORTEX fault can still stop indexing;
- removing the fallback leaves scout or ranger failing with no actionable
  message;
- ranger's test suite still passes against helpers that differ from the
  installed ones.

## 4. The change, in order

Each step is one bug, landed and reviewed separately, in this order.

### Step 1 — trailblazer:7c6fdfc: index starts without VORTEX
- VORTEX config loading moves out of the boot path's failure domain: an
  invalid config yields "VORTEX unavailable: <reason>" (logged once, visible
  in `trailblazer status` as e.g. `vortex: {state: unavailable, reason}`), and
  the core children start normally.
- `Vortex.Settings.load!/1` keeps its strictness (it is a trust boundary);
  the caller handles the failure. Prefer a `load/1` returning
  `{:ok, opts} | {:error, reason}` with `load!/1` delegating to it.
- Today `Config.get(:vortex)` re-reads and re-parses
  `$TRAILBLAZER_VORTEX_CONFIG` (`~/.config/trailblazer/vortex.json`) through
  `load!` at every call: application.ex:27, config.ex:100,
  planner/research.ex:274, loop/runner.ex:22. So a file broken after boot
  can raise inside Loop.Runner or the research route at run time. Load once
  at boot, keep the `{:ok, _} | {:error, _}` result, and have all four sites
  read that; reloading is an explicit act, not a side effect of a read.
- `trailblazer.service.d` orders the unit `After=`/`Wants=` the
  `vortex-router` and `vortex-trailblazer` units. Keep `Wants` ordering only
  as a soft preference; indexing must not wait on them.
- `Planner.Supervisor` is not part of this step; whether dispatch should run
  without VORTEX is open question 1.
- Tests: invalid JSON, missing keys, and a bad peer policy each leave the API
  answering `status` for a watched fixture repo, with the reason reported.

### Step 2 — trailblazer:565c539: freshness is real
Either implement the 15 s poll the status promises, or report the true state
(`following: none`, reconciled on request) and fix priv/skill/SKILL.md. Codex
and Claude pick in review; the fix must make `status` truthful. Prerequisite
for step 4, because without a fallback, a stale index is the only index.

### Step 3 — ranger:0131422: one scout client
- Delete `ranger/scout.py`, `index.py`, `trailblazer.py`,
  `scout.SKILL.md.in`, and the ranger tests that only cover those modules
  (move any assertion scout lacks into `~/projects/scout/tests`).
- `ranger.py` imports scout from its installed canonical location (the scout
  skill directory, which links to `~/projects/scout`); `install.sh` stops
  copying helpers. Exact import mechanism is the builder's call (a `sys.path`
  insert of the scout skill dir is sufficient); it must be one path, with no
  copy.
- Ranger's remaining tests exercise ranger against real scout modules.

### Step 4 — scout:3df441f: delete the Python index
- On the Trailblazer path scout uses only two things from `index.py`:
  `candidates_text` (formats hits) and `symbol_matches` (ripgrep exact names,
  called with `graph=None`) — checked in scout.py:69-108. Move those two into
  scout (e.g. `scout/format.py`, or into `scout.py`), then delete `index.py`
  entirely: `sync`, `search`, `list_files`, `chunk_file`, and the Python import
  graph (`build_graph`, `symbol_edges`, `file_uses`, `graph_note`,
  `index.structure_text`) are reached only from the fallback branch. Remove
  that branch in `candidates_with_source` and its tests.
- When Trailblazer cannot answer, scout exits 1 with a one-line cause and
  the command to run: service down → `systemctl --user start trailblazer`;
  not watched → it already calls `trailblazer watch`, keep that; vectors still
  building → report `pending_vectors: N` and return graph/exact-name results
  without vector hits (exit 0 if any candidates).
- Drop the per-repo ranger Qdrant collections after the change is deployed
  (list and delete them; Trailblazer's collections untouched).
- Update both SKILL.md files: the "its own index otherwise" text goes.

## 5. Acceptance (whole change)

- With `TRAILBLAZER_VORTEX_CONFIG` pointing at a malformed file (in a test
  or a throwaway state dir, never the live `~/.config/trailblazer/vortex.json`),
  `trailblazer status` and `scout -q` answer for a watched repo, and
  breaking the file after boot does not crash any process.
- `rg -l 'def sync|qdrant' ~/projects/scout ~/projects/ranger` finds no
  index implementation.
- `diff` finds no shared file between ranger and scout; ranger tests import
  scout from the canonical path.
- Existing suites green: `mix test` (trailblazer), scout and ranger unittest.
- Ranger's 3 reference questions still answered with file and line.

## 6. Open questions for review

1. Should `Planner.Supervisor` run without VORTEX? Its research route uses a
   VORTEX conference; its coder route only needs the Loop. Claude's lean:
   yes for the coder route, research route reports unavailable.
2. (Settled by Claude: the Python import graph is used only on the
   fallback path; see step 4.) Is Trailblazer's `structure_text` appendix
   at least as useful as the Python graph's was for ranger's 3 reference
   questions? Step 4's acceptance run answers this.
3. mirai-agent code copied into Trailblazer (design.md §9: ModelClient,
   Tool, Vortex.Client, Embedder) — out of scope here; audit separately for
   drift?

## 7. Left to the builder

Names of new functions and status fields, test fixture layout, commit
granularity within each step.
