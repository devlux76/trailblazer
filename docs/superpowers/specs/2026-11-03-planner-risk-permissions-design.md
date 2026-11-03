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
7. Set a trusted local permission deadline (proposed default: 30 minutes).
   No answer by that absolute persisted deadline atomically refuses with
   reason `no_decision`, mirrors the blocker, and archives/verifies the
   checkpoint before removing its owned worktree/branch. Keep evidence and
   source response inspectable. Restart enforces an already elapsed deadline;
   expiry and grant race through one transition, and late grants are rejected.
   Failed archive/ownership checks stay visibly cleanup-blocked, never deleted
   blindly. Waiting/expiry uses native timers, not recurring model calls.

F15 already ended under the old guard. P1 must preserve that closed source case
and explicitly adopt its verified saved response/checkpoint into a new
permission continuation, checking peer/repo/base/policy and response provenance.
No source-case rewrite or ordinary coder redispatch. This narrow P1 migration
follows the new lifecycle; the broader 0697491 replay work remains held.

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
  occurs, waiting holds no model lease, and verified expiry releases worktrees.
- P2: calibration and host routing tests precede enabling local authority.
- P3: attempted outside-root/symlink/Git writes prove the execution boundary;
  snapshot-only assertions do not satisfy this acceptance.
