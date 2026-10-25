# Trailblazer acceptance follow-up implementation plan

> For agentic workers: use `superpowers:executing-plans` for Codex's supervision and verification. Implementation is delegated serially to the existing MiniMax M3.1 Flash OpenCode session. Do not start this plan during closeout; begin in a fresh session after reading the resumption note.

**Operator reprioritization:** Tasks 1–2 were implemented at `00337fe`.
T1–T4 live acceptance is now deferred until the VORTEX-first coordination,
exclusive model-resource handoff and Mirai incident/three-attempt escalation
path in `docs/design.md` §11 is built. The T1 rerun was deliberately interrupted
and its evidence archived; this is deferral, not an acceptance result. The
OpenCode provider exhausted its daily allowance; its server and VORTEX
connector remain stopped. Codex owns the next work. Do not resume an old
OpenCode session or the paused acceptance monitor from this plan.

**Goal:** finish the acceptance gaps exposed by deployed B11 without expanding the completed event/pipeline work into another redesign.

**Architecture:** preserve the existing `Loop.run/2`, trusted check command, installed-repository sources, case records and three-attempt limit. Codex owns diagnosis, bounded briefs and independent review; MiniMax M3.1 Flash implements one reviewed change at a time. Commit verified work directly on `main`, as the operator requested.

**Tech stack:** Elixir 1.20 / OTP 29 through `mise`, ExUnit, Bun, installed Babylon packages, OpenCode's existing `opencode-go/minimax-m3.1-flash` session.

**Spec:** `docs/design.md` sections 6.5, 7.4, 7.5 and 13; the T1-T4 acceptance definitions and deployed closeout in `docs/trials.md`.

## Constraints and review focus

- The old MiniMax M3.1 Flash checkout was archived and removed during closeout. Bind the existing session's next bounded task explicitly to `/home/mirai/projects/trailblazer` on `main`; never reuse its deleted `trailblazer-sb` directory. Read [closeout verification](2026-10-19-closeout.md) before starting.
- No local model calls or live-service changes in unit tests. Never index Trailblazer with itself.
- Preserve explicit trusted check commands; do not silently replace them with inferred commands.
- Design rules win over contradictory requests. Installed dependency sources establish actual APIs.
- No sleep/poll scheduling, timeout weakening, global backstop-count workarounds or broad refactoring.
- Keep source excerpts bounded and report missing evidence honestly. A dependency name or path is data, never a shell command.
- Preserve the input repository and unrelated edits. Acceptance branches are evidence, not automatic product changes.
- Test reset/retry state, an invented dependency export, a check that does not import the edited file, absent dependencies and an unavailable reviewer/model.

## Task 1: explain retry state correctly

**Owner:** Codex diagnoses and reviews; MiniMax M3.1 Flash implements only after a deterministic reproduction.

**Files:** `lib/trailblazer/loop.ex`, `lib/trailblazer/loop/prompts.ex`, `priv/prompts/coder.md`; regression tests in `test/trailblazer/loop_test.exs` and `test/trailblazer/loop/prompts_test.exs` if prompt-only coverage is needed.

**Interfaces:** retain `Loop.run(task, opts)` and `Prompts.coder(task, trail, files, feedback, head)`. A failed attempt's next prompt must describe the restored workspace, not imply that its previous edit remains applied.

- [ ] Codex reads case `20261019-072205-0a9e7b`, its prompt/reply/check events and `attempts/6`. Separate the generated test's wrong arithmetic (`31 h` versus `3 h`) from the reset-related edit miss; do not label both a harness defect.
- [ ] MiniMax M3.1 Flash adds an ExUnit scripted-model regression: attempt one adds a test and fails its check, the workspace resets, and attempt two must see feedback explicitly stating that the previous edits were discarded. Assert the second attempt reads the original file and can apply a complete corrected patch.
- [ ] Run that regression RED before changing feedback. Keep the stable prompt prefix unchanged; append the reset explanation to existing failure feedback only where reset succeeded. A reset failure must still stop the case.
- [ ] Run `mise exec -- mix test test/trailblazer/loop_test.exs test/trailblazer/loop/prompts_test.exs`, then the full suite. Codex inspects every changed line and the prompt-size/cache assertions before committing.

## Task 2: ground dependency reuse in installed source

**Owner:** Codex defines the small lookup and its containment/budget rules; MiniMax M3.1 Flash implements the approved brief; Codex reviews.

**Files:** a bounded helper under `lib/trailblazer/loop/`, wiring in `lib/trailblazer/loop.ex` and `lib/trailblazer/loop/prompts.ex`; tests under `test/trailblazer/loop/` and `test/trailblazer/loop_test.exs`. Do not alter graph indexing or scan all dependencies on startup.

**Interfaces:** evidence is a list of `{relative_path, excerpt}` entries prepared once for a task. Pass the same verified evidence to coder and reviewer; retain existing prompt APIs through an explicit optional argument or head-start field, chosen in the brief before implementation.

- [ ] Codex specifies the first supported case: a task proposing a named helper in a Bun project with a Babylon-first rule. Read installed package exports/declarations for that helper; include the declaration and importable namespace, not a model's remembered spelling. Bound results to 20 hits and 8 KB; reject paths escaping the trusted repository/dependency roots.
- [ ] MiniMax M3.1 Flash creates a tiny installed-package fixture exporting `Scalar.Clamp` and deliberately not exporting `MathUtils`. The tests must show both prompts receive the real declaration, the invented namespace is not presented as evidence, and an absent package yields an explicit absence instead of a guessed API.
- [ ] Add containment and size-limit cases before implementing the helper. Do not run package scripts, install dependencies, or execute commands supplied by a model response.
- [ ] Implement just this lookup and prompt wiring; keep request-independent evidence before retry feedback to preserve cache reuse. Run focused tests, prompt byte-accounting tests and the full suite; Codex reviews the exact diff and commits independently.

## Task 3: complete B11 with a check that covers edited TypeScript

**Owner:** Codex owns acceptance and triage; MiniMax M3.1 Flash prepares/reviews deterministic test fixtures and the task/check definitions.

**Files:** `docs/trials.md`; fixture coverage in `test/trailblazer/loop_test.exs` and `test/trailblazer/loop/check_test.exs` only if a missing harness behavior is reproduced. Do not change `Check.default/1` merely to make the trial pass: an explicitly requested check remains authoritative.

**Interfaces:** continue using the existing `trailblazer run --repo ... --check ...` and case reports. Strengthen the new trial's supplied check to cover type imports, rather than treating an unrelated unit-test pass as proof of compilation.

- [ ] Reproduce T4's invalid export cheaply: the installed Babylon package must reject `import { MathUtils } from "@babylonjs/core"`. Preserve this as the negative acceptance example, never as a Sojourney feature.
- [ ] Use `--check 'bun run typecheck && bun test'` for T4 and other TypeScript-wide edits; independently run `bun run build` on a proposed successful result. Demonstrate that an unused invalid import cannot receive a successful compile result.
- [ ] After Tasks 1-2 pass, Codex coordinates a bounded inference-lock window and reruns only T1 and T4 first. Record the check, source revision, actual dependency version, prompt section sizes, first-token time, total time and competing workload. If either fails, classify the defect before another run.
- [ ] T4 is accepted only for an import that exists and Babylon's own clamp, or a failure report citing the design. T1 is accepted only for correct duration arithmetic and a meaningful test. Never merge generated acceptance edits into Sojourney without separate product review.
- [ ] Once correctness passes, measure reviewer reasoning cost against an unchanged baseline. No no-think or budget reduction is approved by the earlier slow PASS results alone.

## Deferred measurements

- Mirai-agent vector-search acceptance remains unrun. Coordinate with its owner when available, use the inference lock, and verify its checkout and services before and after; this is not permission to change Mirai while Claude is away.
- A dedicated durable VORTEX investigation identity/fanout is still unresolved: a third identity cannot join an existing two-party direct room. Inspect current `Investigate` delivery evidence in the fresh session; design separate app-to-peer rooms or the intended conference membership before wiring delivery. Do not claim transport writes prove receipt.
- Sojourney's existing v1 issues retain their own plan and visual sign-offs. This Trailblazer plan does not authorize working through that product backlog during stand-down.

## Completion gate

Codex runs format, warnings-as-errors compilation, the full unit suite, production release build and an authenticated deployed graph query. Run Rust tests only if native code changes. Keep one primary checkout and `main`, preserve trial recovery data outside the checkout, record exact results in the resumption note, and stand down without scheduling new intensive work.
