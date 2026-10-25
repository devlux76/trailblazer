# VORTEX coordination acceptance — 2026-10-19

Implemented as `df5dc23`, then continuous listener `fb829fd`. Deployed locally.
The primary repair target remains Mirai. This is the coordination foundation;
it is not acceptance of unattended Mirai repair or Qwen's Elixir competence.

## Verified

- Independent code review found two P1 transport defects and one report omission.
  Regressions first reproduced stalled coordination, recursive timeout reporting,
  omitted commit/check and inaccessible returned-fix metadata; fixes passed.
- Final full suite: **516 passed, 4 excluded**, seed 825637's separate acceptance
  followed by full suite (full-suite seed is retained in the log). Explicit
  VORTEX suite: **21 passed**, including real disposable VORTEX/SQLite/Loop/git
  and Elixir checks with scripted replies. Formatting, production compilation
  with warnings as errors, escript and release build passed.
- Scripted acceptance verifies one actual repair and exactly three failed
  attempts followed by escalation, delivery receipt distinct from claim,
  interrupted running Loop recovery with evidence and an unreleased residency
  fence, and no replay/fourth attempt. Returned fixes are data awaiting
  verification; sender, claim, correlation, conflicts and restart retention
  have deterministic coverage.
- Live Codex/application exchange admitted one probe as waiting for resources,
  survived the release update, then honored caller cancellation and returned a
  receipted cancellation report. A fresh second exchange exercised the deployed
  continuous listener. No model ran and both cases have zero attempt events.
- Live outbox reached zero, no open cases, no resource-release fence. Twenty-three
  pre-existing anomalies reached Codex and received application delivery receipts;
  they remain unresolved and unclaimed, with complete notices archived.
- OpenCode and vortex-opencode remained stopped. Mirai/router/model services,
  canonical repair repositories and the pre-existing .gitignore edit were
  preserved. Only Trailblazer and its own VORTEX connector were restarted.

Production permits only the isolated acceptance repository and recognized
Codex collaborator. Resource acquisition defaults to denial. A model-free
continuous wait/read/ack path avoids VORTEX's four-model-wakes-per-hour cap;
its fixed ring adapter is a recovery path, never inference. After transport
failure, recovery is event/ring/manual driven rather than a busy retry loop.
The old connector post-start script that dialed offline peers is overridden.

## Versions and retained evidence

Trailblazer source/deployed release: `fb829fd9f1eccbe866c35ae9fc2783f4e850111f`.
Scripted VORTEX fixture source: `eb87187e208c89d5d398891eda30514bb7655eee`.
Actual VORTEX application deployment: `d9d254f6a1646849bd071095eb59c1faf06ad9ba`.
Actual Codex connector deployment: `35d6f8970a834a555edf0ea83d02befa6b7252e1`.
These deployments differ; the live exchange separately establishes the tested
compatibility rather than assuming source/deployment identity. Bun 1.4.3,
Elixir 1.20.4. Mirai source was clean at
`0de003b3b56d7e398c66f4783b9934a445917bcf`; it was not modified.

Private local archive: `~/.local/state/codex/trailblazer-followup-2026-10-19/`:
`vortex-review-red.log`, `vortex-owner-red.log`, `vortex-listen-red.log`,
`vortex-listen-final.log`, live inbox pages/receipts/status/report JSON,
`vortex-deploy-before/` (consistent cases.db and prior CLI), and prior release
backup. Last processed Codex inbox cursor 412; a subsequent read was empty.

## Remaining acceptance gates, in order

1. Coordinate actual Mirai/Qwen unload/load ownership and verify residency,
   holding the same resource lease across coder, reviewer and verification.
   Worker death or a released process lock alone is not proof of unloaded model.
2. Connect Mirai's real harness fault emitter to durable authorized admission;
   exercise triage, at most three local attempts, then frontier handoff.
3. Independently validate a returned commit's base, scope and trusted check under
   new resource ownership before executing verification. Returns currently wait.
4. Prove Qwen's Elixir ability on a bounded Mirai defect in an isolated checkout:
   reproducer fails first, generated patch passes real tests, canonical source
   stays unchanged, and three failures demonstrably reach a frontier model.
5. Only after those, resume deferred T1–T4 and cost/quality trials.

Operator clarification after this checkpoint: Claude availability imposes no
hold on live Mirai/router/model work. Codex is authorized to implement and test
the resource handoff now. Keep inference serialized and verify model release;
OpenCode and its connector must remain stopped.
