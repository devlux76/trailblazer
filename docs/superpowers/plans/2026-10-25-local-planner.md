# Local Planner Implementation Plan

> Execute inline; do not create paid subagents. Verify independently.

**Goal:** A local model prioritizes current ready tasks and dispatches Trailblazer.
**Architecture:** OTP Brain coalesces actual events; Board reads current planner
cards; Decision asks existing local model for bounded JSON; durable case-store
journal fences repeat inference and interrupted resource ownership.
**Tech Stack:** Elixir/OTP, existing Req/Jason/CaseStore/Resource and planner CLI.
**Spec:** ../specs/2026-10-25-local-planner-design.md

## Constraints and review focus

Only marked-ready admitted cards, one target, no timer/model polling, no model
replay after failure, existing resource guard, no self-repair or merges.
Review forged output, concurrent claim changes, resource-release failure,
worker-busy races and restart between recording intent and dispatch.

## Steps

- [x] Add failing tests for output validation, eligible snapshots, event coalescing,
  unchanged-snapshot suppression, stale decisions and cleanup/restart behavior.
- [x] Implement Board/Decision/Brain with durable journal and optional config;
  wire it into the existing one-for-all group and resource/mirror event sources.
- [x] Run focused and full suites; test one actual local model decision.
- [ ] Commit against verified issue cf1c78a; rebuild/restart idle service and
  verify installed event-driven brain/status without stale backlog activation.

Verification: 702 full-suite tests passed (4 live/integration excluded); 26 focused Brain/NoClocks checks passed; actual local Qwen prioritization fixture selected p1 stability work over p3 typo. Free implementation delegate stopped and confirmed idle after quota exhaustion; final corrections independently implemented and verified inline.
