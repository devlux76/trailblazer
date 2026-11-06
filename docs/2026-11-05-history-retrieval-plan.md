# History retrieval: git as the preseed for the coding loop

Date: 2026-11-05. Status: plan, not started. Owner of the design: the operator;
written up by Claude.

## Why

Trailblazer's local coders (Bolt codes, Spark plans and reviews) fail mostly on
form, not reasoning. They copy SEARCH text inaccurately, invent context, and
loop. The fallback patches we pay the frontier for teach the system nothing.
We have no preseed. A model sees each task cold.

But every repository we own is already a database of solved problems. A commit
cites a `bug:<id>`, the git-bug card holds the request and the
"Implementation plan:", the diff is the change, and whether the card closed
and the change survived is the outcome. About 370 commits across our repos
already carry `bug:` refs (trailblazer 126, vortex 95, llama.cpp 35, opencode
28, resonant 25, ranger 16, mirai-agent 15, planner 11, frontier 10), plus
every commit without one, plus every attempt in Trailblazer's case records,
failed ones included.

The operator's call, and the shape of this plan: embed all of it at fine
grain. EmbeddingGemma is built for "find every mention of X in a huge personal
corpus". LFM3 already reranks Trailblazer trails. The point is density: the
more samples there are to choose from, the more likely a query finds genuinely
relevant ones near the top. (The operator's "0.90" was an illustration of that,
not a threshold; clarified 2026-11-05.) The reranker picks the best few, and
those go into the prompt as worked examples in the exact edit format the model
must write. It will take time to build and a long while to embed. That cost is
accepted.

## Part 1 (prerequisite): line-range edits, applied by diff and patch

The examples are only useful in a format the model can actually produce.

1. Text-mode coder prompt: drop SEARCH/REPLACE for edits. The model gets
   numbered source (as now) and answers with the **same JSON range blocks tool
   mode uses**, in a `json` fence. `Tools.text_edit_blocks/1`
   (`loop/tools.ex`) already parses that from a text reply, and `Edits.parse/1`
   is SEARCH-only today. No new syntax. Part 1 is mostly a prompt change plus
   wiring text mode to the range path.
2. **Keep the first/last-line quotes mandatory.** They are the anchors
   (`edits.ex` relocates on a unique quote match and refuses otherwise) that
   stop a 4B model's miscounted range from silently overwriting the wrong
   lines.
3. **Digest optional in text mode.** A small model copying 64 hex chars will
   hallucinate them, and the anchors already catch stale ranges. Tool mode
   keeps its digest.
4. **File creation:** range blocks need an existing file (`read_full` →
   `:no_such_file`). Keep the empty-SEARCH block as the single creation case,
   or add an explicit create action. Pick whichever the tests make simpler.
5. The host splices the ranges into a scratch copy, writes a unified diff with
   `diff -u`, and applies it to the case worktree with `git apply --check`
   then `git apply`. Watch new files (`-N`) and CRLF. The diff is what review
   reads and what is committed. Our own matcher is no longer in the apply
   path. This is vendored "sensory" tooling, per standing policy.
6. Overlap, bounds and anchor failures are refused with feedback that quotes
   the current numbered lines. That machinery already exists.
7. Looping: `Loop.looping_blocks?/1` is SEARCH-specific. The no-op signal
   becomes an **empty diff**, repeated (host_stop is `Model`'s finish
   mechanism and is unchanged).

Check: the loop and edits suites; one live case on a real card.

## Part 2: the history corpus

### Unit of storage

One entry is one commit × one file's hunks:

| field | source |
|---|---|
| repo, commit, parent, author date | git |
| bug id | `bug:<id>` in the message (none for commits without one) |
| request | card title + body + the "Implementation plan:" note (git-bug); otherwise the commit subject and body |
| path | the file |
| patch | that file's unified diff, cut at hunk boundaries to fit the embedder |
| outcome | see Labels |
| case | Trailblazer case id, model, attempts, local/frontier, check result (from the git note, see below) |

Trailblazer case attempts become entries too. Every attempt's patch is
recorded with its outcome (check failed, review rejected, passed), so failed
patches sit next to the ones that worked on the same request.

### What gets embedded

The document text is `title: <path> | text: <request>\n<patch>` (the
EmbeddingGemma document prompt). Hunks are packed per entry up to the model's
input limit, and a file whose diff overflows that limit is split into several
entries that share the request. The query is the case's design text + plan +
target paths, embedded with the query prompt. One collection holds all repos,
tagged by repo (as `Memory` already does), so recall works across repos. Same
768-wide vectors, same Qdrant, all behind `Trailblazer.Vectors`, so the
LadybugDB move later replaces the store and not the design.

### Labels

- **succeeded**: the card is done (or the commit has no card), the commit was
  never reverted, and no later commit citing the same bug changed the same
  lines within 24 h.
- **fixed-up**: a later same-bug commit changed the same lines. Both commits
  become entries, and the later one is the better example.
- **reverted**: a revert commit names it.
- **attempt-failed / attempt-rejected**: from case records, with the first
  concrete failure or the review reason.

Labels are recomputed when history moves. An entry's label can only get worse
(a later revert) or more certain (it survives longer).

### Git notes

Starting with Part 2, every integration writes a note under
`refs/notes/trailblazer` on the commit: case id, Trailblazer version, coder
and reviewer models, attempts, local or frontier, check result. The backfill
writes the same notes for past commits it can match to case records (by bug id
plus tree). Notes never rewrite history and are never pushed unless the
operator says so.

### Ingest

- **Backfill**: walk `git log --all` per repo, oldest first, with `git bug`
  JSON for cards. Resumable via a cursor per repo. Rate-limited so the embedder
  (:8091) stays usable for the live indexer, behind the existing `EmbedGate`.
  Order: our own repos first (bug-ref commits, then the rest), then case
  records, then the upstream history of vendored repos (llama.cpp, opencode).
  Upstream history is large (thousands of commits) and goes in as a separate
  tag that recall can include or exclude.
- **Live**: the indexer already calls `git.changed(path, head)` when the
  watcher reports a HEAD move (`indexer.ex`). Corpus ingest hangs off the
  same event, and Loop records each attempt as it ends.
- **Point ids**: never `:erlang.phash2` (31-bit; Qdrant silently overwrites on
  collision, unsafe past about 10k points). Use a UUID derived from
  sha256(repo, commit, path, chunk) and check for collisions on write. The
  same fix applies to `Memory.point_id/1` before it grows.
- Measure throughput on a 500-commit sample first, then project the full
  backfill time and report it before running it.

### Privacy (operator, 2026-11-05)

The repos were squashed on 2026-10-25 to redact PII that AI tools had written
into history. That is why the commit rules are strict. The corpus is a new
copy of history and must not become a way around that redaction.

- **One screen, the same one the commit rules use**:
  `~/.config/git/pii-patterns` (as used by the global commit-msg hook), plus
  the absolute-home-path rule. Every text field is checked before it is
  embedded or stored: request, commit message, patch, case attempt and review
  reason. A match drops the entry and logs only its commit and field, never
  the text. The corpus never keeps its own copy of the patterns.
- **Unscreened sources get the most suspicion.** git-bug card bodies and
  comments, and Trailblazer case records (whole prompts with source), never
  pass through the commit hooks.
- **Reachable history only**: real branches and tags. Never `--all`, never
  `refs/bugs`, never the reflog, and never objects that a squash left
  unreachable.
- **Derived data follows git.** Entries are keyed by commit. A commit that is
  no longer reachable (squashed, rewritten, redacted) is purged from the
  vectors and JSONL on the next ingest pass. Because the backfill is
  resumable, a full rebuild after a redaction is cheap.
- **Prompts that leave the machine** (the frontier fallback dossier) carry
  examples only after they pass the screen. The screen runs again at render
  time, so a pattern added later still applies.

## Part 3: recall into the prompt

1. Query: design + plan + paths → Qdrant top-k (start at 200) → LFM3 rerank.
   No fixed cosine floor. `Trail.Rerank`'s moduledoc records EmbeddingGemma
   putting related and unrelated *code* in a 0.6-0.8 band, so absolute scores
   say little; rank among many candidates is what matters. A floor is added
   only if the density probe (step 0) shows a clean gap that cuts junk
   without losing true siblings.
2. Exclusions: never return the case's own bug id, commits at or after the
   case base, or anything from the case's own branch. This is mandatory or the
   replay eval cheats.
3. LFM3 reranks the survivors against the request, using the same plumbing
   as `Trail.Rerank.select/3` but with a new selection prompt (the current one
   ranks code locations by signature, not patch examples), and keeps up to 3 succeeded examples plus at most 1
   failed attempt on the closest request, shown as "this was tried and failed
   because …".
4. Each example is rendered in the coder's edit format: diff hunks converted to
   range blocks against the pre-change file. That conversion is mechanical,
   and the parent blob gives the line numbers.
5. The examples go into a "Similar past changes" section of the coder prompt
   with its own token budget. The planner and Spark's planning step get the
   same section, so frontier plans can get cheaper too.

`Memory`'s "nothing reaches a coder prompt" rule is changed here
deliberately. Examples are real, labeled history, not drawn lessons. Each one
is shown with its label and date, and each prompt records which entries it
used so outcomes can be traced back to examples.

## Part 4: measure

- **Replay eval**: closed cards with a host check, rerun at their base commit
  with and without examples (exclusions on). Only about 10-12 such cards exist
  per repo, and 11 of 12 recorded outcomes failed, so a pass-rate delta over
  20 cards can't be resolved. Instead:
  - Run paired, within card, 3 runs per arm, per repo (vortex TypeScript and
    trailblazer Elixir separately).
  - Primary metric: **first-apply success**, the fraction of replies whose
    first batch parses, anchors hold, ranges are in bounds and the diff
    applies. This is the "form" problem the examples target.
  - Secondary metrics: attempts to pass, check failures, refusals and no-op
    attempts, tokens, frontier fallbacks.
  - Draw the eval set from case records across repos if closed cards run
    short (about 34 vortex cases are on disk).
  - Never calibrate on the eval set: use an older era or skip calibration.
- **Live**: frontier fallback rate per card, before and after, from case
  records and notes.
- Calibrate k and example count on the replay set. Report similarity
  histograms and the density curve (sibling recall@k vs corpus size).

## Order and gates

| # | step | gate |
|---|---|---|
| 0 | **Density probe** (one script, no infra): embed the baseline entries to JSONL, brute-force cosine for each replay query; report sibling rank (recall@k) and how it moves as the corpus grows (subsample 25/50/100%), plus histograms against true siblings; count the replay cards that still have a plausible example after exclusions | curve + histogram reported to the operator; picks k (and a floor only if a clean gap shows); if fewer than about 10 of 20 cards have a sibling, widen the corpus first |
| 1 | Part 1: JSON range blocks in text mode + diff/patch | suites green, one live card |
| 2 | corpus schema + ingest for the baseline only (operator, 2026-11-05): owned repos trailblazer, vortex, ranger, planner, scout, mirai-agent, sojourney (not resonant, sojourney2, frontier); real branches/tags only, no squash snapshots, no `refs/bugs`. About 276 unique patches / about 918 code entries (about 259 bug-citing commits), nearly all trailblazer + vortex, plus case attempts. Expand (e.g. opencode upstream as a tagged set) only if the probe/eval says density is the limit | entries + labels spot-checked by Claude |
| 3 | throughput sample, projected backfill time | reported to the operator |
| 4 | git notes on integration + backfill of notes from case records | notes visible on v6-impl commits |
| 5 | recall + rendering + prompt section | unit tests; exclusions tested |
| 6 | replay eval with and without | numbers reported |
| 7 | full backfill (own repos, then case records, then upstream) | runs in the background, resumable |

Each step is a card, and each card is coded through the pipeline itself where
it can be (planner → Trailblazer), with the frontier fallback as usual.

## Peer review record

- 2026-11-05, GLM (OpenCode, read-only, verified against code;
  `~/.local/share/claude-handoff/glm-reply.md`). Folded in: a density probe first
  (step 0; operator later clarified 0.90 was an illustration of density, not a
  threshold, so the probe measures recall vs corpus size and retrieval is
  top-k + rerank); JSON range blocks in
  text mode (no new syntax); mandatory anchor quotes; optional digest in text
  mode; a file-creation path; looping detected on empty diffs; sha-based point
  ids; a new rerank prompt; a paired, per-repo eval on first-apply success.
  Rejected one claim: "`Git.changed/2` has no caller". The indexer calls it
  through the injected git module.
- Codex: out of usage until 2026-11-10; no review. Ask then if a second look
  is still useful.
