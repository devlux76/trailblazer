Trailblazer design, continued from design.md

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

The model receives the system prompt, trail, named-file manifest and request.
Native `submit_edits` accepts either SEARCH/REPLACE blocks or read-backed line
ranges. The legacy text and whole-message JSON forms remain accepted (see
`local-planner.md`). Reading returns the full original file's SHA-256 and
numbered source. A range identifies that version and inclusive 1-based lines;
it replaces those original lines without retyping the old source. A nonempty
replacement without a final newline inherits the replaced range's LF/CRLF
separator when an untouched following line remains, preventing accidental joins.
An explicit replacement newline remains unchanged; empty text deletes the range;
a replacement reaching EOF stays byte-exact. This boundary rule also applies to
dry-run previews (bug:fae87c7).
EOF/before-line insertions use `end = start - 1`. Each model range also
quotes the text of lines `start` and `end` (`first`/`last`); a quote that does
not match the line it names refuses the batch, so a miscount fails loudly
instead of splicing over the wrong lines (bug:9ae2ace).

Ranges use original coordinates, are grouped by canonical file identity, and
splice from the end. Stale versions, overlaps, duplicate insertions, mixed
legacy/range modes on one file and escaping paths are refused. Adjacent ranges
and boundary insertions are valid. Untouched Unicode, CRLF and final-newline
bytes stay unchanged. Empty SEARCH never appends to a nonempty file; it returns the current digest
and whole-file range for a local correction. Legacy matching tolerates whitespace differences but
requires a unique target; it never guesses between repeated matches or repairs
punctuation automatically. Preview and actual application share the same
atomic validation and path resolution; preview writes no files or directories.

During reading the advertised toolset stays stable. When reading ends or a
correction begins, only `submit_edits` is advertised. The pinned DSpark server
supports string `tool_choice = "required"`, not named-function objects; required
with reading tools still advertised allowed forbidden searches in a real probe.
The edit schema itself remains unchanged. This one toolset transition can
invalidate the prompt prefix cache; correctness takes priority over that cache.
The host also rejects forbidden read calls without executing them.

A native submission miss, malformed arguments, mixed calls or forbidden reads
returns a compact tool result in the same conversation, with the original
assistant call retained and each tool-call ID answered. No workspace reset,
retrieval restart or duplicate full batch is needed. At most two correction
calls follow the initial unusable reply. A third unusable reply stops with
`edit_repair_exhausted`, retaining the worktree and case evidence even for a
managed primary. It consumes one coding attempt, not three whole coding runs.
Feedback is capped at 12,000 characters including its envelope;
stale-range feedback includes the current digest and a bounded numbered excerpt.
A zero-read miss without source or filename candidates stops immediately as
`source_context_missing`; this does not silently widen the read budget.

A successful preview proceeds to application, artifacts, check and independent
review. A failed check or usable review finding still allows the normal next
coding attempt from the original base with its submitted blocks as reference.
Legacy text/JSON misses retain the original outer-attempt behavior.
Source issue: trailblazer:9ae2ace.


For explicitly named existing-file tasks with read rounds, the native schema
advertises only the range shape. A bounded Spark conformance test accepted this
shape but selected empty SEARCH when both shapes were advertised, even after
reversing their order. Zero-read, missing-file and unspecified-file tasks keep
the compatible dual schema. Host decoding still accepts both; the selected edit schema stays
stable throughout each attempt, while the reading tools are removed at the
submission boundary. The format choice is recorded as `edit_format`.

### Compiling checkpoints (operator rule, 2026-11-04; bug:67ba062)

Compilation is a separate, locally configured gate, bound to the admitted
repository and test/check command in the peer policy's `compilation` map.
The peer/model cannot supply a compilation command. Absence means compilation
has not been separately established; it is never inferred from a failed test
command. Configure this gate for the current compiled-language queue.

Order: artifact preparation, compilation, **commit the exact compiling tree**,
refresh its index, then run tests and independent review. Failed tests do not
veto or erase the compiling commit. Each case keeps a private `-compiled`
worktree/branch with normal commit hooks, the same provisioned dependencies,
and issue references. Identical trees
reuse their commit; later compiling versions are additional commits. Source
worktree resets never delete these commits. The execution worktree, approved
candidate lifecycle and primary branch remain separate: a compiling checkpoint
is neither review approval nor permission to merge.

The compiled worktree's graph is explicitly refreshed after its commit. Its
indexed HEAD and pending-vector count are recorded with the checkpoint; graph
freshness is distinct from asynchronous embedding completion. Existing global
content-addressed embedding cache entries can be reused for unchanged source.
The original worktree's index continues to describe its own original source.
Do not silently return compiled/unreviewed source as primary-branch results.

A failed test/check creates a Git-bug report linked to the compiling commit (or
the exact candidate tree if compilation was not separately established),
source card/case, exact command, exit status and bounded failure output. Repeated
failure of the identical checkpoint and command reuses that report. Reports are
resolved only when a later candidate passes tests and independent review. Until
then the commits and reports remain inspectable. All these stages share the
existing 15-minute verification allowance; no deadline is renewed. Candidate
reports expose `compiled` commits independently from the reviewed `commit`.

### 7.4 Review against the design

After the check passes, an independent model reviews the diff against the
request and the design sections in its trail: does it do what was
asked, only that, and in the way the design says? A failed review uses
up an attempt like a failed check. This is the defence against the
first anti-goal: code that passes the tests and breaks the design.

The reviewer is a different model than the coder, on its own router;
Spark never reviews Spark. The configured reviewer is Nemotron
(`nemotron-3.5-bolt-e4b:q4`, iGPU router `http://127.0.0.1:8098/v1`).
Up to three review passes fit within the card's shared 15-minute verification
allowance (operator hour-of-code rule, 2026-11-04). Each call's Backstop is
clamped to the remaining allowance; an unusable verdict may retry, but never
renews that allowance. Expiry immediately preserves the candidate for frontier
verification; the third unusable pass also parks the case. A clear FAIL returns
findings to the coder; an unclear, timed-out,
unavailable or unusable review is never fed to the coder and never
fails a tree that passed its check: the case closes as `awaiting_review`,
the checked tree is pinned at `refs/trailblazer/checkpoints/<case-id>`,
and the workspace and branch are retained for a frontier review with
compile/run regression evidence (Nemotron; Codex, or Claude when Codex
authored the change).

### 7.5 Three attempts, then phone a friend

**Hour of code (operator, 2026-11-04; bug:dfc3bd9).** Each fresh coder context
has a hard 900,000 ms generation window, starting before its prompt is built.
Waiting for the embedding gate, read/search calls, reasoning, prompt evaluation, edit submissions and same-context
corrections all share this deadline; individual model-call limits cannot renew
it. The existing Backstop stops inference and bounds read/search work. Partial
responses are recorded synchronously. A complete late response is retained but
cannot proceed as a successful generation.

Before any failed attempt is reset, pin its generated tree at
`refs/trailblazer/attempts/<case>/<attempt>`. Original replies, submitted blocks,
compiler failures and partial output remain in the case record. The next attempt
starts from the original source in a fresh conversation with the failure feedback;
no previous chat history is resumed (bug:6ff32b2): partial content, reasoning and
tool-call fragments are case evidence, never forwarded as a completed or prefilled turn,
and every attempt is a labelled restart; a longer window needs an operator decision.
A restart still reuses the KV cache (bug:95b9b73): system prompt, trail and source precede
the feedback, so the server keeps that prefix (router, 2026-11-07: 2,921 of 2,922 tokens
cached on repeat). A changed system prompt or toolset invalidates all of it, so a read→final
switch pays one full prefill; read tools are not re-advertised to avoid that. Each reply
records the server's `timings` (`prompt_n`, `cache_n`, `prompt_ms`). After three unsuccessful attempts, return
`failed` with reason `decomposition_required`, a dossier and retained workspace.
The planner blocks the parent for decomposition; do not automatically readmit the
same card. Smaller child tasks must have their own checks and acceptance scope.

Artifact preparation, checks and independent review share a cumulative 900,000 ms
verification allowance across the three attempts. Generation time does not
consume it. An exhausted allowance retains the tree as `awaiting_review`, with
explicit check status (which can be unverified or timed out); it never authorizes
a commit or another coder retry. Remaining verification time follows a fixed
candidate into coordinator/Companion detached checks as an absolute deadline;
those checks cannot each obtain a fresh allowance. Tests use shorter trusted
limits; task payloads cannot widen them. Thus scheduled generation is at most
3 x 15 minutes, with at most 15 minutes of verification. Admission, dependency
provisioning, preservation and cleanup remain separately supervised overhead;
report them separately rather than claiming a strict one-hour end-to-end SLA.

DSpark was previously measured by the operator to improve 5 to 6 TPS. Current
case traces at 1.6–1.9 TPS are a regression to investigate, not evidence that the
original comparison was absent. Apply the time-box rule first; if a bounded run
still cannot deliver, compare one representative edit with minimal context against
the full harness before making further tool changes.

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
status      fixed | escalated | unverified | failed | awaiting_review
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

Continued in design-3.md: §13.
