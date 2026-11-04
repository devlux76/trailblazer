# Frontier permission continuation P1 implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans task by task. Frontier agents may repair these tools; Claude reviews each bounded pin. No parallel implementation or new coder delegation is assumed.

**Goal:** Observe an artifact scope exception, wake an authenticated frontier decider, and continue preserved work under a bound decision without another coder call.

**Architecture:** A generic permission record/checkpoint owns decisions and continuation state in CaseStore. A local postmaster repairs correspondence and addresses; host records supply the stamps. A supervised Planner coordinator owns transport, active notification, deadlines and board mirrors. Loop/Runner/Bridge suspend and resume one recorded stage; artifacts is the first real consumer.

**Tech stack:** Existing Elixir/OTP, Exqlite CaseStore writer, Jason, VORTEX v5 authenticated direct messages/outbox, current local notifier routes. No npm dependencies or new coding model. LFM3 is an intent parser/postmaster, not a risk decider.

**Spec:** `docs/superpowers/specs/2026-11-03-planner-risk-permissions-design.md` at c1b8427 (operator postmaster revision, approved by Claude).

## Global constraints

- SPEC FIRST. This is a plan, not authorization to call an unimplemented path working. Base: deployed main 0f60f21; 86eb4bf is not merged into this line.
- P1 has frontier-only decisions. Local postal-intent parsing is allowed; local risk judgement is not. No calibration implementation, bwrap enforcement claim, global policy self-edit, new arbitrary commands, push or VORTEX cutover.
- Permission timeout defaults to 14,400 seconds, configurable locally; an earlier explicitly admitted hard deadline wins. One reminder at max(lifetime - 1,800 seconds, lifetime/2) after creation, strictly before expiry (use persisted millisecond times).
- Expiry ends the REQUEST as no_decision; the CASE stays blocked/resumable. Preserve incomplete work, including confused/partial output. No automatic deletion of unfinished worktrees/branches.
- Discard code only after review/evidence establishes it is bad, unused, inefficient or superseded. Incompleteness or slow inference alone is not such evidence.
- `task.files` remains context. Approval does not bless a stale check; all approved content enters fresh check/review/commit.
- Proposed authority floor retains current scope; P1 detects known violations but does not prevent or prove absence of outside writes.
- Existing 0697491 WIP stays held. Build a reviewed continuation path, not an unreviewed stash transplant.

## Review focus

- Notice-only replies and one-word confirmations work without show-command knowledge; stale/ambiguous/qualified consent asks instead of guessing (2a–2d).

- Paused worker exit/restart must not become a failed coding case: tests in task 3.
- Expiry, notification ambiguity, duplicate/late decisions and crash races must preserve work: tasks 1–2.
- Evidence must not confuse ignored files, untracked content, directory metadata and Git content: task 4.
- A successful check against changed but uncommitted source is unacceptable: tasks 3–4.
- Mailbox delivery must not be described as waking an idle frontier host: tasks 2 and 6.

## Reviewed baseline and superseded work

Task1 storage/snapshot/followups, Task2 notifier, low-level policy and internal codec through e527ccc are Claude-approved, with last full suite 869 pass / 4 excluded. They are **not deployed**. Unreviewed notification-ledger WIP 4047a05 is preserved on `codex/permission-notification-ledger-hold` (11 focused tests only). Reconcile/reuse after review; do not discard or silently transplant it. This plan replaces the earlier strict sender/show-first Task2 workflow. First live P1 config uses Codex only; Claude noninteractive target/sender/wake remains unproven.

## Grounded seams and preflight ledger

- Loop.run unconditionally closes CaseRecord today. Runner.handle_info(DOWN) calls fail even on normal exit. Both need explicit durable-pause handling.
- Bridge releases the active lease on worker DOWN, but Store's request can remain running; dispatch then fences all later work. Add waiting_permission/resume_ready handling, not just a UI status.
- CaseRecord only appends to open cases. Keep task_case open with a separate permission state; do not invent another terminal case status and break event appends.
- Decision.choose is card selection, not a permission API. Do not reuse its model answer as authority.
- CaseStore.case_append and lifecycle_cas are serialized writer operations. New permission CAS must journal its event atomically; calling CaseRecord.event from inside CaseStore.transaction would deadlock.
- Current ping-codex emits queued/started/steered; queued is not active wake. Current ping-claude wrapper sends VORTEX mail. Tonight's Codex-to-Claude turns used `claude attach` plus input, so they do not prove ping-claude's idle behaviour.
- Interface dependencies: tasks 2–5 consume task 1's record/digest/CAS; task 3 consumes task 2's authenticated transitions; task 4 supplies task 1's evidence and uses task 3's continuation; task 5 imports F15 into that same path; task 6 gates actual configuration/deployment. Resolve mismatches against the spec before coding.

### Task 1: Durable generic permission contract and preservation

**Files:** create `lib/trailblazer/loop/permission.ex`, `permission_checkpoint.ex` and their tests; modify `priv/migrations/002_cases.sql`. The existing `CaseStore.transaction/1` already provides the serialized writer contract; no CaseStore refactor is needed.

**Interfaces:** `Permission.open(case_id, consumer, evidence, checkpoint, opts)` -> `{:ok, request_id}`; `get/1`, `for_case/1`; `decide(request_id, authenticated_peer, decision, now_ms)`; `expire(request_id, now_ms)`; `claim_resume(request_id, now_ms \\ system_clock)` -> `{:ok, checkpoint}` once; `finish_resume(request_id, outcome, now_ms \\ system_clock)`. The optional clock is supplied by the host, never the decision payload. A lost row CAS returns `{:error, :conflict}` without a journal event or writer restart. No function takes a model-chosen executable.

- [ ] Write failures proving atomic request+event creation; case remains open; immutable before/after evidence/checkpoint digests; frontier binding includes case/base/policy/source/exception digest and request nonce.
- [ ] Test grant/refuse/escalate/amend_policy, unauthenticated peer, changed evidence, duplicate/late grant, grant/expiry race, and expired request followed by a NEW request reusing the checkpoint. Expiry must retain authored/untracked/binary files, modes and partial response bytes.
- [ ] Run `mix test test/trailblazer/loop/permission_test.exs`: expected RED on absent capability, not fixture/setup errors.
- [ ] Implement one generic table/journal through the CaseStore writer with CAS states waiting, granted, refused, expired, resuming, resumed. Preserve case checkpoint separately from request outcome. Spill large evidence via verified manifest under the case directory; protocol carries its digest/reference, not full source blobs.
- [ ] Run the focused file GREEN, then commit citing bug:0981773. No code must silently migrate a closed old case to open.

### Task 2a: Durable correspondence and issued-view context

**Files:** create `lib/trailblazer/planner/permission_mail.ex` and `test/trailblazer/planner/permission_mail_test.exs`; modify `loop/permission.ex`, `priv/migrations/002_cases.sql`, existing permission tests. Reuse CaseStore's serialized transactions and verified case spill storage; avoid a second persistence engine.

**Interfaces:** `PermissionMail.ingest(authenticated_context, text, now_ms)` -> `{:ok, mail_id}` idempotently by actual peer/message id. Context contains verified peer/direct room, message id and optional reply context, never a text-supplied actor. `issue_view(mail_id, request_id, view, proposal, now_ms)` prepares the exact public view/binding/question before its reply effect. `confirm_view(question_id, authenticated_delivery_context, now_ms)` marks delivery/display from verified client/transport facts; preparation/queued mail alone is not a shown receipt. An authenticated reply carrying the issued question context can confirm receipt and answer atomically. `get/1` and `pending/0` recover originals, partial parser output, questions and stamps. `Permission.public_view(request_id)` contains immutable evidence/binding fields only, excluding private notifier env/routes.

- [ ] Write RED tests: duplicate intake creates one item; original/free text and binary/partial evidence survive restart; private route/credential sentinels never enter public views/replies; unknown peer/room cannot mint an issued view.
- [ ] Write RED tests: issued view binds actual recipient, request, evidence digest, question/proposal and reply context. An HTTP actor-name parameter cannot fabricate this context; recording delivery/display does not claim human attention. A never-delivered question plus an uncorrelated yes cannot grant; reach back with the view. Question context is attached automatically by the client/transport, never hand-copied by the decider.
- [ ] Run `mix test test/trailblazer/planner/permission_mail_test.exs test/trailblazer/loop/permission_test.exs` RED; implement the narrow journal/view APIs, run GREEN, commit bug:0981773.

### Task 2b: Postmaster intent, repair and host stamping

**Files:** create `planner/permission_postmaster.ex`, `planner/permission_intent.ex` and matching tests; modify `model.ex` plus its tests only for the per-call target seam below.

**Interfaces:** `PermissionIntent.parse(text, context, opts)` returns a proposed outcome/request/scope/conditions/reason or a clarification; it has no permission-write or executable tool. `PermissionPostmaster.receive(authenticated_context, text, opts)` -> `{:ready, mail_id, stamped_decision}` | `{:reply, mail_id, view_or_question}` | `{:held, mail_id, reason}`. Host lookups resolve requests/views; only the host creates nonce/hash/identity/scope stamps. The controller in 2c applies a ready result through Core.decide.

- [ ] RED: clear structured input needs no inference. Natural `grant <request>: mode change harmless` against its exact issued view stamps the presented scope, required commit paths and no invented normalization. Unknown fields/formatting can be repaired; intent is not silently changed.
- [ ] RED acceptance chain: a notice-only grant with NO receipt returns the verified view itself plus `confirm this grant?`; a subsequent **one-word `yes`** from the same authenticated context stamps the stored proposal against that sent view. No separate show command. Test through the correspondence/controller boundary, not just a parser stub.
- [ ] RED: wrong sender, another question's yes, several possible requests, stale/replaced view and old yes do not grant. Return the correct view/question and wait for fresh consent. Qualified/partial statements, negation and quoted instructions cannot become a broader unconditional grant; request clarification when not resolved.
- [ ] RED: parser outage/malformed/truncated reply preserves the message and returns an easy clarification, not a default grant or a case failure. Duplicate delivery/question replies do not execute twice; no autonomous parse/clarification retry loop.
- [ ] Ground the installed LFM3 preset/model-card contract before trial. Router :8094 lists `lfm3-1.7b-q8`, currently unloaded. Existing Model.chat builds Config code_model/code_model_url plus Spark generation defaults. Its low-level req_options can override HTTP options, but there is no explicit postmaster target/profile; do not mutate global coder settings to repurpose it. Add an explicit host-configured per-call target/profile (`model`, `url`, `parameters`, output/time budget) if reusing its SSE client; preserve coder defaults and never toggle global app env. Prove separate parser/coder requests concurrently against real local test HTTP servers, including unchanged coder settings.
- [ ] Parser inference uses the existing resource budget. If another case holds it, retain a visible queued item; use release events/backstops rather than a second busy/polling/model loop. Add a release notification seam only if missing and test that it cannot steal another case's lease.
- [ ] Run new postmaster/intent tests plus `model_test.exs` RED→GREEN; full `mix test`, commit bug:0981773. No live postmaster authority until the corpus and real-host test in task6 pass.

### Task 2c: Authenticated controller, notification claims and board

**Files:** create `planner/permissions.ex` and tests; extend `loop/permission.ex`, `vortex/{protocol,store,bridge,settings}.ex`, `planner/{supervisor,companion}.ex` and focused tests. Approved notifier, strict internal codec and local-policy validator are reused, not rewritten.

**Interfaces:** supervised `Planner.Permissions` owns correspondence effects/timers. Persist the locally resolved policy digest in request binding; keep raw route env/endpoint config private. `Permission.notifications_ready(id, now)` is an internal host transition after THIS case's lease release is confirmed (task3). `claim_notification(id, peer, ordinal, now)` records an attempt BEFORE effects; `record_notification(...)` stores only normalized delivery. Inspect preserved WIP 4047a05 for reuse **after review**; it is not deployed/fully tested.

- [ ] RED: actual transport peer/room/current frontier policy AND frozen request membership/room/binding gate every stamp/decision. Body identity, tier, model, command or HTTP actor cannot confer authority. Removing a decider locally revokes it. Apply only a postmaster-ready decision through the final Core.decide CAS.
- [ ] RED: initial mail + active wake and one distinct reminder; ordinal claim precedes effects; claimed/unknown after crash is consumed, not blindly replayed. Restore absolute deadline/reminder/outbox state; expiry leaves case/work blocked and resumable. queued != admitted; admitted != read/decided. Notification reply questions use durable correlation, without an unbounded extra wake budget.
- [ ] RED: missing labels/addresses resolve from trusted peer/session bindings; unresolved/ambiguous routes hold that item and reach back. A repairable optional permissions/route defect does not disable unrelated coding or graph work. Base peer/authority configuration still fails closed; never guess a principal, arbitrary command or chat. Low-level policy validation runs after resolution; no model edits global configuration.
- [ ] RED: `escalate`/`amend_policy` immediately mirror blocked(escalated/amend_proposed, reason) on the assignment board and return operator-attention status to the frontier chat, including with only one decider. The preserved request remains decidable. Do not silently wait four hours or invent a higher tier. Mirror failures remain visible/recoverable.
- [ ] RED: timers/effects do not block the coordinator or hold a coder lease. Release failures remain visible; notification starts only after own lease release. Current+frozen membership and fresh source bindings survive restart races. Granted/resuming crash recovery is explicitly task3, not silently ignored.
- [ ] Run focused controller/bridge/Companion/protocol/settings tests RED→GREEN and full `mix test`; commit bug:0981773. No configured live route yet.

### Task 2d: Ergonomic decider client (show is optional)

**Files:** create `planner/permission_client.ex` and tests; modify `api.ex`, `cli.ex` and tests.

**Interfaces:** `trailblazer permission reply --decider ALIAS --text-file FILE [--request ID] [--reply-to QUESTION]` sends natural intent/confirmation through that decider's OWN verified VORTEX endpoint. IDs are optional when authenticated reply context uniquely resolves them. `permission show REQUEST --decider ALIAS` remains a convenience, not a gate. The existing structured decide command may remain a fast path through the same postmaster; the sender never hand-copies thirteen fields.

- [ ] RED end-to-end: own-peer `reply grant...` → view/question returned and displayed → `reply yes` → host stamp → Core grant. No shell JSON, separate show command, body actor or automatic daemon start. Own endpoint identity is verified with Transport.call expected_peer; credentials stay out of stdout/case evidence.
- [ ] RED: bounded public evidence paging verifies the whole immutable view digest, caches the exact issued view/question, and excludes private route/env bytes. Stale context asks with the new view rather than silently substituting it. Wrong service owner, wrong sender, duplicate replies and unknown request stay preserved/clarifiable without granting.
- [ ] The ordinary bearer-auth HTTP API is read-only for permission evidence/status. It cannot vote or mint a frontier view receipt from an alias/actor argument; the authenticated postmaster correspondence does that.
- [ ] Run client/CLI/API/protocol tests RED→GREEN and full suite; commit bug:0981773. Task6 uses this notice-only/yes path from the real frontier, not forged protocol/RPC data.

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
- [ ] Run a bounded saved corpus through the ACTUAL LFM3 parser/profile (including notice-only/yes, negation, qualification and ambiguity). Record model/quant/preset, requests, outputs and fallback behavior; no coding-model run. Unexpected grants block activation.
- [ ] Idle preflight: no runner queue/worker/open active case ownership, Bridge/model/resource/profile leases reconciled; preserve F15's existing files and source transcript. Build release BEFORE normal restart, back up local config, enable only reviewed P1 peer/notifier policy, verify health/default Q8+DSpark/artifact policy after restart.
- [ ] Adopt EXACT source `vortex-c4a0fdcdb16158bce3f4889e5087e6247d19501717bc30656bbdd1baa055562f` at base afca2ef via task 5. Send initial active notice; frontier judges the consequences and replies through task2d. Without a receipt, return the verified view/question; one-word yes confirms that exact view and the host stamps it. No separate show command. Keep the same established Codex/Claude pairing throughout. Do not start another coder attempt.
- [ ] Verify candidate source/native blocks, directory evidence, authenticated decision, resumed stage, clean second build, project check, fresh review, independent Companion result and native cleanup. Send Claude exact evidence/candidate for acceptance. Reconcile cards only after actual success; otherwise preserve the checkpoint and file the concrete tool gap, no unchanged retry.
