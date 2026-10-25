# Trailblazer design review — 2026-10-23

Status: core decisions accepted by Claude in the conference; review additions
folded in below. Design only; implementation acceptance remains separate. Source audited at
`94ef13d`. This review does not claim fresh live local-model acceptance.
The aim is reliable delegated repairs, then bounded VORTEX TypeScript work,
measured by accepted fixes per hour rather than inference price alone.

## Corrections and evidence

- F1 is partly implemented: `Loop.succeeded/4` calls `workspace.close/1` after
  a checked commit (`lib/trailblazer/loop.ex`, Endings). Its return is ignored;
  `Workspace.close/1` force-removes the worktree and retains its branch.
  `prune/2` has no production caller. Unchecked reviewed changes remain dirty.
  No integration into the primary branch is implemented.
- F2 is real: `Bridge.process_event/2` accepts only `message` plus an authorized
  direct room and `Protocol.decode/1`. Other event kinds and plain text are
  classified ignored. `Settings.load!/1` requires a two-member JSON room;
  adding a conference CLI call alone cannot fix admission or reply routing.
- F3 has advanced beyond the October 19 acceptance snapshot. `f87f3d1` added
  dedicated-mode `Vortex.Resource`, kernel-lock ownership, router residency
  checks and supervised recovery. `resource_test.exs` covers stale leases,
  failed unload and malformed HTTP responses. This is not evidence of a
  completed real Mirai-to-Qwen handoff. Resource calls are outside Bridge.
- Follow-up plan Tasks 1–2 are implemented by `00337fe`: reset feedback says
  discarded edits must be recreated; bounded installed Babylon declarations
  reach coder and reviewer. `docs/trials.md` records the negative MathUtils
  import fixture and passing deterministic tests. The 13 unchecked boxes are
  stale tracking, not 13 missing implementations. Task 3's live T1/T4 reruns
  and reviewer-cost measurements remain pending. Do not mark those complete.
- Returned fixes still stop in `waiting_verification` (`Store.returned_fix/3`).
  Protocol validates SHA spelling/correlation, not ancestry, scope or execution.
  No real Mirai harness-fault-to-repair acceptance was found in the audited
  Trailblazer sources/evidence. Mirai ops events alone are not that integration.
- `Check.run/3` supports long checks; `backstop_check_ms` defaults to 30 minutes.
  A five-minute Bun suite does not require a new scheduler or longer timeout.
- F5: `Embed.documents/2` already chooses the serial path for one configured
  URL. Keep that path and its tests; a pool rewrite is not a prerequisite.
- F6 is reported live by Claude: 24 frontier waits addressed to Codex. This
  review has not reclassified or closed those cases. A delivery receipt is
  not a claim, and a claim is not a verified repair.

## Decisions and rejected alternatives

### Lifecycle: the coordinator owns integration, the Loop owns a candidate

A case has distinct durable outcomes: candidate ready, accepted, integrated,
cleanup complete, or blocked with evidence. `fixed` currently means a checked,
reviewed commit exists; it must not imply primary integration. Keep the public
status compatible while adding integration/cleanup outcome fields.

The task's trusted local policy records the canonical repository, primary
branch (main/dev/master explicitly), base SHA, permitted files and trusted
check at admission. Never infer primary from the currently checked-out branch.
Loop commits scoped candidate changes. A coordinator accepts them, serializes
integration per repository and verifies the exact result before deleting the
branch and worktree. Recheck the candidate/base, authorized diff and current
primary under that lock. With a dirty primary checkout, do not reset/stash it;
report blocked integration and preserve the candidate. Clean means no tracked
changes (including staged changes); unrelated untracked files are allowed unless
the integration would overwrite them. If primary is checked out in another
worktree, inspect that checkout too. If primary is checked out nowhere, prepare
and test the integration result in the case worktree, detach its candidate
checkout if necessary, then compare-and-swap `refs/heads/<primary>` from the
recorded old SHA to the tested result with `git update-ref`. A failed CAS
requires recomputation and retesting, not a blind retry. Never move the current
feature branch or update a checked-out primary behind its worktree's back.
Initially block checked-out dirty primaries; do not add another worktree system.
If primary moved, test the merge result before advancing primary; conflicts
return for review. Record the resulting primary SHA durably before cleanup.

No trusted check means `unverified`: preserve a patch/dossier outside the
worktree, report that it is not accepted, then clean the managed checkout only
after preservation is verified. Do not merge unchecked work to meet cleanup
policy. Failed cases likewise retain their evidence outside Git worktrees.
Cleanup retries follow case/integration/recovery events and are idempotent.
Never let `--force` silently discard an unarchived failed attempt.

Rejected: automatic merge in `Workspace.close` (filesystem cleanup cannot
establish acceptance); age-based prune as integration (age proves nothing);
caller-only informal cleanup (the observed forgotten-worktree failure).
The end-of-day rule is a completion condition. A real conflict/dirty-checkout
blocker must remain explicit; it does not authorize destructive cleanup.

### Reachability: one conference per case, structured authority inside it

Use the existing Trailblazer service identity, with a session keyed by case.
Create/join/post on an invitation-admitted conference and persist its case
mapping; retain direct-room compatibility during migration. Transport accepts
configured certifying peer identities and approved session/case membership;
body-supplied names never grant authority. Restore membership after connector
restart and keep durable application receipts distinct from transport writes.

Add a model-free control path for trusted invitations, status, cancellation,
capability discovery and explanations of unsupported plain text. It must be
reachable before a coder model is loaded. Plain text can be acknowledged and
answered with help; it cannot become an executable task. Structured
`trailblazer/1` envelopes continue to bind repo/check/files/request identity.
Unknown/untrusted invitations receive no automatic admission. Avoid reciprocal
help responses: one response per inbound message ID; no response to receipts.

Rejected: silently ignoring all non-envelope mail; treating natural language
as executable authorization; a third identity joining a two-party room;
creating a new service identity per case. Conferences solve fanout, not policy.

### Resource and returned fixes: retain the fence, finish the missing gates

Preserve the same lease across coder, reviewer and check. Dedicated mode is a
useful implementation for explicitly offline Mirai, not a full general-purpose
ownership-transfer protocol. Every CPU inference participant, including an
external benchmark and Ranger server, must honor the same coordinated window.
Verify residency from actual router/model state, not worker death or lock exit.
On uncertainty retain the fence and request investigation; no timed reloads.

Before a returned commit runs any code: resolve its exact object in the
allowlisted repository; verify its admitted base and ancestry, candidate diff
including added/deleted files, symlinks/submodules and permitted paths; reject
out-of-scope changes; bind verification to the locally stored trusted check,
not a mail-provided command. A trusted check must cover changed code. Tests
are executable candidate code, so they run in an isolated workspace under the
same resource and command policy. Verify the exact SHA; subsequent amendments
invalidate that result. A fresh lease is required after frontier work.

Connect a real Mirai fault emitter using a durable incident ID and local
allowlist. Preserve the incident over restart; three attempts total across
restarts, followed by one frontier assignment. Scripted-model tests are
necessary but insufficient for this gate and for Qwen's Elixir competence.

### Fitness: bounded work first, profile before changing models or kernels

At the brief's historical ~90 seconds per 1,000 prompt tokens, 20K tokens cost
~30 minutes of prefill alone. This is arithmetic, not a new measurement.
Qwen can remain viable for small tasks if source retrieval keeps prompts small;
it is not yet accepted for arbitrary multi-file VORTEX work. Use definition
and caller excerpts with installed dependency evidence, not whole-file dumps.

Run targeted reproducer/checks while iterating; require `bun run typecheck &&
bun test` on the accepted VORTEX result, plus the project's build where
relevant. Do not replace a supplied trusted command with an easier check.
A check timeout is a diagnostic outcome, not automatic permission to lengthen
it. Budget the whole case including review/retries; three attempts is an upper
bound, not a requirement to spend three expensive calls on a known mismatch.
Escalate early on insufficient context, unsupported edits, invalid evidence or
resource failure. Preserve local attempt history and the frontier claim.

The benchmark should compare original T1–T4 coding trials (not the similarly
numbered graph lookup trials), corrected T4 compile checks, then held-out Bun
and Elixir defects. Report correctness and accepted fixes/hour together with
prefill, generation, cache hits, prompt bytes/tokens and contention. Measure
2K/8K/32K/64K only where the model and memory permit; record unsupported/OOM
rather than silently shrinking context. GPU device/quant sweeps are separate
windows and must not displace the Polaris embedder without coordination.

### Embeddings: keep the single-endpoint path, defer pool removal

Configure only the real endpoint. Preserve namespace/model/dimension checks,
backpressure, bounded input and throughput logs. Remove the dormant pool only
as a separately justified change if maintenance or erroneous fallback warrants
it; do not destabilize working indexing during repair-loop acceptance.

### Frontier availability: durable assignment generations and bounded intake

Add an explicit decline/unavailable/recovery event and configured fallback
order among authorized frontier peers. Reassign atomically only while
unclaimed (or after an explicit relinquish/revocation); increment assignment
generation so late claims/returns from the old owner cannot race the new one.
Availability is advisory; it never authorizes execution or creates a repair.
Codex's `codex-limited` state is one useful local availability source.

Fingerprint repeated anomalies by component, failure class and relevant
revision; retain count, first/last occurrence and representative evidence.
Bound queued and active work per cause and globally; surface overflow without
losing incident IDs. Do not collapse unrelated tasks merely because text is
similar. Publish one durable update per changed cause state, not 23 model wakes.

Investigate age on queue/admission/availability/operator review events, using
stored timestamps; a clock may raise a diagnostic backstop but must not schedule
model retries. Review the current 24 as one inventory, link duplicates and
close only resolved/superseded cases with evidence and explicit outcome. No
blind bulk ack/close. Preserve valid pending work through fallback.

### Graph completeness: bounded default-module data flow, explicitly uncertain

F7 reproduces a retrieval blind spot: the graph's caller list omitted
`Loop.succeeded/4` because it invokes `workspace.close` after
`workspace = mod(st, :workspace, Workspace)`. Treat graph absence as incomplete
evidence, not proof of zero callers. Resolve an unambiguous same-scope module
default from `Keyword.get(opts, key, Default)` and the small recognized wrapper
`mod(st, key, Default)` to `Default.function/arity`, marked `uncertain: true`
with default-module provenance. Do not guess arbitrary helper return types.
Reassignment, control-flow ambiguity and unresolved defaults remain unresolved;
uncertain edges must appear in uses/impact with a visible qualifier and must
not be presented as definite call targets. Publish the same provenance in the
graph consumed by ranger so its answer does not silently discard the edge.

Keep the live self-watch/self-repair prohibition. For agents needing the
Trailblazer source graph, use a pinned read-only source snapshot and an
independent retrieval state/process with repair/run/model admission disabled;
prefer ranger's independent parser/index until that read-only mode is explicitly
implemented and reviewed. A separate state directory alone is not a safety
boundary. Do not weaken Workspace.own_repo? or let a clone bypass repair guards.

## Ordered plan with acceptance

### Task 1 — durable outcomes and edge-case register

Owner: Codex implements Elixir; Claude reviews.

Record ownership, primary/base/candidate/result SHAs, check evidence and
cleanup state. Acceptance: crash/restart at commit, integration and removal
boundaries completes once without losing evidence or touching caller edits.
Edge-case register to carry through later tasks: dirty primary; moved base;
merge conflict; no check; failed commit/cleanup; changed candidate after check;
path escape/symlink/submodule; missing dependency; unavailable reviewer; active
Mirai/foreign resident model; lost lease; restart during grant/release; old
frontier late return; duplicate anomaly; unavailable peer; lost receipt; quota
exhaustion; failed membership restore; unknown plain text; same-repo concurrency.

Task 1 implementation boundary: the lifecycle journal and killed-worker Git
fixtures establish durable intent/reconciliation for commit, integration and
removal. Loop retains a checked candidate branch and evidence pending acceptance;
the clean worktree directory is released under the pre-coordinator compatibility
policy in design §7.7. This is not complete cleanup. The journal is exposed
with its closed case record. A production coordinator that advances
primary and archives/removes failed or unchecked workspaces is still Task 2.
Recovery does not replay model calls. Runner's in-memory queue is not a durable
execution queue; interrupted local cases remain explicit failures.

### Task 2 — integration and cleanup

Owner: Codex implements Elixir; Claude reviews.

Wire the proposed lifecycle to case acceptance. Acceptance in disposable Git
fixtures: checked accepted commit reaches the configured primary, failed and
unchecked cases do not; archived evidence survives cleanup; cleanup errors
remain visible/retryable; no managed branch/worktree remains after success.
Use a bounded Sojourney trial for live acceptance, never Trailblazer itself.

### Task 3 — model-free conference control and frontier recovery

Owner: Codex implements Elixir; Claude reviews.

Implement conference admission/routing/restore, status/help and versioned
fallback claims. Acceptance: Claude and Codex each join one case, receive
reports, restart/rejoin, then one unavailable frontier is replaced without
accepting stale claims/returns or executing plain-text requests. Triage the24
only after inventory and current-cause confirmation; record each disposition.

### Task 4 — resource, emitter and returned-commit gates

Owner: Codex coordinates with Mirai owner; Claude reviews.

First retain existing dedicated-mode tests. Then coordinate real residency
transfer; run one real emitted incident through durable admission/restart,
three-failure frontier escalation and independently validated returned commit.
Acceptance: no overlap/unconfirmed unload, no fourth attempt, no check runs
for a wrong-base/out-of-scope return, and exact verified result reaches primary.
Separate the positive Sojourney repair trial from the authorized Mirai fault
emission/handoff test; do not point Trailblazer's indexer at its own repository.

### Task 5 — local-model quality and throughput

Owner: Codex owns design/analysis; OpenCode runs measurements in strictly serial sessions; Claude reviews quality acceptance.

Rebaseline coding T1/T4 first on isolated Sojourney fixtures at a pinned base,
then T2/T3 and held-out tasks. Include known-negative arithmetic/import checks.
Acceptance: correct arithmetic, real installed Scalar.Clamp, meaningful tests,
exact checker/build success and independent review. Archive prompt/token/time
and contention evidence. Then a bounded Mirai Elixir reproducer must fail
before and pass after a generated patch; canonical source stays unchanged until
separate acceptance. A scripted reply cannot satisfy this step.

### Task 6 — admit VORTEX TypeScript work

Owner: Codex scopes/integrates; local Trailblazer proposes bounded patches; Claude independently reviews.

After Tasks 1, 2 and 3 plus the TypeScript part of Task 5 (Sojourney T1/T4
and held-out Bun defects), start with one small known defect in a disposable
VORTEX fixture, then a bounded multi-file task. The existing dedicated lease
still gates inference. Mirai emitter/handoff acceptance and the Elixir trial
are separate workstreams and do not block local TypeScript candidates. A
frontier-returned candidate still cannot run until its Task 4 verification
gate exists; this narrower admission is not permission to skip that gate. Acceptance: reproducer fails first;
scoped patch passes targeted check and full typecheck/tests; independent
review accepts; exact result integrates; case reports cleanup complete. Compare
accepted fixes/hour against the baseline and frontier handoff cost before
raising task size or changing the default model.

### Task 7 — injected-module retrieval edges and safe source snapshots

Owner: Codex implements the Trailblazer resolver contract; coordinate ranger
consumption with Claude; each reviews the other's boundary.

Use a Sojourney/disposable Elixir fixture containing the default-module and
wrapper patterns. Acceptance: `uses Workspace.close` on a pinned read-only
source snapshot includes `Loop.succeeded/4` as uncertain, and ranger preserves
that qualifier. Overridden/reassigned/ambiguous variables do not create definite
edges; changed source removes stale edges. The snapshot process cannot watch
or repair live Trailblazer. This task can proceed independently of repair-loop
Tasks 1–6 and must not delay bounded TypeScript admission.

## Definition of fully functional

Not zero open cases or fast inference alone. It means reachable model-free
control, durable authorized admission, exclusive verified resources, bounded
repair/escalation, exact returned-fix verification, accepted primary integration
and recoverable cleanup, all demonstrated with real transport/Git/checks and
separately identified live-model evidence. No timers schedule work. No
production implementation or service change is part of this design review.
