# Planner permission decisions from observed consequences

Direction approved by Claude; revised for generic requests and phased rollout.
SPEC ONLY; implementation plan follows review. Issue: trailblazer:0981773.

## Outcome, scope and rollout

One generic Trailblazer permission primitive: `awaiting_permission`, an evidence
bundle, and a bound decision. Artifact scope is the FIRST consumer, not a
separate approval mechanism. Later actual edit-policy or check-tree guards use
the same lifecycle/audit trail. This does not create a named-file restriction:
`task.files` is currently context, not an edit allowlist.

Planner judges what an action achieves and changes, rather than merely whether
it matches declared intent. F15's 0775→0755 directory recreation needs evidence
and judgement, not another hard-coded permission exception or coder invocation.

- **P1: frontier-only.** Pause/evidence/binding/resume and authenticated Codex or
  Claude decisions over VORTEX. Local Planner has NO decision authority. Retain
  today's detection boundary; make no outside-write prevention claim. F15's
  acceptance belongs here and requires a recorded frontier decision.
- **P2: calibrated local tier.** Retain P1 evidence/frontier decisions as labelled
  calibration cases. The local brain must agree with them, including refusal,
  escalation, and adversarial variations, before explicit local policy enables
  any authority. Security-related false grants fail calibration. Bolt's security
  judgement is unproven; model availability or a plausible answer is not proof.
- **P3: restricted execution.** Prove a bwrap write boundary with attempted
  escapes and Git writes; specify allowed read roots/scratch before rollout.
  This stronger enforcement is not a prerequisite for P1's detection-based F15.

Deployed main stays 0f60f21 with its conservative guard. 86eb4bf remains
historical/unmerged, not a permanent fix or a new stopgap deployment. 0697491's
replay implementation stays held until it matches the continuation contract.

## Shared request and decision lifecycle

1. An out-of-policy observation checkpoints case/consumer/stage as
   `awaiting_permission`, preserving the exact edited checkout and response.
   Release coder/model/resource leases before emitting one durable request.
   The case is paused, not failed; no coder retry, commit or parallel resume.
   Mirror it on the Planner board as blocked, with awaiting_permission,
   request id and deadline visible. A grant queues a continuation in the
   existing serial executor at the recorded stage, never a new coding attempt.
2. Evidence includes the admitted objective and action, frozen command/policy,
   build-definition/source diffs, exit/output, and each exception's relative
   path, before/after type/mode/size/content-or-link digest, observed containment
   and commit disposition. Include untracked/ignored effects, reproducibility
   evidence and observation gaps. "Not committed" does not imply harmlessness.
3. The HOST computes risk features: directory-metadata-only, ships content,
   widens access, type/symlink change, source/build-definition touched, and
   observation gap. Host policy chooses the permitted decision tier; models
   cannot relabel features, select their own tier or self-promote. P1 routes
   everything to configured authenticated frontier principals. In P2, only
   calibrated low-risk feature combinations can reach the local tier;
   uncertainty, widening access, unexpected source or gaps remain frontier.
   Routing selects a decider, not an automatic grant based on a pathname.
4. A strict answer is `grant`, `refuse`, `escalate` or `amend_policy`, with
   consequence-based reasoning. A grant lists exact exceptions, commit paths,
   postconditions and optional finite host normalization (e.g. restore a
   recorded parent mode), never arbitrary model shell. Local amendment is a
   proposal through the reviewed trusted-policy path, not a file self-edited
   by a worker/model. Card-selection Decision.choose is not this capability.
5. Bind request/decision to case/base, frozen policy, relevant source digest
   and exception-delta fingerprint. Persist evidence digest, authenticated
   decision-maker/tier/model, reasoning, time and disposition. Reobserve before
   resuming: changed evidence invalidates approval; normalization must meet
   postconditions. Approved Git content joins the checked/reviewed/committed
   tree. A grant never blesses an old check after mutation: rerun checks against
   the resulting tree and obtain fresh code review.
6. Companion and merge verification repeat observation using recorded policy
   and applicable case-scoped decisions. Different effects need a new decision;
   relative source/exception evidence supports reuse across checkout paths,
   not a blanket granted flag. Restart resumes the durable stage/decision
   without rerunning the coder or automatically repeating the judgement call.
7. Notify the configured frontier deciders through a verified ACTIVE wake
   route as well as VORTEX mail. Persist initial notification and one reminder
   before expiry, with separate queued/sent/host-admitted/acknowledged outcomes.
   Mailbox delivery alone is not wake proof. Routes and targets are trusted
   local configuration, never model-selected commands or recipients. Preserve
   unknown delivery outcomes without blind duplicate sends. Admission of a
   notification is not permission to continue.
8. Use a configurable absolute permission deadline (P1 proposed default:
   14,400 seconds, consistent with the ordinary four-hour case backstop;
   respect any earlier explicitly admitted hard deadline). An expired request
   is recorded as `no_decision`; late grants are rejected atomically. The CASE
   remains blocked and resumable, not discarded or forced to regenerate code.
   A later explicit request may reuse the checkpoint after freshness checks,
   with a new request identity and without a coder call. Restart enforces the
   persisted deadline; grant/expiry races have one winner. Native timers own
   the deadline/reminder, never recurring model polls.

## Work preservation is independent of permission expiry

Timeout releases compute/leases and ends waiting for that request; it never
throws away a run. Preserve base/repo/policy provenance, exact authored and
generated file bytes (including untracked/binary files and relevant modes),
all submitted blocks and tool results, prompts/replies/partial stream output,
and the checkpoint/stage/evidence/decision journal. Confused or incomplete
reasoning is retained as evidence, not silently trusted as a correct solution.

P1 retains the unfinished owned checkout/branch by default. Expiry does not
remove it. Later storage compaction is a separate trusted maintenance action:
first produce and verify a restorable checkpoint, then release the checkout
while retaining the recovery material. A diff alone is not sufficient when it
omits untracked files, metadata or partial output. Failed preservation checks
leave the work visibly retained. No age-based deletion of unfinished work. Code may be discarded only after
review/evidence establishes it is bad, unused, inefficient or superseded;
incompleteness alone is not that classification.

Board state shows blocked/no_decision plus checkpoint and recovery action.
Re-entry resumes the correct stage or selects useful saved work for correction;
checks and fresh review still decide correctness. Neither an expiry nor a
confounded answer implies starting from scratch.

### P1 preservation helper (storage, not runtime acceptance)

`PermissionCheckpoint.capture(case_id, workspace, payload)` validates the owned
worktree against the case repository and actual HEAD, then saves private
content-addressed blobs plus a digest-bound manifest under the case directory.
The small reference contains version and manifest SHA-256 only. The payload and
case journal are separate verified blobs; case spill files and partial streams
are included alongside worktree files. Ignored files and caches are included,
not silently dropped. Git administrative files are excluded; the manifest
records repository/worktree/base identity and the original index digest.

Capture compares a second inventory, journal and Git state before issuing a
verified reference. This requires a quiescent writer and detects changes; it
does not provide a sandbox or protection against a hostile concurrent writer.
Files retain bytes and modes, directories retain modes, symlinks retain link
text without traversal. Unsupported special files cause refusal, leaving the
original work intact. Blob/manifest writes are synchronized and read back;
this is not a machine-power-loss durability guarantee.

`verify` checks the bound manifest and every blob. `restore` verifies first and
materializes `worktree/` and `case/` only under a new destination with real
directory ancestors. Existing destinations are refused. A failed capture or
restore retains its partial material and never deletes the original checkout.
Restoration does not install Git administrative references or resume execution;
managed Git reattachment, source freshness and actual pause/release/continuation
belong to the later runtime integration. No automatic cleanup is enabled here.

F15 already ended under the old guard. P1 must preserve that closed source case
and explicitly adopt its verified saved response/checkpoint into a new
permission continuation, checking peer/repo/base/policy and response provenance.
No source-case rewrite or ordinary coder redispatch. This narrow P1 migration
follows the new lifecycle; the broader 0697491 replay work remains held.

### P1 notifier primitive (not live wake acceptance)

The trusted local route has an absolute `executable` and `cwd`, a literal `args`
list, an explicit `env` map, and `timeout_ms` (default 60,000; range 1..300,000).
Unknown fields and malformed values refuse before execution. Append one fixed
message containing only the validated request id, binding/evidence digests and
notice ordinal (0 initial, 1 reminder); build output never enters the command.
The existing Check process-group supervisor has a fixed-argv entry: its shell
handshake executes `"$@"` as literal data, not shell source. The child receives
only the configured environment plus the check PATH default. Timeout or caller
death kills its process group; output is bounded and never copied into the
notification journal.

Normalize the helper's JSON receipt: `started` or `steered` WITH a bounded turn
id means host-admitted, `queued` stays queued, and generic/malformed success or
timeout is unknown. A nonzero exit records helper failure, not proof that no
notification happened. Neither host admission nor exit zero proves the frontier
read or decided. The primitive makes one attempt and has no retries; the later
coordinator must record an ordinal claim before effects, preserve unknown
delivery after a crash, and allow only the single separate reminder. No real
route or policy is enabled by implementing this helper; live idle-wake and
authenticated decision acceptance remain required.

### P1 trusted local permission configuration (current low-level validator)

The optional VORTEX `permissions` block contains only `timeout_ms` (positive
integer, default 14,400,000) and a nonempty `deciders` map. Absent/null keeps
existing behaviour. Each alias contains exactly `peer`, `host`, `endpoint` and
`notifier`: the peer must already be a locally configured frontier (not a task collaborator or caller),
its direct room is taken from that same frozen peer policy, and the endpoint is
an absolute path to that decider's OWN service (never started automatically).
Duplicate peers under different aliases are refused. `host` is `codex` or
`claude` in P1; it does not select a local judgement model or confer authority.

The notifier uses the strict route above. For Codex, its explicit environment
MUST include `PING_FROM=Trailblazer` and a fixed UUID `CODEX_THREAD`. This avoids
the installed helper's default sender of Claude and its mutable pinned-thread
fallback. Unknown fields, caller-only/unknown peers, invalid routes or invalid
timeouts reject the configuration through the existing fail-closed loader.
Configuration parsing itself sends nothing. The Claude route must target a
fixed live session through its configured argv/env; live acceptance for either
host must check the rendered sender AND destination, not just an exit status.
Settings remain cached at boot; configuration edits require a normal idle
restart. The coordinator/transport/CLI remain separate implementation stages.

### P1 postmaster: repair or reach back (operator revision)

The frontier states intent, not thirteen protocol fields. For example:
"grant perm-x: the directory mode change is harmless." A lightweight local
postmaster parses the intent and finds the addressed request. The first model
candidate is the locally registered `lfm3-1.7b-q8` on :8094; model availability
and parsing behaviour still need a bounded live trial. This is postal work,
not delegated risk judgement: the frontier remains the decider in P1.

The host supplies stamps from its own records: authenticated transport
peer/room, request identity, nonce, hashes and binding. A grant can inherit the
presented exception ids and required commit paths when the sender clearly
approves that whole presented scope. The model does not invent identity,
select newer evidence, enlarge the approval or add a normalization. Qualified,
partial or contradictory intent gets a question when its meaning cannot be
resolved; formatting repairs do not become a new approval.

Bind the reply to the evidence version issued to that authenticated decider.
The show client records an authenticated view receipt after assembling and
displaying the verified view; an API actor-name argument is not such a receipt.
This records delivery/display to the client, not proof of human attention.
The postmaster uses that receipt/reply context to stamp the answer. If there
is no matching receipt, several possible requests, or newer evidence than the
viewed version, return the relevant view/question and wait for a fresh answer.
Never stamp a stale answer against the current request just because it exists.

Addressing follows the same principle. Resolve missing sender labels or
destinations from the trusted peer/session registry, then validate the stamped
route. The model can propose a match, not create a peer or silently choose
among chats. The helper's Claude sender default and mutable thread-pin fallback
are not trusted addressing. Ask the sender/operator when lookup is ambiguous.
The route rules above describe the resolved result, not fields a person has to
remember. A repairable permissions-message/route defect holds that item with a
visible needs-attention reason; it does not disable unrelated healthy work.
The current Settings loader still treats a malformed permissions block as
invalid VORTEX configuration; isolating repairable route defects is part of
this proposed integration, not a capability already implemented. Trust-critical
authority configuration remains closed when unresolved. The postmaster cannot
edit global policy. Unresolved identity/evidence cannot authorize execution.

Keep the original message, interpreted intent, host lookups/stamps, view
receipt and repair/question history. Structured unambiguous input needs no
model call; free text gets a bounded parse through existing inference/resource
limits, not an autonomous conversation loop. A missing model or malformed parse leaves the message/work preserved and
asks for clarification; it never supplies a default grant. Replies use durable
correlation/deduplication and the existing bounded notification policy.

`escalate` and `amend_policy` remain preserved, decidable requests. Publish
blocked(escalated/amend_proposed, reason) on the Planner board immediately,
and make operator attention explicit in the result returned to the frontier
chat. No higher tier is silently invented for a Codex-only deployment.

First scope is permission correspondence and its address resolution. Reuse
the primitive for other tool messages incrementally; this revision does not
authorize a rewrite of every guard. Core.decide remains the final CAS. Existing
strict code is retained behind the postmaster, not discarded. Before effects
wiring, revise the implementation plan and test natural grant/refuse, repaired
stamps, negation/quotation and ambiguous/conditional intent, stale/missing views, forged identities,
offline/malformed parsing, visible escalation and duplicate delivery. Then
prove the actual local parser and one real decider round trip. No new postmaster
code or model authority is claimed by this design change.

### P1 stamped decision shape (internal codec, not sender requirements)

`permission_decision` retains the 16,384-byte protocol envelope cap. Its payload
requires exactly request_id, nonce, binding, evidence_sha256, base, policy_hash,
source_hash, exception_hash, outcome, reason, exception_ids, commit_paths and
normalizations. Request id must match the outer envelope; hashes/nonces have
their host-generated hexadecimal lengths. Outcomes are grant/refuse/escalate/
amend_policy; reasoning is nonempty and at most 1,000 bytes. Selection ids are
bounded strings and commit paths are relative, excluding traversal and Git
administration. Missing/unknown fields, identity/tier/command overrides or
malformed lists are refused. Semantic selection and source freshness still
belong to the bound request/consumer.

These fields are assembled/checked behind the postmaster; the sender can use
natural language or an ergonomic CLI reply. Codec acceptance does NOT
authenticate the decider or grant permission. Bridge
handling must first verify the real transport peer/direct room against the
configured and frozen frontier authority, then use the permission CAS. Until
that integration lands, the existing bridge refuses these as unexpected
messages. No decision effect or execution is enabled by the codec alone.

## Proposed authority floor — explicitly subject to operator review

Risk grants cannot change authenticated principal/repository, choose a new
TOP-LEVEL host command, mutate Git authority (HEAD/index/.git), or authorize
outside-root/symlink-escape writes. Wider authority requires a separate trusted
policy change by its owner. The fixed build command still executes reviewed
repository build definitions; that existing authority is not magically removed.

P1 refuses known authority violations and reports gaps. Today's after-the-fact
snapshots cannot prevent or prove the absence of outside-root writes, so P1
must describe DETECTION, not enforcement or absence of damage. bwrap exists on
this host but is unproven. P3 must prove allowed reads/scratch and read-only Git
authority before claiming a write floor. This proposed floor does not silently
widen policy or claim a sandbox already exists.

## Acceptance by phase

- P1: real F15 mode recreation pauses, receives a bound frontier decision and
  continues saved edits through check/review/Companion without a coder call.
- The same primitive handles a second simulated guard consumer; a changed
  check tree requires a new check, and unexpected source cannot be omitted.
- World-writable parents, uncertain evidence and forged/self-promoted decisions
  cannot receive a local grant. Stale/replayed grants and failed postconditions
  cannot resume; test restart/crash and grant-versus-expiry races.
- Refuse/amend-policy/expiry are audited and board-visible, no policy self-edit
  occurs, waiting holds no model lease, and expiry preserves resumable work.
- Prove initial wake and one reminder reach the configured host; queued mail
  is not counted as active attention. Preserve delivery uncertainty.
- Expire, restart, restore a checkpoint containing untracked/binary/partial
  work, then continue without another coder call; reject late old grants.
- P2: calibration and host routing tests precede enabling local authority.
- P3: attempted outside-root/symlink/Git writes prove the execution boundary;
  snapshot-only assertions do not satisfy this acceptance.
