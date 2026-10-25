# Trials

## 2026-10-18: acceptance on sojourney

**Why sojourney.** The operator chose `/home/mirai/projects/sojourney` as the
test bed: substantial development (125 TypeScript, 46 Python and 54 Markdown
files among 2,898), and easy to roll back. Trailblazer only reads the
repository; its git state was recorded before and after every run and never
changed (HEAD `8956bfe`, two untracked files that were there before).
Trailblazer was never pointed at its own repository.

**How.** Seventeen tasks, each with its expected answer written down before the
first run, from `rg` and reading the code by hand. The first run called the
core in-process with a throwaway state directory (the API was not built yet);
the second ran through the deployed service and the `trailblazer` CLI. Phase 1
makes no model calls, so every task is a question with one right answer, and
every failure is a **harness** failure unless the embedding model is at fault.

**Machine.** CPU only. EmbeddingGemma 2 on `:8091` (768 dimensions), Qdrant
1.19 on `:6333`.

### Results

| # | Task | Expected | First run (in-process, before fixes) | Deployed service (after fixes) |
| --- | --- | --- | --- | --- |
| T1 | `where touchLayoutActive` | `src/core/isMobile.ts:12` | pass | pass |
| T2 | `uses touchLayoutActive` | call sites at `PlayerController.ts:162`, `Play.ts:266`, `startGame.ts:39` | pass; line 162 credited to the class | pass; line 162 credited to `PlayerController.constructor` |
| T3 | `where WeatherSampler` | `src/sky/Weather.ts:33` | pass | pass |
| T4 | `impact weatherAt` | `tests/weatherSampler.test.ts` | **fail**: empty | pass |
| T5 | `uses stepBob` | `PlayerController.ts:621` | pass (`PlayerController.follow`) | pass |
| T6 | `uses FireState` | `src/play/Campfire.ts` | **fail**: empty | pass; also found `harness/campfireTransitions.ts`, which the hand-written answer missed |
| T7 | `where tile_heights` (Python) | `tools/ground_mesh.py:40` | pass | pass |
| T8 | `uses tile_heights` | three calls in `tools/build_ground.py` | **fail**: empty (predicted) | pass, with the import |
| T9 | `where src/play/Campfire.ts:7` (an import) | `FireState` | **fail**: empty | pass |
| T10 | read outside the repository | refused | pass | pass |
| T11 | read a range | the lines | pass | pass (`read --text` prints them raw) |
| T12 | stale citations | none real | **fail**: 4 false positives | pass: 0 |
| T13 | `search "head bob"` | `stepBob`, `bobOffset` | pass: top four are `headBob.ts`, `bobOffset`, `PlayerController.follow`, `stepBob` | same |
| T14 | `search "how is the weather chosen for a day"` | `daySchedule`, `weatherAt` | pass: `daySchedule` first, then `WeatherSampler`, `WEATHER.md` §schedule, `weatherAt` | same |
| T15 | trail: "the head bob is too strong when walking slowly" | `stepBob`, `bobOffset`, `PlayerController.follow` | relevant code present, but whole-file items and a cut last item | `PlayerController.follow`, `stepBob`, `bobOffset` in full in the top six |
| T16 | trail with `src/play/fireRules.ts:20` in the request | `FireState`, `Campfire` | present, with whole-file noise | `FireState` first, then `Campfire.act`, `Campfire.find` |
| T17 | trail: "add a new kind of weather: fog", with `Weather.ts` | Weather's definitions, `Fog` | present, plus every function named `add` | Weather's definitions in full, then `Fog`, `fogDensity`, haze; no `add` noise |

Final: **17 of 17**.

### Failures and their causes

Every failure was in the harness. The embedding model was not at fault: both
searches put the right definitions first.

| Finding | Cause | Fix | By |
| --- | --- | --- | --- |
| T4, T6, T9 | References outside any definition (`from_key: nil`) were left unresolved, so every JS/TS import line and every call inside a test file's top-level `test(() => …)` made no edge | each JS/TS/Python file gets a whole-file node that owns those references (H1) | Codex, `6100d2b` |
| T6 | `new FireState()` was not a use, and TS constructors were not definitions | constructor calls, class and type references kept; `Class.constructor` (H2) | Codex, `6100d2b` |
| T8 | Python modules resolved from the repository root only; scripts import their neighbours (`from ground_mesh import …`) | the importing file's directory first (H3) | Codex, `6100d2b` |
| first sync 215 s | the resolver rescanned every ref and node per file (104 s), uncached tree-sitter queries, and a second sync on watch | indexed lookups, cached queries, one sync (H4); first watch **11.8 s** | Codex, `6100d2b` |
| T12 | in Markdown a bare `§5` was tied to the last document named in the paragraph, and bare file names were forced into `docs/` | in Markdown a section counts only right after the document it names; paths kept as written and matched by their end (A11, H5) | Claude `b155c96`, Codex `6100d2b` |
| T15–T17 | whole-file nodes packed as items; the separator between parts was not counted, so the last item was cut; plain words ("add") seeded every function with that name | whole-file nodes walked but not packed; separators counted (H2); only identifier-shaped or backticked words seed by name (A12) | Claude `27b4496` |

Found while deploying, and fixed the same day:

- Two stores (the throwaway run and the service) named a repository's Qdrant
  collection by its path alone, so ids from one database would have met points
  from the other (E10, `094a6d6`).
- A database made by an earlier build lacked two newer columns; they are now
  added in place, never by erasing the database (E8, `8b6a8f9`).
- After a restart the service forgot which repositories it watched (E11,
  `276af54`: tests by Codex, implementation by Claude).
- `inotify-tools` was not installed, so the deployed service never followed
  file changes and said so only in one log line. It is installed now, and
  without a watcher the indexer polls every 15 s and `status` reports
  `following` (E12, `e6ac1ba`). A file created in sojourney was seen in 4 s
  and its deletion in 4 s.
- `uses` gave two identical-looking rows for a name defined twice (each row
  now names its target), and `read` had no raw-text output (`2847255`).

### Figures (deployed service, sojourney)

| | |
| --- | --- |
| Files indexed | 229 |
| Definitions (nodes) | 2,542 |
| Edges | 9,796 |
| First watch (graph) | 11.8 s |
| Watch with nothing changed | 4.7 s |
| Embedding | 2,542 definitions in about 53 minutes, 0.8 per second, batches of 16 |
| Stale citations | 0 |

Embedding speed is the CPU embedder's; ranger's own indexer runs at about
0.55 chunks per second on this machine. It is not a harness limit, and the
graph answers in full while embedding runs.

### Known limits, not failures

- A trail's last 40% is a long tail of signatures; most are relevant, some are
  only near the seeds (`sin`, `set`).
- `uses` lists the import line of each file alongside the calls in it; both are
  uses, but an AI reading for call sites may want to skip the import rows.
- The vector half of the mirai-agent run (below) is still to do.

## 2026-10-18: live run against mirai-agent, graph only

mirai-agent is a live system whose embedder (`:8091`) Mirai uses, so this run
indexed the graph only: in-process, a throwaway state directory, embedding
paused, no file watcher. Nothing was written to the repository (clean at
`b2b3297` before and after) or to Qdrant.

| | |
| --- | --- |
| Files | 395 |
| Definitions | 5,381 |
| Edges | 14,799 |
| Graph build | 5.1 s |
| Uncertain edges | 124 (0.8%) |
| Stale citations | 264, in 87 files (the status document counts 98 files citing old documents) |

Questions, against `rg` and against ranger
(`python3 ~/.claude/skills/ranger/index.py -C ~/projects/mirai-agent -q …`):

- **What uses `Memory.Recall`.** Trailblazer: `Acts.Recall.run/2`
  (`acts/recall.ex:45`), `Life.recall/1` (`life.ex:702`), `Lumina.Reverie`, and
  the tests that exercise them, each with its line. `rg` agrees on the three
  library files exactly. Ranger gave no answer within 5 minutes: its index of
  mirai-agent was stale and it re-embeds before it answers (1,325 chunks from
  170 files, about 40 minutes).
- **What changing `Store.transaction` affects.** Trailblazer: 153 definitions
  within two hops (`Conversation.Store.open/fetch/list/rename/…`,
  `Memory.add/embed/carry/…`, the Store tests at distance 1). Ranger: as above,
  no answer within 5 minutes.
- **Where a VORTEX message is turned into a stimulus for Mirai.** A question
  of meaning, which needs vectors: about 5,381 definitions to embed, roughly
  two hours of the shared embedder. Left for the operator to schedule.

For questions of structure (who uses, what is affected, where declared) the
graph answers in seconds with no embedding at all; ranger can answer nothing
until its whole index is current.

## 2026-10-18: phase 2 (L9), Trailblazer codes on sojourney

`trailblazer run` against the deployed service, model `qwen3.6-35b-a3b:mtp-q4` on the CPU, sojourney at
8956bfe (its checkout is never touched: every task works in its own worktree under the state directory
and leaves a `trailblazer/<case>` branch). Expected outcomes were written down before any run. Each
result is triaged as harness or model (operator's rule).

| # | Task | Check | Expected |
|---|---|---|---|
| T1 | One-line behaviour change: `DownloadEstimate` says "About 120 min left" for two hours; from 60 minutes up it should say hours, e.g. "About 2 h left". Add a test. | `bun test tests/downloadEstimate.test.ts` | `fixed`: one changed line in `src/ui/DownloadEstimate.ts`, one new test. |
| T2 | Rename `easeTowards` to `easeToward` everywhere (pose.ts, headBob.ts, PlayerController.ts). | `! grep -rn easeTowards src tests && bun test` | `fixed`: three files, no other change. |
| T3 | New pure function `formatDuration(seconds)` in `src/ui/formatDuration.ts` ("45s", "3 min", "2 h 5 min") with tests in `tests/formatDuration.test.ts`. | `bun test tests/formatDuration.test.ts` | `fixed`: two new files. |
| T4 | Add a hand-written `clamp(value, min, max)` helper to `src/core/pose.ts` and use it in `clampPitch` and `reclineTilt`; design: AGENTS.md rule 1, "Babylon first" (Babylon ships `Scalar.Clamp`). | `bun test` | Either `fixed` using Babylon's `Scalar.Clamp` (the design followed), or `failed` with review findings citing the rule. A committed hand-written clamp is a failure of the review. |

The first live run, before these, was on a scratch repository (calc.py, `add` returning `a - b`): Qwen's
blocks were right all three times but named `lib/greeting.ex` (the prompt's example) and `lib/calc.py`;
the feedback did not name the real file, so a one-character fix failed. Harness: fixed as D17 (Aider's
file-name resolution) and a prompt rule.

### Router prompt cache (P0, 2026-10-18 evening)

Found during L9 T1: every attempt after a review re-read the whole prompt. The router ran Qwen with
`parallel = 1` and `cache-ram = 0`, and warned at every load: `--cache-idle-slots requires --cache-ram,
disabling`. Prefix reuse within the one slot worked (smoke run 2, attempt 2: "selected slot by LCP
similarity, f_keep = 0.867", 191 tokens processed), but any other request (our reviewer, a ranger query,
Mirai) took the slot and the coder's state was discarded: attempt 3 after its review was "selected slot
by LRU" and re-read all 1,154 tokens; on T1 that is ~7,200 tokens, ~11 minutes.

Fix (Claude, operator's go-ahead while Codex was out of usage; Codex to review): mirai-agent
`config/llama-router.ini`, Qwen section, `cache-ram = 2048`, router restarted. Measured with T1's real
coder prompt (`cache_measure.py` in the job's tmp; one generated token per call):

| Call | Prompt tokens | From cache | First token |
|---|---|---|---|
| coder, cold (includes ~42 s model load) | 6,551 | 0 | 360 s |
| reviewer, a different prompt | 1,876 | 0 | 89 s |
| coder retry with appended failure | 6,581 | 6,039 | **34 s** |

The warning is gone. Also seen: prefill ran at ~28 tokens/s after the restart against 8-11 before it.
Before, Qwen's llama-server had 5.2 GB of its memory in swap (RSS 15.6 GB); after, RSS 24.9 GB and
150 MB in swap. Memory pressure is the second item for Codex (secondary, by the operator's call).

### Live T1 after B4 (2026-10-18, 21:20-21:59)

`Loop.run` in an isolated test state directory (no trail, D21; head start: the check command), real
Qwen through the router with the cache fix. Case 20261019-032000-ae3a38.

| Step | Prompt tokens | Time | Result |
|---|---|---|---|
| coder | 2,509 (Files 4.4 KB, system 1.3 KB, Request 184 B, Check 71 B) | read 121 s, reasoning 12,972 B, total 1,586 s | one SEARCH/REPLACE block, applied |
| check | | 33 ms | `bun test tests/downloadEstimate.test.ts`: 5 pass |
| reviewer | 785 | 769 s, reasoning 6,851 B | PASS |

Report: `fixed`, attempts 1, commit f4c38d1 on `trailblazer/20261019-032000-ae3a38` (2 files: the one
changed line, one new test). Sojourney's checkout unchanged (8956bfe, the two known untracked files).
Total 2,365 s.

Triage: **no harness fault.** The prompt is 38% of T1's first live run (6,551 tokens). The time is the
model: ~8 B/s of reasoning on this CPU, 13 KB of it before a one-line edit and 7 KB before "PASS".
Open question for the harness, not a fault: a reviewer that needs 13 minutes to say PASS on a passing
check could be given a reasoning budget or no-think mode; measure on T2-T4 before deciding. The report
summary is the model's first sentence ("I will update ..."), future tense; cosmetic.

### Live T2-T4 after B12 (2026-10-18 23:25 to 2026-10-19 00:40)

Same setup as T1: `Loop.run` in an isolated test state directory, real Qwen through the router. The
isolated instance watches nothing, so every trail was `{:error, :not_watched}` (D21) and the coder got
whole files instead. Sojourney's checkout unchanged afterwards (8956bfe, the two known untracked files).

| Case | Coder prompt | Coder | Check | Reviewer | Report |
|---|---|---|---|---|---|
| T2 rename (3 files) | 10,147 tokens (Files 31.4 KB), read 994 s | 1,765 s, reasoning 5 KB | pass, 1 s | 1,237 tokens, 239 s, PASS | `fixed`, 1 attempt, d87fb67, 2,010 s |
| T3 new function + tests | 1,179 tokens, read 106 s | 903 s, reasoning 8.5 KB | pass, 21 ms (3 tests) | 698 tokens, 308 s, PASS | `fixed`, 1 attempt, 2d3a34e, 1,218 s |
| T4 hand-written clamp | 1,782 tokens (1,039 cached), read 67 s | 720 s, reasoning 7.8 KB | pass, 218 ms | 603 tokens, 474 s, PASS | `fixed`, 1 attempt, 243f1a5, 1,203 s |

Triage:

- **T2, harness (known, D21):** 56% of the coder's time was reading three whole files. With a trail
  (deployed service, B11) the coder gets the definitions and call sites as excerpts. Measure in B11.
- **T3, harness, fixed:** the reply was unfenced blocks alone (`path`, then `<<<<<<< SEARCH`), which
  `Edits` accepts but `explanation/1` did not split on, so the summary and commit message were the
  last lines of the REPLACE text. The fence is now optional there too; test "a reply of unfenced
  blocks alone still gets a summary".
- **T4, review failure, as the expected outcome defines it:** a hand-written clamp was committed and
  the reviewer said PASS. Both coder and reviewer had the "Babylon first" rule (Design, 197 B); both
  followed the request against it. Harness part: neither prompt said which wins when the request and
  the design disagree; now both say the design wins (coder: do it the design's way and say so;
  reviewer: FAIL citing the design). Remaining part: the reviewer has no tools, so "does Babylon
  provide it?" rests on the model's memory of `Scalar.Clamp`. Next harness step, not done: look the
  request's new helper names up in the installed dependency sources and put the hits in the Design
  section. Rerun T4 after either change.
- **T4, model habit handled by the harness:** the coder named its file `lib/greeting.ex`, the prompt's
  example, again; D17/D20 resolution mapped it to `src/core/pose.ts`.
- **Reviewer time:** 239-474 s per PASS on a passing check, 20-40% of each case. No-think or a
  reasoning budget for the reviewer remains open; T4 shows the reviewer is not yet thinking hard enough
  where it matters, so cutting its reasoning waits until the design-rule rerun.

### Deployed B11 closeout (2026-10-19)

Codex inspected the deployed case reports after Claude's weekly usage ended. All four runs are
finished; these results supersede assumptions that the deployed rerun was still in progress.
The generated branches are acceptance artifacts, not approved product changes.

| Trial | Case | Attempts | Reported result | Total time | Prompt / completion tokens |
|---|---|---|---|---|---|
| T1 download hours | `20261019-072205-0a9e7b` | 3 | failed; last check failed | 6,121 s | 13,599 / 19,311 |
| T2 rename | `20261019-090407-66e5a1` | 1 | fixed, `830e73f` | 1,237 s | 13,291 / 1,736 |
| T3 duration function | `20261019-092447-a0c07f` | 1 | fixed, `a4921dc` | 971 s | 3,833 / 3,465 |
| T4 design precedence | `20261019-094100-c04bc4` | 2 | reported fixed, `e245684`; acceptance failed below | 3,280 s | 8,552 / 13,238 |

T1's last test expected `3 h left` for inputs that produce `31 h left`. An earlier attempt also
searched for a test introduced by a prior attempt after the workspace had been reset. The first
is a generated-test arithmetic error; the second needs a deterministic retry-feedback regression
before assigning the cause to the model or harness. Its failed worktree and dossier are retained
in the closeout archive rather than applied to Sojourney.

T4 followed the stated design precedence in words, but imported `MathUtils` from `@babylonjs/core`
and called `MathUtils.Clamp`. The installed package exports `Scalar`, not `MathUtils`.
Codex verified the defect directly on the unchanged Sojourney checkout:

```sh
bun -e 'import { MathUtils } from "@babylonjs/core"; console.log(MathUtils.Clamp(2, 0, 1));'
```

It exits 1: `Export named 'MathUtils' not found`. The case's `bun test` check did not import the
changed module, and the reviewer nevertheless returned PASS. Thus this is not a successful T4:
the model invented an API, and the harness's check and review did not catch it. The next-session
plan requires installed-dependency evidence and a compile check; do not merge this trial commit.

Raw report snapshots and branch/worktree recovery data are under
`/home/mirai/.local/state/codex/closeout-2026-10-19/`. No further local-model trials were started
during closeout. The shared embedder moved to Polaris Vulkan at 02:54 MDT; the benchmark and
capacity checks overlapped this deployed trial window, so these wall times are not isolated
performance measurements.


### Acceptance follow-up, October 19 morning

Codex resumed directly after the OpenCode free daily allowance was exhausted;
OpenCode and its VORTEX connector remain stopped. No generated trial edits were
merged into Sojourney.

The retry regression first failed because the next prompt did not explain its
reset. It now checks that a failed edit's new test file is removed, the original
source is restored, and a complete corrected patch can recreate the test. The
reset explanation is appended only after reset succeeds, after the unchanged
prompt prefix. Reset-failure and three-attempt behavior remain covered.

For Bun tasks naming clamp with a Babylon design rule, installed evidence is
prepared once and shared with coder and reviewer. The initial supported shape
is Babylon's package manifest, root export through `Maths/pure.d.ts`, and the
`Scalar.Clamp` declaration. It reads at most four fixed files, caps each read
at 64 KB, and returns at most 20 entries / 8 KB of paths and excerpts. Unsafe,
absent, oversized or unsupported declarations are explicitly unavailable; there
is no dependency crawling, package installation or model-generated command.
Symlink containment uses the existing repository reader. Tests cover reuse of
the same evidence across retry/review, export-chain failures, path escapes,
size bounds, and an unavailable reviewer leaving the change uncommitted.

On installed Babylon 9.31.0 / Bun 1.4.3, a temporary fixture with an unused
`MathUtils` import reproduced T4's gap: `bun test` passed its unrelated test;
`bun run typecheck` failed with TS2305; a direct Bun import also failed. The
Sojourney checkout was unchanged. Future T4 acceptance must explicitly supply
`bun run typecheck && bun test`, and independently build a proposed success.
The caller's trusted check and `Check.default/1` are unchanged.

Validation: 495 tests passed, 3 live tests excluded, seed 378724; format and
production warnings-as-errors compilation passed. An earlier full run failed
`AnomalyTest`'s guard/global armed-count assertion (observed 1 instead of 0);
the focused run and final full run passed without changing that assertion or
Backstop. This intermittent failure is recorded, not claimed fixed.

Live T1/T4 reruns and reviewer-cost measurements remain pending. Unit tests and
the negative import fixture do not establish local-model acceptance. Logs and
negative-fixture results are retained under
`/home/mirai/.local/state/codex/trailblazer-followup-2026-10-19/`.
