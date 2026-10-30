# Local planning and dispatch

The optional planner brain uses the existing local Qwen coding model to
prioritize current work. Its only target is Trailblazer. It has no paid
fallback. Elixir/OTP owns planning tasks, resource cleanup, dispatch and restart
recovery in the planner one-for-all supervision group.

Enable it in the Trailblazer service with `TRAILBLAZER_PLANNER_CONFIG` naming
the existing trusted planner dispatch JSON (`repos` maps absolute paths to
admitted checks). A repository must have exactly one check. The existing
VORTEX peer policy must admit the same repository/check pair.

Explicitly mark only current, well-specified work:

```sh
git -C /path/to/repo bug bug label new BUG_ID dispatch:ready
```

The brain considers unclaimed todo cards with that label, including defects.
It excludes its own repository. It reads admitted boards before selecting up
to eight short contexts ordered by priority; the local model then chooses one
or waits. It validates the listed reference and target, rechecks the board
fingerprint and worker availability, and uses the existing idempotent
`planner assign` command. It cannot invent a command or assignee.

Real git-bug changes, completed planner mirrors and confirmed resource releases
wake it. It does not periodically call a model. Repeated notices coalesce, and
failed/interrupted inference is not repeated for an unchanged board. A crash
stops old planning tasks and restores durable cleanup intent before new work.

The router unloads asynchronously. The brain retains the decision while
confirming cleanup through its status stream. A missing unload notice triggers
one bounded cleanup investigation after a minute; unconfirmed ownership stays
fenced. This backstop never retries inference. A stale selection is discarded.

To inspect or wake it from the release RPC console:

```elixir
Trailblazer.Planner.Brain.status(Trailblazer.Planner.Brain)
Trailblazer.Planner.Brain.wake(Trailblazer.Planner.Brain)
```

Inspect `state`, watcher health, `last` and `last_error`. A missing watcher or
fenced cleanup needs investigation; a wake is not permission to replay failed
inference. Fix the cause and change the current work deliberately, or restart
the idle service to recover an outstanding lease. Never restart during coding.

Completion produces an independently checked candidate branch. It does not
merge or deploy it. Producer interruption before admission and complete
assignment generations remain shared:40dbd63; automatic integration remains
trailblazer:1beebca. Source issue: trailblazer:cf1c78a.

## The research route

A ready card without a nonempty `Implementation plan:` line always goes to research.
The plan must resolve the starting code, ordered changes, interfaces, and test
assertions; files and acceptance criteria alone are insufficient. The research
reply must include a nonempty `plan` array of concrete steps for each child.

A planned card goes to the research route when its body lacks the `Files:` and
`Acceptance:` markers, or when it carries `dispatch:research`; the local
model only breaks ties and validates research targets. Research dispatches
to the research server in the planner group, which claims the card for the
research actor, opens one VORTEX conference per card, posts a brief with the
card text, the admitted repositories and the reply contract, subscribes for
a day and wakes the peer.

The peer answers with exactly one JSON object. Valid children become
`planner add` cards with the `dispatch:ready` label on their named
repositories and the parent is noted; invalid or off-board children drop
with a reason into the journal, and if nothing survived the parent is
blocked for the operator. A card is researched at most once afterwards.
Without a reply inside three hours the card holds with its claim kept; it
retries when the peer resurfaces, the board changes, or any other planner
event wakes the brain. Children completing wake nothing; the parent is
marked done by the planner mirror only once every child is done. Source
issue: trailblazer:4cc63df.

## Coding and verification contract

The coding worker exposes `submit_edits` alongside its read/search tools. It
accepts a nonempty array of repository-relative `path`, exact `search`, and
`replace` strings; an empty search creates a file. At the reading budget, only
this edit tool remains and the request explicitly selects it. Legacy Aider text
blocks remain accepted, but are not the required native editing interface.
Both formats use the same atomic edit application, project check, fresh review,
and independently checked candidate path. Tool submission alone is not success.

An explicit assignment can set `planner assign ... --read-rounds N` (0 through
6, default 6). The validated task field survives admission and persisted case
recovery. Zero exposes and forces only `submit_edits` from the first coder call;
use it when the supplied implementation plan resolves every needed edit. Other
tasks can retain a small read budget. Repeating an existing assignment with a
different budget is refused; reconcile it before starting a fresh task. Reading,
output and wall-clock budgets are separate controls.

`--reasoning-tokens N` supplies an optional per-task thinking limit to the
backend's native `reasoning_budget_tokens` field. It must be nonnegative and
below the total response cap, reserving room for an answer or edit submission.
Omitting it preserves the backend default. It leaves high reasoning effort and
model-card samplers intact. A reasoning-only response cut off at the total token
limit is recorded as output exhaustion and stops the case without repeating the
same budget; partial reasoning remains available for diagnosis.

For supervised work that should continue while progressing, call
`Trailblazer.Planner.Companion.observe(case_id)`. It persistently disables the
assignment's result deadline, including across recovery, and preserves automatic
independent verification when the case closes. It never stops the worker.
The local checked launcher uses this mode and a cleanup-only native observer;
30 minutes is the coordinator's review interval, not an automatic runtime cap.

Spark requests follow its model card: thinking enabled with `high` (its highest
supported effort), temperature 1.0, top-p 0.95, top-k disabled, repeat penalty 1.0,
and presence/frequency penalties 0. Effort is not a hard budget. Callers can set
`max_tokens` in model options to give each bounded task an explicit output cap,
independently of reasoning effort; a cutoff remains a failed attempt and cannot
apply partial edits. Wall-clock backstops remain separate. These are request
settings, not changes to the shared model preset. Do not tune an active run or
claim performance from sampler settings alone. Regression tests must cover native edits, the final forced submission,
malformed arguments, mixed read/edit batches, and transport options. A live
planner-to-candidate trial is required before claiming a protocol repair works.

## Verification-only recovery

Worker and detached verification worktrees use the same dependency provisioning
implementation, including package-level node_modules and candidate-local workspace
aliases. The verifier still pins the reported commit to its candidate branch,
runs the admitted check independently, rejects tracked mutations, and cleans up.

After fixing an infrastructure-only verification failure, explicitly recheck the
existing candidate from the release RPC console:

```elixir
Trailblazer.Planner.Companion.reverify("<case-id>")
```

This accepts only an existing fixed candidate whose planner verification is
blocked. It is idempotent while verifying or already verified, refuses open or
failed coding cases, and does not dispatch a coder, replay a model, merge, or
push. Verification evidence and the planner result follow the normal durable
companion path. Do not edit the assignment database to force completion.
