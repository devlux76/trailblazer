# Planner permission decisions from observed consequences

Draft for Claude/operator review; no implementation. Issue: trailblazer:0981773.
Supersedes treating 86eb4bf's directory-mode allowance as the permanent fix.

## Outcome and current state

Planner may grant or refuse continuation based on what a preparation step
actually changes and achieves. Declared outputs express intent, not the answer.
F15's 0775→0755 directory recreation should produce evidence for a judgement,
not require another hard-coded exception or another coder invocation.

Deployed main remains 0f60f21 with the conservative guard. 86eb4bf is reviewed
but NOT deployed; keep it as historical evidence, not a new stopgap rollout.
0697491 and its uncommitted replay/mode refinements are held. Resume that work
only after its recovery contract matches the decision lifecycle below.

## Decision lifecycle

1. Preparation records before/after observations. An out-of-policy effect
   checkpoints the case as `awaiting_permission`, preserves the exact edited
   checkout and response, releases coder/model/resource leases, and emits one
   durable permission request. It does not retry the coder, commit, or mark the
   case failed. Planner can use its own model without a coder lease deadlock.
2. Evidence includes the admitted objective, frozen command/output policy,
   build-definition diff, exit/output, and each exception's relative path,
   before/after type, mode, size, content/link digest, root containment and
   proposed commit disposition. Include source diffs, untracked/ignored effects,
   reproducibility evidence and explicit observation gaps. Directory metadata
   is distinguished from Git content; "not committed" alone does not imply
   harmlessness (permissions and runtime effects still matter).
3. A separate strict permission decision uses the existing Planner model,
   journal and transport foundations; card selection's Decision.choose is not
   already this capability. The answer is `grant`, `refuse`, `escalate`, or
   `amend_policy`, with consequence-based reasoning. A grant names the exact
   exceptions, proposed commit paths, expected postconditions and any finite
   normalization action. Normalization is host-implemented (e.g. restore a
   recorded parent mode), never arbitrary model-supplied shell.
4. Local Planner may decide fully observed low-risk consequences, such as a
   directory-only change that ships no content and does not weaken access.
   Those examples route judgement; they do not auto-grant by pathname. Added
   write access, symlink/type changes, unexpected source/build-code changes,
   unknown effects or uncertainty escalate to an authenticated configured
   frontier reviewer over VORTEX. The host enforces decision authority; model
   text cannot self-promote. Refusal records its reason and ends the case.
   amend_policy is only a proposal through the reviewed trusted-policy path,
   never a policy file written by the worker or self-applied by the model.
5. Bind decisions to case/base, frozen policy, relevant source digest and
   exception-delta fingerprint. Persist evidence digest, decision, reason,
   decision-maker/model and authority tier. Revalidate before resuming; changed
   evidence invalidates the grant. Normalization produces a new observation
   and must satisfy the grant's postconditions. Any approved Git content joins
   the checked/reviewed/committed tree; hidden source changes cannot pass tests
   and then be omitted from the commit.
6. Continue with non-mutating checks and fresh code review. Companion and merge
   verification repeat observation against the saved policy and applicable
   case-scoped grant; different effects need a new decision. Reuse is based on
   relevant relative exception/source evidence, not checkout paths or a blanket
   granted flag. Restart resumes the checkpoint/decision without rerunning the
   coder or automatically repeating a model decision. An unavailable decider
   leaves a visible waiting state and releases resources.

## Proposed authority floor — explicitly subject to operator review

Risk judgement cannot change the authenticated principal/repository, choose a
new top-level host command, mutate Git authority (HEAD/index/.git), or authorize
writes outside the admitted writable roots or through a symlink escape. Wider
authority is a separate trusted-policy change by its owner, not a risk grant.
The fixed build command still executes reviewed repository build definitions;
"no model-supplied commands" does not magically remove that existing authority.

**Enforcement gap:** today's after-the-fact snapshots cannot prevent or prove
the absence of outside-root writes by a host command. The proposed write floor
needs an actual restricted execution boundary before claiming enforcement.
bwrap exists on this host; suitability is not yet proven. Specify/prove allowed
read roots and scratch writes, and mount Git authority read-only, during the
implementation plan. Detection after an escape is a refusal/incident, not a
claim that no damage occurred. This draft does not silently widen the current
policy or promise a sandbox already exists.

## Acceptance before rollout

- Real F15 mode recreation reaches a recorded local decision and resumes from
  saved edits through check/review/Companion, without a coder call.
- A world-writable parent is escalated, unexpected source cannot be silently
  omitted, and an uncertain/partial evidence bundle is not locally granted.
- Root/Git/command authority violations cannot be granted; prove the write
  boundary with attempted outside-root and Git writes, not snapshot assertions.
- Stale/replayed/forged grants and changed postconditions cannot resume work;
  crash/restart at request, decision and resume boundaries is idempotent.
- Refuse and amend-policy paths are auditable, no policy self-edit occurs,
  and no model/resource lease is held while waiting for another decider.
