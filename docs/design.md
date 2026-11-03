# Trailblazer: design

Written 2026-10-17 by Claude, from a design conversation with the
operator. It replaces an earlier "coder" draft, no longer in the repository,
whose parts are reused here (§9). Where this
document says *the operator decided*, that is the operator's call;
where it says *builder's call* or *Claude's call*, it is a default that
can be changed without asking.

Current implementation notes (2026-11-02): this remains a specification,
including requirements not implemented yet. The dated plans are historical;
the following gaps must not be read as completed features:

| Requirement | Current implementation and remaining work |
|---|---|
| Verify a frontier's returned fix (§7.5) | VORTEX stores the return as `waiting_verification`; ancestry, scope, trusted checks and fresh review are not wired. See bug:a3339f5. |
| Integrate and clean a resource-gated task (§7.7) | `Loop.Coordinator` implements integration/archive/cleanup and the HTTP API accepts an explicit `primary`. The current Planner/VORTEX task protocol does not admit `primary`, so those cases stop at a candidate; live gated acceptance remains open in bug:1beebca. There is no age-based prune. |
| Repair a real harness incident (§11) | The incident-emitter and returned-fix end-to-end acceptance remain required, not demonstrated by local coding trials (bug:a3339f5). |
| Event-only observation (§13) | The local bounded-launch cleanup observer currently reads case status every five seconds. It makes no model calls or retries; this is a known exception to reconcile, not an event-driven implementation. |
| Operate running services (§12) | Still deferred; the coding worker has no general restart/deployment authority. |

## 1. What it is, and why

Trailblazer is a local coding tool **for AIs, not for people**, in the
way VORTEX is a collaboration tool for AIs.

Agent models such as LFM2.5-24B, Mirai's conscious mind, are good
agents and poor coders. Until now coding has been delegated over
VORTEX to Claude, Codex and OpenCode (MiniMax M3.1 Flash). That works, and it
is expensive: it spends paid usage, delegates run out of usage close to
the end of a task, and intent gets lost between the brief and the
delegate. The result is design mistakes that are found in review and
fixed inside multi-million-token Claude sessions, where every token
costs the most.

Trailblazer puts the operator-selected local code model (§7.2) in a harness
built for coding. It is not Mirai's harness: a code model placed inside
her two-minds runtime would be confused by it. Trailblazer uses her
**body** (the model router, the embedder, Qdrant, VORTEX) and none of
her **brain**.

The name says what it does. A trailblazer marks the trail so that
others can follow it safely. Its core, a port of ranger to Elixir,
already knows the lay of the land: before the code model asks where
something is, what uses it or what design it follows, the answer is in
front of it.

The name is the operator's choice. Salesforce uses TRAILBLAZER heavily,
and the operator expects to get a waiver before release.

## 2. Who calls it

- **Primary user:** Mirai. A fault in her harness must be able to create a
  Trailblazer case for triage and bounded repair. After three failed local
  attempts, the case goes to an available recognized frontier collaborator
  with its evidence and continuation state. Once that path works, Mirai can
  use it to request tools and features directly.
- **Supporting callers:** Claude, Codex and OpenCode, both for direct work
  and for taking over escalated cases.
- **Eventually:** other people's agents; the operator intends to market
  it.

Callers are models. The report is written for a model to read (§7.6),
and the caller does not watch the run.

## 3. Goals, non-goals, anti-goals

**Goals**
1. Fix what a local model can fix, verified, and commit it on a branch,
   without spending paid tokens.
2. When it cannot fix something, hand a stronger model a dossier good
   enough that the stronger model spends its tokens on the fix, not on
   finding its way around.
3. Keep intent from getting lost: the design behind the code travels
   with every task automatically (§6.4, §7.4).
4. Answer "where is this declared", "what uses this" and "what does
   changing this affect" from a graph, without a model.
5. Record every case completely, so the local model can later be
   trained on its own mistakes (§8).

**Non-goals**
- Being a human-facing coding assistant: no chat UI, no TUI.
- Mirai's minds, memory or experience. Trailblazer has none of them.
- Training the model. v1 only records the data (§8).
- Acting on running services (restarts, config changes). Deferred; see
  §12.

**Anti-goals: this fails even if it works when**
- it commits code that passes the check but breaks the design;
- it spends more of the caller's tokens than doing the work directly
  would have (long reports, a babysitting loop, vague escalations);
- it keeps trying a fix it cannot make instead of escalating.

## 4. Constraints

- **Hardware.** The coding preset is CPU-only with 6 threads. Earlier
  Qwen/MTP measurements (about 24 GB loaded, 8–11 prompt tokens/s under
  swap pressure) describe that historical deployment, not Spark's current
  memory use or throughput. Every token in the prompt still has to earn
  its place (§6.5); measure the active deployment rather than inferring
  capacity or time from those old runs.
- **No timing assumptions** (the operator decided, §13). How long
  anything takes depends on the machine's load; work moves by messages,
  and time is only a backstop.
- **Embedding is slow:** EmbeddingGemma 2 manages about 0.4 code chunks
  a second here. The first full index of a repo takes hours, so
  re-embedding must be incremental.
- **Resource coordination.** Standalone core retrieval has no global
  inference-lock requirement. Dedicated coding mode is the explicit
  exception: `Vortex.Resource` holds the shared kernel flock while its
  inference lease is granted, requires the other runtime offline, and
  verifies router unload before releasing ownership. This serializes
  cooperating inference clients, not arbitrary processes on the host.
- **Toolchain:** Erlang/OTP and Elixir as mirai-agent pins them;
  dependencies at latest while developing, pinned at release.
- **Licence:** the Aider-derived parts are Apache-2.0 and carry the
  attribution in `NOTICE` at the repository root.

## 5. The path of one task

| # | Stage | Done by | What happens |
|---|---|---|---|
| 1 | Intake | caller | Request, repo, optionally files, design sections and a check command (§7.1). |
| 2 | Workspace | Trailblazer | A worktree and branch for the task (§7.7). |
| 3 | Trail | core | Entry points by vector search, then a graph walk; the trail is packed within a budget (§6.5). |
| 4 | Attempt | code model | Edits as SEARCH/REPLACE blocks; the core re-indexes what changed. |
| 5 | Check | the project's check command | Format, compile, tests. |
| 6 | Review | code model, against the design sections | Does the diff do what was asked, only that, as the design says? |
| 7 | Retry or escalate | Trailblazer | Stages 4–6 fail: try again, at most 3 attempts. After the third, escalate with a dossier (§7.5). |
| 8 | Commit | Trailblazer | Only after check and review both pass. |
| 9 | Report | Trailblazer | To the caller (§7.6). The case is recorded (§8). |

## 6. The core

The core is ranger, ported to Elixir, kept running, and given a graph.
Today's ranger (`~/.claude/skills/ranger/`, about 800 lines of Python)
indexes 40-line chunks and has a regex graph of imports and top-level
names for JS and Python. The core replaces both.

### 6.1 Parsing

- **Elixir** with Elixir's own parser (`Code.string_to_quoted` with
  columns and token metadata). It is exact, and Elixir is the language
  of most of the work.
- **Every other language** with tree-sitter, run as an external OS
  process behind an Erlang Port, never as a NIF, so a parser crash
  costs that process and not the VM. The operator agreed to
  tree-sitter on that condition.
- **v1 languages (Claude's call):** Elixir, TypeScript/JavaScript
  (VORTEX) and Python (ranger, tools). The other grammars come when a
  repo needs them.

### 6.2 The graph

Nodes are **definitions**: modules, functions (by name and arity),
types, test cases, and **sections of design documents**. Each has a
stable id derived from its repo, kind and qualified name (not its line
number, so a move within a file keeps the id).

Edges (builder's call on the exact set; these are the minimum):

- `contains`: module → function, document → section
- `calls` / `references`: function → function or module
- `imports` / `aliases` / `uses`: module → module
- `tests`: test case → what it exercises
- `implements`: code → the design section it cites (§6.4)

**Name resolution** decides which definition a call means: aliases,
imports, `use` macros and module attributes in Elixir; imports and
re-exports in TS and Python. It is where the real work of the graph
lies. An edge the resolver cannot settle (a dynamic call, `apply/3`, a
computed import) is kept and marked *uncertain*, never silently
dropped.

The graph lives in the core's memory (ETS or `:digraph`, builder's
call) and is saved to SQLite so a restart does not re-parse
everything.

### 6.3 Vectors

Qdrant holds **one point per definition**, not the raw tree and not
line windows. The point id is the graph node's id, so a vector hit is a
graph node with no lookup in between. The vector embeds the
definition's text under a short header (its module, signature, and the
names it calls). The payload holds path, line range, kind, language,
name and a content hash. Only a definition whose hash changed is
re-embedded.

The core keeps its own collections, separate from today's ranger
collections, so the ranger skill keeps working until the core replaces
it.

### 6.4 Design documents are part of the land

Design documents are indexed like code: each section is a node and a
point. mirai-agent's source already cites the design in its comments
(for example `docs/07-conversations.md §7.6` in `Vortex.Client`). Each
citation becomes an `implements` edge. A citation that points at a
section which no longer exists is reported as **stale**;
`docs/12-status.md` counts 98 files that cite the old documents.

This is how the design travels with a task: the trail of any code
includes the sections it implements, without the caller restating them.

### 6.5 The trail

For a request:

1. **Seeds.** Files and names given by the caller; definitions named in
   an error or stack trace; then the nearest definitions by vector
   search.
2. **Walk.** Personalized PageRank from the seeds over the graph, with
   each step also scored by the neighbour's similarity to the request,
   so that paths drifting away from the request are cut. Uncertain edges
   count for less.
3. **Pack.** The highest-ranked definitions in full, the next ones as
   signatures, the design sections they implement, all within a token
   budget.

The default budgets (Claude's call, to be tuned against measurements):
system prompt at most 900 tokens, as in the draft; trail at most 4,000
tokens. Named files contribute a path/line-count manifest and seed the
trail, not an additional full-file copy (the revision below supersedes
the original files-in-full plan).

**The coder's prompt is as short as it can be, plus a head start**
(the operator's aim; Claude's call on the means, revised 2026-10-18
after T1 of L9, whose 6,500-token prompt was 72% trail, mostly noise):

1. *Files named are never sent whole* (operator, 2026-10-25, replacing
   D21's files-in-full). They seed the trail, which packs their relevant
   chunks with what they touch (callers, callees, the design they
   implement) within the 4,000-token trail budget; under Files the model
   sees only each named file's path and line count, and reads anything
   else it needs with `read`/`search`. Chunks are embedded so that no
   prompt has to carry a whole file.
2. *The head start* is what the model would otherwise spend a tool round
   or an attempt finding out, and only that: the check command it must
   pass and, when the request asks for a test, the project's test file
   for that module (or the nearest one) as the pattern to follow;
   the design rules that apply. No general instructions it does not
   need.
3. *Stable before variable.* Each attempt's prompt keeps the previous
   one's text as an unchanged prefix and appends what failed, so the
   model server's prompt cache can spare a retry the re-read. With one
   slot the reviewer can displace the coder's active prefix. The current
   serving preset uses `parallel = 1` and `cache-ram = 2048`; cache reuse
   and its memory cost are measurements, not a correctness guarantee (§13.4).
4. *Measured, not guessed:* every case records its prompt's tokens by
   section, and the time to first token, so budgets are tuned against
   the record (§10).

### 6.6 Kept current

The core is a long-running OTP application. It watches the repos it is
told about and re-parses and re-embeds what changed, as a pipeline of
processes passing messages (§13.4): file events in, a parse pool, one
store writer, one embed queue. Embedding and the code model share the
same 6 CPU threads, so embedding is held while the code model is
generating (EmbedGate, Claude's call). Before a trail is built, the
files it uses are brought up to date, so the trail always reflects the
working tree.

A repo is added with an explicit command (`trailblazer watch <repo>`)
or by its first task. Parsing a repo takes seconds and embedding it
takes hours, so a repo that is not fully embedded is still usable: the
graph and exact search work at once, and vector seeds join as
embedding catches up (Claude's call).

### 6.7 Questions anyone can ask

The core answers without a model:

- `where_declared(name or position)`
- `who_uses(definition)`
- `impact_of(definition)`: walks the reverse edges outward
- `read_range(path, lines)`
- `search(text)`: semantic search and exact search together
- `trail(request)`: the packed context of §6.5

The code model reaches these as tools (§7.3). Claude and Codex can
reach them directly too, which would make the core the replacement for
the ranger skill. Claude's guess at a good second use; the surface
(CLI, MCP or both) is the builder's call.

## 7. The coding loop

### 7.1 A task

```
repo        absolute path
request     what is wanted, in words
files       optional: paths the caller knows are involved
design      optional: design sections that apply
check       optional: the command that proves it works
from        who asked (a VORTEX peer, or "cli")
```

With no `check`, Trailblazer uses the project's usual one (`mix test`,
`bun test`, …) when it can tell. With no check at all, the result is
reported as *unverified* and is not committed (Claude's call).

### 7.2 The model

Spark-X2.6-4B, the publisher's Q8_0 GGUF with its companion DSpark draft,
is the operator-selected coding worker. A separate CPU router serves it as
`spark-x2.6-4b:q8-dspark`; the default OpenAI-compatible base URL is
`http://127.0.0.1:8096/v1`. The earlier Q4_K_M trial on port 8094 is not
the current default. The dedicated `mirai-llama-dspark.service` uses the
XHToken llama.cpp fork (22c0ae18); the upstream router on port 8094 cannot
load this draft. The request sampling parameters are:

- temperature 1.0, top_p 0.95, top_k 0 (disabled), min_p 0
- presence and frequency penalties 0
- repetition penalty 1.0
- thinking enabled with reasoning effort `high`

The serving preset allocates 131,072 context tokens. Separately, Trailblazer's
default output cap is 16,384 tokens, including reasoning; a caller may set an
explicit smaller reasoning budget within that cap. Neither setting is the
model's 1,048,576-token advertised maximum. The DSpark-capable serving fork
uses `draft-dspark`, at most seven proposed tokens, and greedy draft sampling;
this does not change the target sampler settings above.

Sources: [target model](https://huggingface.co/XHToken/Spark-X2.6-4B)
and [DSpark draft](https://huggingface.co/XHToken/Spark-X2.6-4B-DSpark-GGUF).

Trailblazer reads the model name and base URL from configuration. The
model's reasoning is recorded (§8) but never sent back to it.

### 7.3 One attempt

The model is given the system prompt, the trail, a named-file manifest and
the request. It submits native `submit_edits` SEARCH/REPLACE blocks; the
validated legacy text/whole-message JSON forms are also accepted (see
`local-planner.md`). It may first
call the core's questions (§6.7) when the trail is not enough; each call
and its answer is part of the attempt. Edits are applied with the
tolerant matcher ported from Aider (§9). A block that does not apply
comes back to the model with the closest lines in the file.

An attempt **fails** when its edits do not apply, the check fails, or
the review (§7.4) finds a problem. The next attempt is given what
failed: the check's output (its last 4,000 characters) or the review's
findings.

### 7.4 Review against the design

After the check passes, the model reviews its own diff against the
request and the design sections in its trail: does it do what was
asked, only that, and in the way the design says? A failed review uses
up an attempt like a failed check. This is the defence against the
first anti-goal: code that passes the tests and breaks the design.

Whether the reviewer is the same model in a fresh context or a
different one is the builder's call. Claude's default is the same
model, fresh context, a short reviewer prompt.

### 7.5 Three attempts, then phone a friend

The operator's rule: **at most three local attempts, then escalate.** There
is no judgement of whether a task "looks trivial" and no fourth local
attempt. A reasoning-only output cutoff stops earlier rather than retrying
the unchanged budget; verification-only recovery also makes one attempt.
Unsafe setup, ownership or transport failures can end the case before coding.

Who the friend is (the operator decided):

- **Codex is the friend Trailblazer calls.** It receives the dossier
  over VORTEX, diagnoses, and reviews. It gives an opinion independent
  of whoever wrote the code. Codex debugs Elixir well but does not
  draft it well.
- **Writing the code goes to MiniMax M3.1 Flash** (OpenCode, model variant
  `max`). Codex hands it the drafting with its diagnosis; MiniMax M3.1 Flash
  works in the task's own worktree (§7.7); Codex reviews what it wrote.
- **Claude is not woken by Trailblazer.**
- Codex's VORTEX door does not do unattended work today (it queues into
  a chosen chat only when a `wake` file exists). Letting Trailblazer
  wake it for escalations is a deliberate change to that door, made
  when phase 3 (§11) is built. Until then, the dossier goes back to the
  caller in the report.

The **dossier** is the escalation message, and it is written for a
model that has never seen the repo:

- the request and who asked
- the trail: definitions, callers and impact, design sections (as
  `path:lines` references and short excerpts, not whole files)
- each attempt: what was changed, and why it failed (check output or
  review findings)
- Trailblazer's own diagnosis, in a few sentences
- the branch and worktree where the attempts can be inspected

When the friend says it is done, Trailblazer runs the same check and
review on the worktree before committing, and records the outcome
(§8). A friend's fix that fails them is reported as `failed` with the
dossier, not retried.

### 7.6 The report

Short and in a fixed shape, because a model reads it:

```
status      fixed | escalated | unverified | failed
summary     two or three sentences
branch      and commit, when there is one
files       changed
check       pass/fail, with the tail of the output on failure
attempts    how many, and the friend's name if escalated
cost        model calls, prompt and completion tokens, seconds
case        the case id (§8)
```

Over VORTEX it is one message in the caller's room, starting with the
usual sender line ("From Trailblazer, not typed by the operator:").
On the CLI it is one JSON object.

### 7.7 Workspace and git

- Each task runs in its own git worktree on a branch named
  `trailblazer/<case id>` (Claude's call).
- Only after check and review pass, the Loop commits on that branch.
  `fixed` means **candidate ready**, not accepted or integrated. The checked
  tree is recorded before the check and compared again before committing;
  changed content needs a new check. Checks that rewrite tracked files,
  including formatters, are rejected: use a non-mutating verification command.
- The Loop never merges or pushes and never touches the caller's checkout.
  `Trailblazer.Loop.Coordinator` owns acceptance, integration and cleanup.
  A primary branch admitted with the case (`primary`, never inferred from
  the current checkout) is the trusted policy that hands the case to it when
  the Loop reports: a `fixed` candidate is integrated (`accept`), any other
  outcome is archived (`retire`). Without an admitted primary the candidate
  branch is retained for the caller, as before, and the `accept`/`retire`
  operations do the same work on request. The public status is unchanged;
  the report adds `integration` or `archive`.
- Integration runs under a per-repository lock and rechecks everything
  there. A primary still at (or behind) the base advances to the candidate
  itself, whose exact tree was checked. A moved primary gets a merge commit
  (`merge-tree --write-tree`, then `commit-tree`) tested with the trusted
  check in a detached checkout; a conflict or failed test returns with the
  candidate preserved. Primary checked out nowhere advances by
  `update-ref <new> <old>`; a clean checked-out primary is fast-forwarded
  through its own checkout. A dirty one blocks; it is never reset or stashed.
  A compare-and-swap lost to a moved primary is reopened and the result
  recomputed and retested, never retried blindly.
- Before anything is removed, the journal and a binary patch of everything
  the case changed relative to its base (committed, uncommitted and untracked;
  provisioned dependency and build trees excluded) are written outside any
  worktree to `<state_dir>/archive/<case>/` and verified by SHA-256. Cleanup
  then removes the managed checkout and deletes the branch by compare-and-swap
  on its archived SHA, ending `cleanup_complete` (integrated) or `discarded`.
  Errors stay in the journal (`last_error`) with the candidate intact and the
  same call retries. Every destructive step first re-verifies the archive,
  also when an interrupted cleanup resumes, and a failed worktree discovery
  is an error, never "checked out nowhere". An intact archive that no longer
  matches the checkout's present content or branch SHA is replaced, before
  removal, by a new snapshot that the journal records (`archive_refreshed`).
  Snapshots are immutable: each directory is named by its whole payload
  (journal and patch bytes and branch SHA), appears by one rename and is
  never rewritten. There is no age-based prune.
- Cleanup precondition: a managed checkout is exclusively owned by its case
  and quiescent with respect to other writers when cleanup runs. The
  per-repository coordinator lock serializes cooperating operations only; it
  does not exclude a non-cooperating process, and nothing bounds the time
  between the final archive comparison and the removal. Content written into
  the checkout in that interval is not protected. A shared or actively written
  checkout must not be admitted for automatic removal; a stronger guarantee
  would need a separate ownership and retention design.
- Integration commit policy (explicit, not equivalent to hooks having run):
  the merge commit is written with `commit-tree`, so the repository's commit
  hooks do not run on it. Its author/committer identity and dates are Git's
  own from the repository/user configuration; its subject is
  `Merge trailblazer/<case> into <primary>` and its body is the candidate's
  message verbatim, so the candidate's issue reference and any disclosure
  trailers it carries are repeated and none are added. The candidate commit
  itself went through the hooks (`Workspace.commit`). A repository whose rules
  require hooks on every commit should not admit a primary for automatic
  integration; a fast-forward writes no new commit.
- `accept`/`retire` over the API answer synchronously: `accept` on a moved
  primary runs the trusted check, so it can take as long as that check. A
  client timeout does not cancel or corrupt the operation; it is idempotent
  and journalled, so the caller retries the same call (or reads the case
  journal) to learn the outcome. `409` carries the blocking reason.
- A durable lifecycle journal in `cases.db` records ownership, base and
  primary SHAs, check evidence, candidate/result SHAs, cleanup state, errors
  and transition history, independently of the public case status. Writes use
  versioned compare-and-swap. Its table is also created lazily for hot loading.
- Write commit intent (exact parent/tree), integration intent (old primary and
  tested result), and removal intent **before** their Git effects. Recovery
  observes exact Git state and records effects already completed once; it
  never replays a model call, runs a check, advances a ref or removes a path.
  Ambiguity remains blocked with evidence. Complete cleanup, including
  candidate branch deletion, requires an integrated result or a verified
  archive (`discard` intent).
- The journal and coordinator implement integration/removal, but API fixture
  tests do not prove the missing resource-gated `primary` admission path.
  Without that explicit policy, a Planner/VORTEX candidate remains for review.
  See bug:1beebca and `docs/2026-10-23-design-review.md`.

### 7.8 Doors

- **VORTEX** is the main door: Trailblazer runs as its own VORTEX owner
  (`trailblazer`), with a durable inbox and a wake adapter like the
  other owners. Requests are accepted from the recognized local
  collaborators (Claude, Codex, OpenCode, Mirai). Anything else is
  refused. A request's text is untrusted data: it can ask for a change
  and cannot widen what Trailblazer is allowed to run. The `check`
  field is a shell command, so it is accepted only from those
  collaborators, and it runs inside the task's worktree.
- **CLI** (`trailblazer run …`, one JSON report on stdout) for tests,
  benchmarks and direct use by Claude or Codex. It follows the case's
  events as they are recorded (§13.3), printing them to stderr, and
  exits on the report; it never polls.
- One task runs at a time (one model on one CPU). Runner's serial queue
  is currently in memory; the case is persisted before admission returns.
  Durable delivery/reassignment is separate VORTEX coordinator work.
- On restart, interrupted local cases are reported failed, without replaying
  model calls. Git lifecycle intents are reconciled first; their evidence
  remains available after the public case closes. This is recovery of Git
  effects, not automatic resumption of a lost in-memory model task.

## 8. Case records

Every task is recorded **completely and in a fixed format**: the
request, the trail as given, every prompt and reply verbatim (reasoning
included), every tool call, every edit, every check output, every
review, the dossier, the friend's fix and its verification, and the
model and settings used. Records are stored in SQLite with the prompts
and replies as files beside them (builder's call).

This is for training the local model later. The operator has in mind a
method like SCoRe (Kumar et al., Google DeepMind, *Training Language
Models to Self-Correct via Reinforcement Learning*, arXiv 2409.12917):
attempts, a verifier and a correction, which is what every case already
contains. The check is a ready-made reward, and an escalated case pairs
the local model's failed attempts with a verified fix. Training is **not
part of v1** and not yet designed. Where it would run is undecided. v1
must only make sure no case is lost or recorded partially.

## 9. What is reused

From mirai-agent (copied, not depended on, so that Trailblazer can be
its own product; Claude's call):

- `ModelClient`, `SSE.Parser`, `Turn.NativeToolCalls`: one streaming
  model call and its tool calls
- `Tool`, `Tool.Validator`, `Tool.WorkspacePath`: tool definitions and
  path safety
- `Vortex.Client`: its local VORTEX API client, which re-reads
  `endpoint.json` on every call
- `Memory.Embedder` and the Qdrant client in `Memory.Index`

From Aider (Apache-2.0; attribution in the root `NOTICE`):

- SEARCH/REPLACE edit blocks: the parser, the tolerant matcher (exact,
  then whitespace-tolerant, then `...` elision), and "did you mean these
  lines" on a miss
- Personalized PageRank over definitions and references, now run on the
  core's graph instead of ctags output
- The edit, check and reflect loop, now bounded by §7.5

From ranger: the repo-scoped collections, `.gitignore` handling, the
embedding form (`task: code retrieval | query: …`) and incremental
re-indexing by content hash.

## 10. How success is measured

- **Paid tokens saved:** tasks closed locally, and for escalated tasks
  the friend's tokens compared with the same task sent without a
  dossier.
- **Fix rate:** the share of tasks fixed in three attempts, and on which
  attempt.
- **Regret rate:** fixes committed by Trailblazer that a later review
  finds wrong. This is the measure of the first anti-goal.
- **Opening prompt size and time to first edit,** against OpenCode on
  the same model and task. The draft's figure is OpenCode's 14,317-token
  opening prompt.

## 11. Order of building

**Operator priority update, October 19, 2026:** the existing core, loop and
pipeline work below is the foundation. The next delivery starts with VORTEX,
not another isolated coding trial. Mirai and the local coding model cannot
fit in memory together, so coordination must work while either is unloaded.

1. Establish the VORTEX task/report and escalation protocol with durable
   delivery, identity checks, acknowledgments and recovery. A transport write
   alone is not proof that a task was accepted.
2. Implement exclusive model-resource handoff: store and acknowledge a request
   before the requester yields its model resources; run the recipient only
   after ownership is available. Keep lightweight coordination independent of
   either loaded model. A result must remain deliverable while Mirai is absent.
   Failure or restart must leave an inspectable owner and case, not lose work
   or load both models. Exact router integration follows an implementation
   inventory; this priority does not authorize changing Mirai's live runtime.
3. Connect Mirai harness incidents to triage and bounded repair. After three
   failed local attempts, hand off the dossier and continuation state to an
   available recognized collaborator; never loop indefinitely or wake a known
   unavailable collaborator. Returned fixes still require checks and review.
4. Reuse the same path for Mirai's requested tools and features.
5. Run final end-to-end acceptance, including T1–T4, recovery and resource
   handoff, then measure correctness, cost and speed. Unit and protocol tests
   accompany implementation; the coding trials are deferred until this path
   exists.

The original phase breakdown follows for reference; it does not supersede
this delivery order.

Claude's call. Each phase is useful by itself.

1. **The core** (§6): parsing, graph, vectors, design-document nodes,
   the questions of §6.7, kept current. Claude and Codex can use it
   from the CLI immediately in place of the ranger skill, which saves
   tokens before any coding loop exists.
2. **The loop** (§7.1–7.4, §7.7) on the CLI: one task, three attempts,
   check, review, commit on a branch, report, case record.
2b. **Events, messages and pipelines** (§13), decided 2026-10-18 after
   the first live runs: the clocks of phases 1 and 2 replaced by
   messages, backstops with investigation requests, the indexing
   pipeline, and the coder's prompt cut to what it needs (§6.5). Planned
   in `docs/2026-10-18-phase2b-events-plan.md`.
3. **The doors and friends** (§7.5, §7.8): the VORTEX owner, the queue,
   resuming, escalation to Codex with a dossier, drafting by space
   bunny.

Building Trailblazer itself follows the same split (the operator
decided): the code is written by MiniMax M3.1 Flash (OpenCode, variant `max`),
and Codex reviews it as an independent second pair of eyes.
4. **Measurement** (§10) against OpenCode on the same model and tasks.

## 12. Open questions

1. **Acting on running systems.** Reading logs, restarting a service,
   changing a unit file: what may Trailblazer do with nobody watching?
   The operator deferred this. Until it is answered, v1 runs only the
   check command and the core's read-only questions.
2. **Where the code lives.** Claude's call is a separate repository,
   `~/projects/trailblazer`, because it is meant to be its own product.
   Its design documents would move there once it exists.
3. **Training:** the method, the hardware, and how often.
4. **The trademark waiver** from Salesforce before any public release.

## 13. Events, messages and pipelines

Added 2026-10-18 after the first live runs. *The operator decided:*
Trailblazer is event- and message-driven throughout. Time is never how
the work moves; it is only a backstop that catches what has gone wrong,
and a backstop that fires is a reason to look, sent to Claude and Codex.

### 13.1 Why

A design built on timing assumptions fails whenever something takes
longer than assumed, and on this machine everything sometimes does:
prompt reading ran at 8–11 tokens/s with 31 GB of swap in use, a
whole-repository graph read took over 15 s, and one reviewer thought for
13 minutes. Each fixed wait in phases 1 and 2 broke this way (E19, E19b,
E23): a call timed out while the work it waited for was still going, and
the timeout was taken for the answer. On the BEAM work is processes and
messages: a reply, a `:DOWN`, an event. Waiting for one of those is
always correct, however long it takes.

### 13.2 The rules

1. **No clock as control flow.** Nothing is retried, polled, debounced or
   given up on because a time passed. Work moves when a message arrives:
   a reply, an event, a monitor's `:DOWN`, a port's exit status.
2. **A wait is for a message, with a monitor.** Every request to another
   process monitors it, so its death is an answer at once. Callers inside
   the VM use `:infinity` call timeouts together with a monitor, or ask
   asynchronously and receive the reply as a message.
3. **Progress is reported as events,** never sampled on a timer: tokens
   as they stream, the model server's prompt progress, files parsed,
   edges written, vectors embedded.
4. **Work queues, not waits.** Where order matters there is a queue and a
   process that owns it (the task queue, the store writer, the embed
   queue). Where it does not, work fans out to a bounded pool and the
   results come back as messages.
5. **Back-pressure by demand.** A stage takes the next item when it is
   free (it asks for work), so a slow stage holds up its producer instead
   of growing a mailbox without bound.
6. **One backstop per external interaction.** Something outside the VM can
   stop answering while staying alive: a check command that loops, a model
   server wedged mid-stream, an HTTP peer that never replies. Each such
   interaction has exactly one backstop, preferably a measure of progress
   (tokens, bytes of output, edit rounds) and else a wall-clock limit set
   generously from measurements. A backstop is not a path the design
   expects to take.
7. **A backstop that fires is an anomaly** (§13.5): the work it guarded
   ends in a defined way (the attempt fails, the task fails, the file is
   marked unparsed), the anomaly is recorded with the system's load, and
   an investigation request goes to Claude and Codex.
8. **Tests synchronise on messages,** never on `Process.sleep`: a test
   waits for the event that says the thing happened (`assert_receive`
   with a subscription), so a slow machine makes a test slower, not
   wrong.

### 13.3 The event bus

A local publish/subscribe registry (Elixir's `Registry` with duplicate
keys; no new dependency), with topics:

| Topic | Published by | Carries |
|---|---|---|
| `{:repo, path}` | watcher, indexer, writer, embedder | files changed, sync started/done, nodes and edges written, vectors done |
| `{:case, id}` | CaseRecord | every case event as it is recorded, and the report |
| `:model` | Model | call started, prompt progress, milestones, call ended |
| `:embedder` | embed health | up / down, with the reason |
| `:anomaly` | Backstop | each anomaly (§13.5) |

The API streams a topic to a client (`/case` with `follow`: the CLI
prints each event as it comes and exits on the report), which removes the
CLI's polling and gives callers the live log for free.

### 13.4 The pipelines

**Indexing** (replaces the per-repository loop of §6.6):

```
request for repo R (search, where, uses, status, run)   ← freshness (§13.7)
  or a git-state event (one inotify instance; one watch per repo, its git dir)
  → indexer per repo: a set of dirty paths; syncs when free, and
    whatever arrives during a sync is the next batch (no debounce)
  → parse pool: N workers (Elixir parser in-process; tree-sitter Ports,
    a small pool, each a separate OS process)
  → resolver
  → store writer: the one writing connection, batched transactions
  → embed queue: global, by repository priority; runs only while
    EmbedGate grants it; asks the embed-health process, never retries on
    a timer
```

**Reads** go through their own SQLite connections (WAL allows readers
beside the writer), so a question or a trail never waits behind a write.
Case records have a database of their own (E23).

**Coding** (§7): the task queue (Runner) takes one task at a time,
because there is one model on one CPU. Within a task, the worktree and
the trail are prepared in parallel; attempts, checks and reviews are in
order. Model calls go through one owner of the model, which knows the
single slot is busy and holds embedding (EmbedGate) for the call.

Parallelism does not speed up the model: one slot on 6 threads. What
pays for a task is fewer prompt tokens (§6.5) and the model server's
prompt cache.

### 13.5 Anomalies and investigations

`Trailblazer.Backstop` arms the one backstop of an interaction and
cancels it when the interaction's own answer arrives. When a backstop
fires:

1. the guarded work ends in its defined way, recorded (case event or
   index status);
2. an anomaly record is written: what was awaited, from whom, for how
   long, the progress seen so far, and the load at that moment (load
   average, free memory and swap, whether the model or embedder was busy
   and for whom);
3. an investigation request goes over VORTEX to Claude and Codex, one per
   distinct anomaly (same kind and subject) until one of them
   acknowledges it, so a repeating fault is one request, not a flood.

The request is short and written for a model, like the report (§7.6):
what fired, the evidence, the load, and where to look (case id, repo,
journal time). Often the answer will be "the machine was loaded"; the
load is in the request so that is quick to see. Investigation requests
are the one exception to "Claude is not woken by Trailblazer" (§7.5),
by the operator's decision.

Backstops start from measured values with a wide margin: generous enough
that firing means something is wrong, not that the machine is busy.

### 13.6 What it replaces

| Was | Now |
|---|---|
| CLI polls `/case` every second | streamed case events |
| Loop heartbeat every 15 s | prompt progress and stream milestones (done, E22) |
| Indexer 1 s debounce | dirty set, sync when free |
| Indexer 30 s embed retry | embed-health events and EmbedGate grants |
| Indexer 15 s poll without a watcher | no poll: every request reconciles its repository first (§13.7); a repo without a watch is simply cold |
| One recursive watch over every indexed repository (cost grows with every directory indexed; ~/projects alone is 81,066 directories against a 65,536-watch limit) | freshness from git on every request; one watch per repository, on its git directory (§13.7) |
| Model 500 ms retry while the model loads | the router's loading answer is retried on a backstop, logged as progress |
| GenServer call timeouts (5 s, 30 s, 10 min) | monitors and `:infinity`, or asynchronous replies |
| Model first-token and total deadlines | token budget (`max_tokens`) plus one backstop |
| Check timeout | one backstop, and output progress logged |
| `Process.sleep` in tests | `assert_receive` on events |

### 13.7 Freshness from git; one watch per repository

Added 2026-10-18 late. *The operator ruled* that a design whose cost
grows with everything indexed is wrong: one inotify watch per directory
over every repository exceeds the kernel's per-user limit (65,536 here;
~/projects holds 81,066 directories, 2,805 after pruning, and it only
grows). On ext4 there is no cheap "what changed since" query, and the one
notifier that covers a whole filesystem in one mark (fanotify with
`FAN_MARK_FILESYSTEM`) needs `CAP_SYS_ADMIN`.

*The operator's answer: track git.* Git already knows what changed, at
a cost that follows the size of the change, not of the repository:

1. **The indexed state is a git state.** Each repository records the
   HEAD commit it last indexed. On a request, `git diff --name-status -z
   --no-renames <indexed>..HEAD` names exactly the files that commits,
   checkouts, pulls and resets changed.
2. **Working-tree edits come from `git status`.** `git status
   --porcelain=v2 -z --untracked-files=all` names modified, staged,
   deleted and untracked files against HEAD, using git's own index stat
   cache (which already handles racy timestamps, `cp -p` and the rest)
   and respecting `.gitignore`, the same rule as file listing. It runs
   with `GIT_OPTIONAL_LOCKS=0`, so it never takes `index.lock` and never
   gets in the way of the operator's or an agent's git command (measured:
   it writes nothing under `.git`).
3. **Every request reconciles first.** Before Trailblazer answers a
   search, where, uses, status or run for repository R, R's indexer runs
   1 and 2, makes the union its dirty set, syncs only those files, then
   answers. The request is the event. The caller waits for a message
   (`{:fresh, repo, generation}`), never a time; progress streams on
   `{:repo, path}`; one backstop guards it.
4. **Requests coalesce.** A request joins the next reconcile that starts
   after it arrived (a reconcile already running may have read the file
   before it changed, J19); every request waiting on that reconcile is
   answered by it.
5. **One watch per repository: its git directory.** Measured on a
   scratch repository: add, commit, checkout, branch and reset all
   rewrite `index` (and `HEAD` or `logs/HEAD` when HEAD moves), all
   directly in the git directory. One non-recursive inotify watch on it
   (for a linked worktree, its own `.git/worktrees/<name>`) tells the
   indexer that git state moved, and it reconciles at once. Unstaged
   edits and new untracked files touch nothing under `.git`; they are
   picked up by the next request (3), or, for a repository with a running
   case, by the loop itself, which knows the files it edits. ~/projects'
   81,066 directories become about one watch per repository.
6. **Ignored but indexed directories** (vendored code such as `deps/`,
   which the operator wants indexed though `.gitignore` excludes it)
   change when their lockfile changes (`mix.lock`, `bun.lock`,
   `package-lock.json`, `Cargo.lock`, `poetry.lock`); git sees the
   lockfile, and a lockfile change rescans that directory by stat.
7. **A directory that is not a git work tree** falls back to a stat
   reconcile on request (size, mtime_ns, ctime_ns, inode against the
   store) and gets no watch.
8. **Embedding stays lazy and separate.** Reconcile makes the graph
   current; vectors for changed definitions go to the embed queue, and a
   search answers from the vectors present, saying how many are pending.
   The crawl that embeds every project by recency is a work queue; a
   repository nobody asks about costs one watch and nothing else.
