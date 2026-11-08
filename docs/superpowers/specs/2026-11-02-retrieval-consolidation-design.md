# Retrieval consolidation: one index, separate from messaging

Date: 2026-11-02. Author: Claude; design reviewed by Codex. Status: approved
for implementation. Implementation and deployment acceptance remain on the
individual cards below; merging this design does not close them.

Bugs: trailblazer:7c6fdfc (p1), ranger:0131422 (p2), scout:3df441f (p2).
Related, found while writing this: trailblazer:c1a47cb (p2, research route
transport). trailblazer:565c539 (watcher reported `polling`) is already fixed
by 09cf67e (`following: :on_request`); it is not part of this change.

Calls marked **[Claude's call]** were settled by Claude after a builder
review; reviewers should check them.

## 1. Intent

Everything in this stack rests on one idea: vectors plus a code map make a
coding model much smarter and more grounded. Today that idea is implemented
twice — Trailblazer core in Elixir, and ranger's original index in Python that
Trailblazer was ported from (design-2.md §9) — and the Python copy is itself
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
  `Config.get(:vortex)`, which re-reads `$TRAILBLAZER_VORTEX_CONFIG`
  (`~/.config/trailblazer/vortex.json`) through `Vortex.Settings.load!/1` on
  every call. A malformed file raises `ArgumentError` (settings.ex:56) and the
  node stops: Store, Indexer, API, Loop.Runner. The same read happens at
  config.ex:100, planner/research.ex:274 and loop/runner.ex:22, so a file
  broken after boot can raise at run time.
- `Config.get(:planner)` has the same pattern (`Board.load_config!` per
  read), today only reached under `Planner.Supervisor`.
- The live config sets `resource_mode: "dedicated"`: Loop.Runner is not a
  core child but runs under `Vortex.Supervisor` beside `Vortex.Resource`,
  which grants exclusive local inference only while Mirai is offline;
  `Runner.submit` refuses direct work in that mode.
- `Planner.Supervisor` starts only when `:vortex` is configured.
- `trailblazer.service.d/10-bringup-order.conf`: `Wants=` ranger-qdrant,
  ranger-embed, vortex-trailblazer, mirai-llama-router; `After=` those plus
  vortex-router.
- Freshness: every API answer first reconciles the repo with git
  (`api.ex` `fresh/2`); with no file watcher, `status` says
  `following: on_request` (09cf67e). Answers are not served stale.
- `~/projects/scout` is canonical for `scout.py`, `index.py`,
  `trailblazer.py` (scout:b9c1385). `ranger/` still holds byte-identical
  copies plus `scout.SKILL.md.in`; `ranger/tests/test_index.py` and
  `test_trailblazer.py` test the copies; `install.sh` copies scout's files
  beside `ranger.py` in `~/.claude/skills/ranger/` and
  `~/.agents/skills/ranger/` (ranger:0131422).
- `scout.candidates_with_source` (scout.py:69-108) asks Trailblazer; on
  unavailable / not watched / no hits it falls back to `index.sync` +
  `index.search` and the Python import graph (scout:3df441f). On the
  Trailblazer path it still uses `index.candidates_text` and
  `index.symbol_matches(graph=None)`.
- `ranger.py:28,236` gets `(index, trailblazer)` from
  `scout.skill_modules()`; its system prompt (ranger.py:273-277) describes
  the Python import-graph notes.

## 3. Goals, non-goals, anti-goals

Goals
1. Trailblazer starts, indexes and answers `status`, `trail`, `where`, `uses`,
   `impact`, `search` with VORTEX config missing or invalid.
2. One retrieval implementation (Trailblazer core); `index.py` and ranger's
   Qdrant collections are deleted.
3. One copy of the scout client; ranger imports it.
4. When the index cannot answer, callers are told exactly why and what to run,
   rather than silently served a different index.

Non-goals
- Splitting Trailblazer into separate OS processes or repositories. The
  boundary here is supervision and startup, not packaging.
- Renaming services or units (`ranger-qdrant`, `ranger-embed` are shared
  infrastructure Trailblazer uses; naming is the later product question).
- Changing models, the coding loop, or the VORTEX protocol.
- Making scout/ranger portable off Linux.

Anti-goals — this fails even if it works when
- a VORTEX fault can still stop indexing;
- an unreadable config lets the coder run outside the resource gate and
  contend with Mirai for inference;
- removing the fallback leaves scout or ranger failing with no actionable
  message;
- ranger's tests or its installed skill still run helpers that differ from
  scout's canonical ones.

## 4. The change, in order

Three steps, each one bug, landed and reviewed separately in this order.

### Step 1 — trailblazer:7c6fdfc: index starts without VORTEX
- Add `Vortex.Settings.load/1` returning `{:ok, opts} | {:error, reason}`;
  `load!/1` delegates to it and keeps its strictness (trust boundary).
- Load once at boot; keep the result (e.g. `:persistent_term` or app env)
  and have all four `Config.get(:vortex)` sites read it. Reloading is an
  explicit act, not a side effect of a read. `Config.get(:vortex)` keeps
  returning the keyword list or `nil`; status gains
  `vortex: %{state: :ok | :unavailable | :not_configured, reason}`.
- **Unreadable config fails closed for coding [Claude's call].** The intent
  (dedicated or not) cannot be known, so: core children (Store, Indexer,
  API, EmbedGate, …) start; no Loop.Runner, no Vortex children, no Planner.
  `trailblazer run` / submit returns `{:error, :vortex_unavailable}` with the
  reason. No config at all (env var unset) keeps today's behaviour: a
  standalone Runner.
- **Planner config gets the same treatment [Claude's call]**: load once,
  `{:error, _}` disables the Planner with a status reason instead of raising.
  Today unreachable without VORTEX, but it must not become the next boot
  crash if the open question below is answered "yes".
- Unit file: drop `vortex-trailblazer` from `Wants=` and `vortex-router` /
  `vortex-trailblazer` from `After=` so indexing never waits on messaging;
  keep the embedder, Qdrant and model-router dependencies.
- trailblazer:c1a47cb (research transport shape) is a separate fix and
  lands separately; step 1 must not change the shape `Config.get(:vortex)`
  returns, so it neither fixes nor worsens it.
- Tests: invalid JSON, missing keys, bad peer policy, bad resource mode —
  each leaves `status` answering for a watched fixture repo with the reason,
  no Runner started, submit refused; breaking the file after boot crashes
  nothing.

### Step 2 — ranger:0131422: one scout client
- Delete `ranger/scout.py`, `index.py`, `trailblazer.py`,
  `scout.SKILL.md.in`, and the ranger tests that only cover those modules
  (move any assertion scout lacks into `~/projects/scout/tests`).
- `ranger.py` imports scout from the scout skill directory (which links to
  `~/projects/scout`), inserted first on `sys.path`. `install.sh` stops
  copying helpers **and deletes** `scout.py`, `index.py`, `trailblazer.py`
  from both installed ranger dirs; otherwise the stale copies beside
  `ranger.py` win the import.
- Ranger's remaining tests exercise ranger against the real scout modules.

### Step 3 — scout:3df441f: delete the Python index
- Move `candidates_text` and `symbol_matches` (the only parts used on the
  Trailblazer path) into scout; delete `index.py`: `sync`, `search`,
  `list_files`, `chunk_file` and the Python import graph (`build_graph`,
  `symbol_edges`, `file_uses`, `graph_note`, `index.structure_text`). Remove
  the fallback branch in `candidates_with_source` and its tests.
- `skill_modules()` returns only the Trailblazer client (callers updated:
  scout.py, ranger.py:28,236). Ranger's system prompt (ranger.py:273-277) is
  rewritten to describe Trailblazer's appendix, not the Python graph.
- When Trailblazer cannot answer, the scout CLI exits 1 with one line of
  cause and the command to run: service down →
  `systemctl --user start trailblazer`; first sync of a newly watched repo
  still running → wait up to the existing endpoint timeout, then exit 1
  "indexing <repo>, retry" **[Claude's call]**; vectors still building →
  report `pending_vectors: N`, return graph and exact-name results without
  vector hits (exit 0 if any candidates).
- **Ranger keeps going without candidates [Claude's call]**: today's
  behaviour, with the cause printed once on stderr; its search loop works
  without them, only slower.
- After deploy, delete ranger's per-repo Qdrant collections (list first;
  Trailblazer's collections untouched).
- Update both SKILL.md files: the "its own index otherwise" text goes.

## 5. Acceptance (whole change)

- With `TRAILBLAZER_VORTEX_CONFIG` pointing at a malformed file (in a test or
  a throwaway state dir, never the live `vortex.json`), `trailblazer status`
  and `scout -q` answer for a watched repo, no coder runs, and breaking the
  file after boot crashes nothing.
- No `def sync` / `def search` index implementation remains in
  `~/projects/scout` or `~/projects/ranger` (main checkouts; worktrees
  excluded) **[Claude's call: narrowed from a `qdrant` grep, which matches
  the shared `ranger-qdrant` unit by design]**.
- No file is shared between ranger and scout, in the repos or in the
  installed skill dirs.
- Existing suites green: `mix test` (trailblazer), scout and ranger unittest.
- Ranger's 3 reference questions still answered with file and line —
  this also answers whether Trailblazer's `structure_text` appendix is at
  least as useful as the Python graph's was.

## 6. Open questions

1. **Operator:** should the Builder (Loop.Runner) and Dispatcher (Planner)
   run without VORTEX? Today both are tied to it. "Yes" means the coder
   route needs its own resource gate when Mirai's dedicated mode is not
   reachable; that is a separate bug and design, not part of step 1.
2. **Review:** mirai-agent code copied into Trailblazer (design-2.md §9:
   ModelClient, Tool, Vortex.Client, Embedder) — audit separately for drift?

## 7. Left to the builder

Names of new functions and status fields, where the loaded result is kept,
test fixture layout, commit granularity within each step.
