# VORTEX integration: Mirai incident to verified repair or frontier handoff

## Intent and execution owner

The operator clarified on October 19 that Mirai is the primary caller. Her
unproven harness must be able to report a fault to Trailblazer, receive a locally
verified repair or a frontier handoff after three failures, and later use that
same path to request tools and features. VORTEX is the coordination mechanism.
Mirai and Qwen cannot be resident together. Codex implements and runs this
integration; the local coding model does not write it. A separate agent reviews
Codex's changes. T1–T4 remain deferred until the coordination path exists. Mirai source repair
is the intended product purpose, not a forbidden target. The operator’s
remaining model-quality uncertainty is Elixir competence. After coordination
acceptance, use a bounded Elixir harness repair with a reproducing test and
verified frontier fallback as the primary model acceptance, before broad
feature work. BEAM fault isolation does not establish semantic correctness.

This refines design.md §§7.5, 7.8, 11 and 13.5. It preserves the trusted check,
private worktree, review and no-merge/no-push rules. OpenCode and its connector
remain stopped after free-tier exhaustion. Claude remains unavailable until
Friday. The operator subsequently clarified that Claude availability imposes no
hold on live Mirai, router or model changes. Codex may implement and test the
resource handoff now, with serialized inference and verified release.

## Verified starting point

The core, HTTP/CLI loop and case records exist. Runner has an in-memory queue
and marks open cases failed on restart. There is no inbound VORTEX task worker.
Three failures create a dossier but do not deliver it to a frontier peer.
Investigate's current room is invalid for the app identity, and successful CLI
send is incorrectly sufficient to mark an investigation sent. EmbedGate is not
cross-application model-resource ownership.

The existing isolated VORTEX CLI test passed on October 19: real local peers,
authenticated message delivery, persisted acknowledgment, restart and a local
wake adapter (one test, 6.36 seconds). This proves transport behavior only.
It does not prove Trailblazer task admission or model-resource handoff.

## Wire contract and authority

Use a versioned JSON envelope under a fixed protocol discriminator. Every
request and response has an immutable correlation ID and message ID. Initial
messages are task, accepted, resource-ready, report, escalation, claim,
returned-fix and acknowledgment. Exact field schemas belong in protocol tests;
unknown versions, types, oversized bodies and malformed fields are rejected.
Serialized envelopes must fit VORTEX’s 16,384-byte message limit; large evidence
is referenced by case artifact rather than silently dropping the case.
Human sender attribution precedes any prose notification.

Authority comes from VORTEX's authenticated peer and direct room, matched
against local configuration. Display names and envelope fields grant no power.
Configuration binds each allowed peer to its repositories, check authority and
role: caller, resource coordinator, or frontier reviewer. A task cannot widen
those permissions, supply executables to the adapter, or declare its own model
resource grant. Unrecognized senders never invoke Runner or a shell.

A task names the repository, request, files/design and trusted check. Incident
evidence is bounded data, with source references; it is not a command. Existing
own-repository refusal applies before admission. Mirai source changes are allowed within the assigned private worktree. No task
automatically changes live services or applies a generated fix to Mirai's
canonical checkout.

## Durable admission, processing and delivery

Persist inbound deduplication, admitted task/case identity and the accepted
response in one cases.db transaction, before acknowledging the VORTEX cursor.
Uniqueness is authenticated sender plus correlation ID. Redelivery with the
same payload returns the existing case; conflicting reuse is rejected. A page's
cursor advances only through events durably classified, including refusals.

Use a durable queue rather than infer runnable state from all open cases.
The existing API/CLI and VORTEX door share the same serial executor. Store the
case's caller/room and lifecycle so restart does not lose ownership or routing.
Distinguish queued, waiting-resource, running, waiting-frontier and terminal.
Persist acceptance before execution. Waiting-resource cases survive restart.
For the first delivered slice, an interrupted running case is retained and
escalated for frontier diagnosis, never automatically rerun: interruption
consumes its allocated attempt, and no restart can create a fourth allocation.
Retain partial edits and case evidence. Automatic stage resumption is deferred
until fenced model ownership and commit-boundary recovery have live acceptance.

A durable outbox carries accepted, report and escalation messages. Stable
message IDs permit retries without a second case or action. Transport write
records a send attempt only. A matching application acknowledgment from the
intended authenticated recipient establishes receipt. Retain undelivered
messages across restart. Accepted acknowledges durable admission; report and
escalation receipt do not transfer execution ownership. Acknowledgments name the
immutable message ID and require the matching authenticated recipient. Ack
messages never require acknowledgments of their own. Use VORTEX events/waits
and explicit recovery triggers,
not an unbounded busy retry loop. An unavailable peer leaves inspectable queued
mail. Do not repeatedly wake known offline/exhausted collaborators.

## Exclusive model-resource boundary

Intake, persistence, acknowledgments and status/report delivery do not load a
model. Accepted means durably queued, not that inference has started. The caller
can yield after receiving accepted and later consume a stored result.

Ownership covers the coder, reviewer and any returned-fix verification. After
yielding, verification requires a new grant. Worker death does not prove model
unloading; a new owner remains blocked until the coordinator confirms release
and residency. Execution remains blocked until the resource coordinator grants ownership for
this exact case and current worker incarnation. Check and consume that grant at
dispatch; do not trust a caller's Boolean claiming Mirai is unloaded. One owner
runs inference at a time. Cancellation, owner death, restart and stale grants
must leave a recoverable case and cannot authorize another simultaneous worker.
The existing local inference lock is coordination evidence, not proof that
Mirai's model has unloaded. Real residency verification requires the router
owner's contract and is a separate live acceptance gate.

For this slice use a deterministic resource adapter in tests. Production is
fail-closed until the actual ownership adapter is verified. Lightweight
coordination may be enabled without enabling real task execution.

## Three attempts and frontier handoff

The real Loop retains the three-attempt ceiling across retries and recovery.
After exhaustion, persist a dossier and escalation outbox item before yielding
resources. The dossier contains the task, actual bounded trail excerpts,
design, each attempt/check/review outcome and the worktree/base/branch references.
A recipient must not need the sender's in-memory state to understand it.

Select one locally configured available frontier recipient. Claim/receipt is
correlated to the case and authenticated peer; duplicate or stale claims cannot
create parallel owners. A transport send does not transfer case ownership.
No available frontier leaves waiting-frontier visible and durable, not another
local attempt. Initial live destination is Codex; do not wake Claude/OpenCode.

A returned fix is confined to the assigned worktree/base and approved file
scope. Re-run the original trusted check and fresh design review before commit.
A failed returned fix is reported as failed; it does not start a fourth local
repair loop. Commit only on the case branch. Merging or deploying the repair is
an explicit caller action, not implied by a successful case report.

## Implementation and verification order

1. Add strict envelopes and sender/room authorization with negative tests.
2. Add transactional deduplicated intake, durable lifecycle and outbox, with
   restart tests around commit/ack boundaries. Preserve existing API/CLI shapes; VORTEX requests wait for resources.
   Existing supervised CLI behavior remains compatible in this first slice.
   Running VORTEX cases interrupted by restart escalate without replay.
3. Wire model-free VORTEX receive/send and resource-blocked dispatch. Test that
   busy execution cannot prevent intake, status or escalation acknowledgments.
4. Drive the real Loop against a tiny temporary repository with scripted model
   replies: a successful repair, then exactly three failures and a frontier
   claim. Returned-fix intake is retained and explicitly deferred for verification
   until a new resource grant, rather than executing instructions from mail.
   The scripted adapter replaces inference,
   not case storage, worktrees, checks, transport or the loop.
5. Run a real local VORTEX exchange using disposable identities/ports and the
   actual application bridge, restart across selected delivery boundaries,
   verify one admitted case and an acknowledged result or escalation. Require
   zero live model calls and preserve all existing owner states/services.
6. Obtain a clean independent code review, repair substantive findings with
   failing regressions, run the full suite and release checks. Then enable only
   the lightweight integration and run a controlled Codex/app exchange.

Acceptance includes unauthorized shell/repository requests, duplicate/conflicting
IDs, offline recipients, interrupted delivery, stale resource grants, cancellation,
restart during an attempt, three-failure escalation, bounded dossier evidence and
failed returned fixes. No passed test may stand in for an unexercised boundary.

## Explicit remaining live gates

A scripted model proves orchestration, not Qwen's Elixir competence. Simulated
resource grants prove blocking, not actual Mirai/Qwen residency handoff. A
Codex/app exchange proves that pair, not Mirai's harness fault emitter. Record
those limitations separately; complete actual router handoff and Mirai incident
acceptance with their owner before enabling unattended repair. Run T1–T4 and
cost/quality measurements last.
