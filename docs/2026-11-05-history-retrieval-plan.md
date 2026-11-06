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
corpus". LFM3 already reranks Trailblazer trails. With a dense corpus, a query
does not get a hundred weak matches spread over 0..1. It gets a couple of
dozen strong ones in roughly 0.90..1, the reranker picks the best few, and
those go into the prompt as worked examples in the exact edit format the model
must write. It will take time to build and a long while to embed. That cost is
accepted.

## Part 1 (prerequisite): line-range edits, applied by diff and patch

The examples are only useful in a format the model can actually produce.

1. Text-mode coder prompt: drop SEARCH/REPLACE. The model gets numbered source
   (as now) and answers with range blocks ("replace lines A-B of PATH with:"
   then the new text, or an insert after line A). It never retypes existing
   code. `Loop.Edits` already has a `:range` block type with a digest (tool
   mode). Text mode reuses it.
2. The host splices the ranges into a scratch copy, writes a unified diff with
   `diff -u`, and applies it to the case worktree with `git apply --check`
   then `git apply`. The diff is what review reads and what is committed. Our
   own matcher is no longer in the apply path. This is vendored "sensory"
   tooling, per standing policy.
3. Range blocks that overlap, fall outside the file, or carry a stale digest
   are refused with feedback that quotes the current numbered lines. Overlap
   detection, bounds and digests already exist.
4. host_stop: the looping detector moves from no-op SEARCH blocks to repeated
   identical range blocks.

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
- **Live**: the watcher already sees HEAD move (`Git.changed/2`). New commits
  on watched repos are ingested on that event, and Loop records each attempt
  as it ends.
- Measure throughput on a 500-commit sample first, then project the full
  backfill time and report it before running it.

## Part 3: recall into the prompt

1. Query: design + plan + paths → Qdrant top 200 → keep cosine ≥ a threshold.
   The threshold starts at 0.90 and is calibrated on held-out cards in step 5,
   since EmbeddingGemma's similarity spread for code is not known yet.
2. Exclusions: never return the case's own bug id, commits at or after the
   case base, or anything from the case's own branch. This is mandatory or the
   replay eval cheats.
3. LFM3 reranks the survivors against the request, using the same reranker
   path as `Trail.rerank`, and keeps up to 3 succeeded examples plus at most 1
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

- **Replay eval**: the last 20 closed cards with a host check, rerun at their
  base commit with and without examples (exclusions on). Metrics: local pass
  rate, attempts to pass, frontier fallbacks, tokens.
- **Live**: frontier fallback rate per card, before and after, from case
  records and notes.
- Calibrate the threshold and example count on the replay set. Report
  similarity histograms, so we can see whether matches really cluster at
  0.90..1.

## Order and gates

| # | step | gate |
|---|---|---|
| 1 | Part 1: range edits + diff/patch | suites green, one live card |
| 2 | corpus schema + ingest for one repo (trailblazer), no recall | entries + labels spot-checked by Claude |
| 3 | throughput sample, projected backfill time | reported to the operator |
| 4 | git notes on integration + backfill of notes from case records | notes visible on v6-impl commits |
| 5 | recall + rendering + prompt section | unit tests; exclusions tested |
| 6 | replay eval with and without | numbers reported |
| 7 | full backfill (own repos, then case records, then upstream) | runs in the background, resumable |

Each step is a card, and each card is coded through the pipeline itself where
it can be (planner → Trailblazer), with the frontier fallback as usual.
