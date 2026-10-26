# Planner research route (GLM on OpenCode)

Operator request, 2026-10-25: with no paid frontier access until about
January, the planner brain routes each ready card one of two ways.

- **Well specified and targeted** → `trailblazer` (today's only target).
- **Needs research, decomposition or planning** → `research`: GLM on
  OpenCode over VORTEX. GLM investigates and returns child cards; it never
  writes code. The children land on the board and the planner routes them
  like any other card, normally to Trailblazer.

Everything below stays in Elixir/OTP; CLIs only record requests.

## 1. Routing decision

A card is `trailblazer`-ready when a deterministic check passes: it names the
files to change, states acceptance criteria (a test or check to pass), and is
not labeled `dispatch:research`. Otherwise it is a research card. The model
(`planner_model`, Bolt E4B once deployed) only breaks ties the check cannot
decide; its strict JSON schema gains `target: "trailblazer" | "research"`
beside `ref`. The model still cannot invent a target, command or repository.

## 2. Research dispatch

- One research job at a time (OpenCode must stay strictly serial). A research
  lease, journaled like the local inference lease, is held from assign until
  GLM's reply is recorded or the job fails.
- The brief goes to a fresh OpenCode session over a new VORTEX conference
  thread per card (one topic, one thread). It carries the card text and the
  output contract in §3, and never names a model.
- The research route never takes the local inference resource and does not
  count as "worker busy" for Trailblazer: a Trailblazer card may run while a
  research job runs.

## 3. Output contract

GLM replies with child cards, each with a title, the target repository
(admitted repos only), named files, acceptance criteria and `dispatch:ready`.
The brain validates every child (same rules as §1); invalid children are
journaled and dropped. Valid children are added with `planner add`, linked to
the parent, and the parent is noted and moved out of `todo` (it is done when
its children are).

## 4. Errors and holds

- An assign or delivery error (quota exhausted, OpenCode down, VORTEX
  refusal) puts the card **on hold**: journaled with the error, not retried
  inside the cycle, not relabeled. Trailblazer-ready cards keep flowing.
- A held card is retried on the next real event that can change the outcome:
  an OpenCode/VORTEX recovery notice, or a board change. The free tier
  resets daily at 18:00 local; that clock may be used only as a backstop
  that triggers one check, never as a polling loop.
- No loops: a card is researched once. If its children still fail §1, or GLM
  returns none, the parent is blocked with `planner block` for the operator
  instead of going back to GLM.

## 5. Tests (TDD)

Routing check (both outcomes and the tie-break), schema validation of the
target, the research lease being serial, hold on each error class and retry
only on an event, child validation and the parent's state, the once-only
research rule, and Trailblazer dispatch continuing while research is held.

## Decisions (as implemented, trailblazer:4cc63df)

- The deterministic route check (`Trailblazer.Planner.Route`) runs before the
  model: both markers → trailblazer, one marker → tie, none or the
  `dispatch:research` label → research. The model only breaks ties and picks
  targets for research cards.
- `Research.dispatch/2` answers `:ok` under one serial job; every refusal is
  a tuple (`{:error, :busy}`, `{:error, {:researched, state}}`,
  `{:error, {:claim, tail}}`, `{:error, {step, reason}}`,
  `{:error, :not_configured}`) and the same text lands in the brain's
  journal: dispatched, unavailable, assign_failed.
- A per-child add failure drops that child into the journal instead of
  holding the whole reply; the surviving children still count.
- The reply backstop is three hours (one armed timer per waiting job).
  Firing holds the card with its claim kept and frees the slot; a reply that
  lands later changes nothing. `{:research_recovered, peer}` or any other
  planner event wakes the brain's cycle, which re-dispatches held cards.
- The brief is one JSON object (card text, admitted repo basenames and the
  reply contract); it never names a model. The bridge lifts conference
  messages unaltered to the planner; the direct-room protocol intake is
  untouched.
- The brain's production default dispatch is the named research server in
  the planner group (`Trailblazer.Planner.Supervisor`), and the server's own
  transport is the application's authenticated VORTEX endpoint. Research
  never takes the local inference resource: a worker busy for Trailblazer
  stays independent (the brain gates as before).
