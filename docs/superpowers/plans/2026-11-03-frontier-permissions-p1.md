# Frontier permission continuation P1 implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans task by task. Frontier agents may repair these tools; Claude reviews each bounded pin. No parallel implementation or new coder delegation is assumed.

**Goal:** Observe an artifact scope exception, wake an authenticated frontier decider, and continue preserved work under a bound decision without another coder call.

**Architecture:** A generic permission record/checkpoint owns decisions and continuation state in CaseStore. A supervised Planner coordinator owns transport, active notification, deadlines and board mirrors. Loop/Runner/Bridge suspend and resume one recorded stage; artifacts is the first real consumer.

**Tech stack:** Existing Elixir/OTP, Exqlite CaseStore writer, Jason, VORTEX v5 authenticated direct messages/outbox, current local notifier routes. No npm dependencies or new coding model.

**Spec:** `docs/superpowers/specs/2026-11-03-planner-risk-permissions-design.md` at a218009 (plus operator cleanup clarification below).

## Global constraints

- SPEC FIRST. This is a plan, not authorization to call an unimplemented path working. Base: deployed main 0f60f21; 86eb4bf is not merged into this line.
- P1 has frontier-only decisions. No local model judgement, calibration implementation, bwrap enforcement claim, global policy self-edit, new arbitrary commands, push or VORTEX cutover.
- Permission timeout defaults to 14,400 seconds, configurable locally; an earlier explicitly admitted hard deadline wins. One reminder at min(1,800 seconds, half the request lifetime), strictly before expiry.
- Expiry ends the REQUEST as no_decision; the CASE stays blocked/resumable. Preserve incomplete work, including confused/partial output. No automatic deletion of unfinished worktrees/branches.
- Discard code only after review/evidence establishes it is bad, unused, inefficient or superseded. Incompleteness or slow inference alone is not such evidence.
- `task.files` remains context. Approval does not bless a stale check; all approved content enters fresh check/review/commit.
- Proposed authority floor retains current scope; P1 detects known violations but does not prevent or prove absence of outside writes.
- Existing 0697491 WIP stays held. Build a reviewed continuation path, not an unreviewed stash transplant.

## Review focus

- Paused worker exit/restart must not become a failed coding case: tests in task 3.
- Expiry, notification ambiguity, duplicate/late decisions and crash races must preserve work: tasks 1–2.
- Evidence must not confuse ignored files, untracked content, directory metadata and Git content: task 4.
- A successful check against changed but uncommitted source is unacceptable: tasks 3–4.
- Mailbox delivery must not be described as waking an idle frontier host: tasks 2 and 6.

## Grounded seams and preflight ledger

- Loop.run unconditionally closes CaseRecord today. Runner.handle_info(DOWN) calls fail even on normal exit. Both need explicit durable-pause handling.
- Bridge releases the active lease on worker DOWN, but Store's request can remain running; dispatch then fences all later work. Add waiting_permission/resume_ready handling, not just a UI status.
- CaseRecord only appends to open cases. Keep task_case open with a separate permission state; do not invent another terminal case status and break event appends.
- Decision.choose is card selection, not a permission API. Do not reuse its model answer as authority.
- CaseStore.case_append and lifecycle_cas are serialized writer operations. New permission CAS must journal its event atomically; calling CaseRecord.event from inside CaseStore.transaction would deadlock.
- Current ping-codex emits queued/started/steered; queued is not active wake. Current ping-claude wrapper sends VORTEX mail. Tonight's Codex-to-Claude turns used `claude attach` plus input, so they do not prove ping-claude's idle behaviour.
- Interface dependencies: tasks 2–5 consume task 1's record/digest/CAS; task 3 consumes task 2's authenticated transitions; task 4 supplies task 1's evidence and uses task 3's continuation; task 5 imports F15 into that same path; task 6 gates actual configuration/deployment. Resolve mismatches against the spec before coding.

### Task 1: Durable generic permission contract and preservation

**Files:** create `lib/trailblazer/loop/permission.ex`, `test/trailblazer/loop/permission_test.exs`; modify `lib/trailblazer/case_store.ex`, `priv/migrations/002_cases.sql`.

**Interfaces:** `Permission.open(case_id, consumer, evidence, checkpoint, opts)` -> `{:ok, request_id}`; `get/1`, `for_case/1`; `decide(request_id, authenticated_peer, decision, now_ms)`; `expire(request_id, now_ms)`; `claim_resume(request_id)` -> `{:ok, checkpoint}` once; `finish_resume(request_id, outcome)`. No function takes a model-chosen executable.

- [ ] Write failures proving atomic request+event creation; case remains open; immutable before/after evidence/checkpoint digests; frontier binding includes case/base/policy/source/exception digest and request nonce.
- [ ] Test grant/refuse/escalate/amend_policy, unauthenticated peer, changed evidence, duplicate/late grant, grant/expiry race, and expired request followed by a NEW request reusing the checkpoint. Expiry must retain authored/untracked/binary files, modes and partial response bytes.
- [ ] Run `mix test test/trailblazer/loop/permission_test.exs`: expected RED on absent capability, not fixture/setup errors.
- [ ] Implement one generic table/journal through the CaseStore writer with CAS states waiting, granted, refused, expired, resuming, resumed. Preserve case checkpoint separately from request outcome. Spill large evidence via verified manifest under the case directory; protocol carries its digest/reference, not full source blobs.
- [ ] Run the focused file GREEN, then commit citing bug:0981773. No code must silently migrate a closed old case to open.

### Task 2: Authenticated decisions, active notification and board lifecycle

**Files:** create `lib/trailblazer/planner/permissions.ex`, `lib/trailblazer/planner/permission_notifier.ex` and matching tests; modify `vortex/{settings,protocol,store,bridge}.ex`, `planner/{supervisor,companion}.ex`, `api.ex`, `cli.ex` and their focused tests.

**Interfaces:** `Planner.Permissions` is an OTP coordinator using task 1 CAS. Protocol adds permission_request/permission_decision with exact schemas. Local authenticated `permission` show/list is read-only; no actor-name field in the ordinary HTTP API may forge a frontier decision. Decisions come from configured VORTEX peer/room authority. Evidence pages are bounded and digest-linked; show/list reads local case data, never a caller-supplied filesystem path.

- [ ] Write tests for peer/room/request/digest binding and unknown keys; caller-supplied principal, command, tier or notifier route cannot confer authority. Permission config is optional (absent preserves old behaviour), frozen at boot; invalid configured policy fails coding closed as current Settings does.
- [ ] Define trusted local permission config: explicit eligible frontier peers/rooms, fixed executable/argv/env notifier routes, timeout/reminder values. Host computes feature flags and always selects frontier in P1. Models cannot reclassify or select a local tier.
- [ ] Test initial wake + ONE reminder with persisted notification ordinals. Execute only locally configured argv, no shell interpolation; fixed message contains request id/digest and retrieval instruction, not untrusted build output. Normalize result to queued/host-admitted/unknown/failure. started/steered is host admission, not decision/read acknowledgement. Unknown delivery after a crash is not blindly re-sent; the one later reminder has a distinct ordinal.
- [ ] Test restart of timers/outbox, expiry race, local-decider-unavailable, malformed notifier output, board mirror blocked(awaiting_permission, request, deadline) and blocked(no_decision, recovery pointer). Test quote/newline arguments as data. No model call or repeated polling owns timers.
- [ ] Run the new focused tests RED; implement; run them plus existing VORTEX/Companion/API/CLI tests GREEN; commit bug:0981773.

### Task 3: Real pause/release/continuation across Loop, Runner and Bridge

**Files:** modify `lib/trailblazer/loop.ex`, `loop/{runner,lifecycle}.ex`, `vortex/{bridge,store}.ex`; tests `loop_test.exs`, `loop/runner_test.exs`, `vortex/bridge_test.exs`, `loop/lifecycle_test.exs`.

**Interfaces:** `Loop.resume_permission(request_id, opts)` reconstructs a data-only checkpoint and continues the recorded consumer stage; `Runner.resume_permission(request_id)` queues that continuation once in the existing serial lane. It must not call work/coder_reply from the start. Persist task, workspace identity, changed paths, reply provenance, resolved check and review evidence; never persist executable callbacks or arbitrary module options.

- [ ] Write RED tests: a durable pause returns without closing CaseRecord; normal worker DOWN does not call fail for a verified pause; uncheckpointed crash still fails normally; Runner boot recovery distinguishes preserved paused cases.
- [ ] Test Bridge's request becomes waiting_permission, lease release is confirmed, and later work is not fenced by an orphan running row. Emit the permission request/wake only once this CASE's lease is released (not when every unrelated case is idle). Release failure stays visible through existing backstop recovery.
- [ ] Test a grant enqueues exactly one resume, revalidates workspace/base/source/evidence, preserves original cost/evidence, and takes normal check/review/commit with zero new coder calls. New check/review failure preserves work and stops; it must never fall into attempts() and regenerate code.
- [ ] Test crashes at pause, release, grant, enqueue and check/commit boundaries; stale callback cannot advance a later request. A simulated second consumer, check-tree mutation, must recheck changed content rather than bless its old result. Do not wire every production guard in P1.
- [ ] Implement against task 1/2 contracts; run focused tests GREEN and full `mix test`; commit bug:0981773.

### Task 4: Artifact observation consumer and independent verification

**Files:** modify `loop/artifacts.ex`, `loop.ex`, `planner/companion.ex`, `loop/coordinator.ex`, plus existing artifact/loop/Companion/Coordinator tests and the artifact spec.

**Interfaces:** preserve existing no-policy prepare/verify behaviour. Add a data-only observation outcome containing allowed changes, exception details, host feature flags, evidence coverage and original before/after identity. Known authority violations are ungrantable; overridable scope effects flow into task 1, not the old generic hard-stop branch. `Permission` decisions augment this case's preparation evidence, never mutate the frozen global policy.

- [ ] RED tests: actual 0775→0755 recreation pauses, evidence contains exact modes and non-commit directory disposition, saved frontier grant resumes source+bundle commit. World-write widening routes frontier (no local authority); unrelated source, untracked files and symlink/type changes remain visible and cannot be hidden from the commit/check tree.
- [ ] Test normalization (only finite host restoration of the recorded parent mode) reobserves postconditions. No arbitrary mode/path/code/command may be supplied by the answer. Test denied/changed normalization and actual authority violations.
- [ ] Test Companion and computed-merge verification against the saved policy AND applicable exception/source-bound grant; different effects pause for a new decision. Independent checks still run. Existing stale merge, frozen policy, non-mutating check and root/symlink tests remain GREEN.
- [ ] Implement, run focused files and full `mix test` GREEN, update current-behaviour docs without claiming P2/P3, commit bug:0981773.

### Task 5: Narrow adoption of the preserved F15 checkpoint

**Files:** add trusted host adoption entry in `loop/permission.ex` (or a small `loop/permission_adoption.ex` only if separation is necessary), tests; read-only CLI exposes provenance. No general reopening of closed cases and no stash transplant from 0697491.

**Interfaces:** `Permission.adopt_failed(source_case_id, opts)` creates a NEW permission continuation from the preserved failed case. Validate original authenticated task provenance, exact current repo/base/check/frozen policy, complete sole native submit_edits call with strict schema, applied blocks equal response, and the later artifact error. Reconstruct a fresh owned checkpoint from committed base + validated saved edits if needed. Preserve the old case/stream unchanged; link both records and raw response digest.

- [ ] Write RED fixtures matching F15's actual saved shape: finish_reason tool_calls, exactly id/name/arguments, applied edit event, artifact error, no later check/review. Reject partial/unknown partial flags, mixed/extra calls or keys, changed block set/authority/base/policy and unrelated failure stages.
- [ ] Adoption creates waiting_permission, not a coder run or an automatic grant. After the frontier grants, fresh preparation/check/review/Companion must complete through tasks 3–4, with only new reviewer inference. Failed recovery retains all work and does not retry coding.
- [ ] Run new tests RED/GREEN, existing textual replay tests unchanged, and full suite. Commit bug:0981773 and record how it replaces this F15-specific need on 0697491; broader replay remains held.

### Task 6: Review, idle deployment and one real F15 continuation

**Files:** spec/operations/checkpoint evidence only; do not hand-edit VORTEX product code or merge a generated candidate into main.

- [ ] Claude reviews each bounded pin; address significant findings with RED→GREEN evidence. All commits reference existing issues and stay <=255 characters. No rollout until full suite passes.
- [ ] Prove ONE configured frontier can receive an idle notification, fetch bound evidence and return an authenticated decision WITHOUT starting the armed old Codex daemon. Current manual `claude attach` pairing stays in use; ping-claude mail behaviour is unproven for this purpose. If the end-to-end route is missing, fix that tool before enabling live permission policy; never count queued mail as a wake or fake a receipt.
- [ ] Idle preflight: no runner queue/worker/open active case ownership, Bridge/model/resource/profile leases reconciled; preserve F15's existing files and source transcript. Build release BEFORE normal restart, back up local config, enable only reviewed P1 peer/notifier policy, verify health/default Q8+DSpark/artifact policy after restart.
- [ ] Adopt EXACT source `vortex-c4a0fdcdb16158bce3f4889e5087e6247d19501717bc30656bbdd1baa055562f` at base afca2ef via task 5. Send initial active notice; frontier judges observed consequences and returns a bound decision. Keep the same established Codex/Claude pairing throughout. Do not start another coder attempt.
- [ ] Verify candidate source/native blocks, directory evidence, authenticated decision, resumed stage, clean second build, project check, fresh review, independent Companion result and native cleanup. Send Claude exact evidence/candidate for acceptance. Reconcile cards only after actual success; otherwise preserve the checkpoint and file the concrete tool gap, no unchanged retry.
