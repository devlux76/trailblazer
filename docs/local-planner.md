# Local planning and dispatch

The optional planner brain defaults to Nemotron-3.5-Bolt-E4B on its separate
local router (`spark` remains the coding worker; see design-2.md §7.2). It
prioritizes current work and its only target is Trailblazer. It has no paid
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
merge or deploy it through the current Planner/VORTEX route. The core's
optional coordinator is implemented, but explicit `primary` admission through
the resource gate and its live acceptance remain trailblazer:1beebca.
Producer interruption before admission and complete assignment generations
remain shared:40dbd63. Source issue: trailblazer:cf1c78a.

## The research route

Implementation gap: production `Research.endpoint_transport/0` currently
expects a map, while `Vortex.Settings` returns a keyword list. The route below
is its intended contract; live dispatch is blocked by bug:c1a47cb until that
wiring is repaired and tested against the real settings loader.

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

Edit mode (`edit_mode` per task, default `Config :code_edit_mode`, env
`TRAILBLAZER_CODE_EDIT_MODE`): `tool` (below) or `text`. In `text` mode the
coder gets only the retrieval tools and the `coder_text` prompt; once reading
ends it is asked, with no tools offered, for plain-text SEARCH/REPLACE blocks,
parsed and applied all-or-nothing by `Edits`. Small local coders handle the
text form far better than JSON-carried code (2026-11-05 A/B: Nemotron Bolt
0 applied edits with the range tool, 3/3 passes with text blocks).

The coding worker exposes `submit_edits` alongside its retrieval tools.
It also exposes `edit(path, search, replace)`: one change per call with plain
string arguments, so a model whose native tool format carries strings raw
(Spark's `<arg_value>`) writes code unescaped. Every call of a reply that holds
only `submit_edits`/`edit` calls joins one all-or-nothing batch.

Commit subject: the request's first line. Over 255 bytes, every `bug:<id>`
reference is kept whole at the end and only the prose is shortened with
`...`; if the references leave under 40 bytes of prose, the work stays
uncommitted as before.
A nonempty `blocks` array accepts two strict shapes:

- Legacy: `{path, search, replace}`, all strings; empty search creates a file.
- Read-backed: `{path, sha256, start, end, first, last, replace}`; digest is
  lowercase 64-hex from a read of the full original file bytes, and line
  numbers are integers. `start >= 1`; inclusive `end` may equal `start - 1` to
  insert. EOF insertion uses `start = lines + 1`. Ranges require an existing
  file. `first`/`last` quote the current text of lines `start`/`end` (empty
  past either end of the file); compared whitespace-trimmed, a mismatch refuses
  the batch (`anchor_mismatch`) and names the line where the quote actually is,
  so a miscounted range cannot silently overwrite neighbouring code
  (bug:9ae2ace, qual2 turn 3).

The read result includes path, digest, total lines and bounded numbered source.
All ranges for a file refer to that same version; edits do not renumber later
ranges. Canonical path aliases share one target. Overlap, duplicate insertion,
stale versions and mixed edit modes are errors; adjacent ranges and insertion
at a replacement boundary are valid. Untouched bytes are preserved. Legacy
SEARCH requires a unique match, with existing whitespace tolerance. Empty SEARCH on a nonempty file
is refused with its digest and full-file range, so a mistaken whole-file update
cannot silently append duplicate code.

Both forms share atomic preview/application, project checks, independent
review and candidate verification. Preview writes nothing, including directories.
At the read budget or during correction, only the unchanged `submit_edits`
schema remains advertised; the host also permits only submission. This one
toolset transition can invalidate the prompt prefix cache. The DSpark backend
accepts `tool_choice: "required"`; a named function-choice object is unsupported
and must not be relied on.

For native calls, a missed batch or malformed/mixed/forbidden call gets a compact
tool result in the same conversation. Its original arguments remain in history;
the model resubmits the complete corrected batch. Two correction calls are
allowed, then `edit_repair_exhausted` stops and retains work/evidence for review.
No full coder retry or workspace reset is caused by that exhaustion.
A zero-read miss with no recoverable source stops immediately. Error feedback
does not repeat replacement code and bounds the complete feedback to 12,000 characters.
Tool submission alone is not success. Legacy Aider text remains supported.


For explicitly named existing-file tasks with read rounds, the native schema
advertises only the range shape. A bounded Spark conformance test accepted this
shape but selected empty SEARCH when both shapes were advertised, even after
reversing their order. Zero-read, missing-file and unspecified-file tasks keep
the compatible dual schema. Host decoding still accepts both; the selected edit schema stays
stable throughout each attempt. Reading tools are removed from the advertised
toolset once reading ends or a correction begins; only `submit_edits` remains. The format choice is recorded as `edit_format`.

A complete whole-message JSON edit array or `{ "blocks": [...] }` object,
optionally inside one `json` fence, also uses that exact validator and pipeline.
Extra fields, malformed/partial JSON and surrounding prose are rejected; code
strings are never unescaped or repaired heuristically.

`planner assign ... --replay-reply-from CASE` explicitly recovers the last
complete structured coder reply of a closed failed case. Source peer,
repository, check and original Git base must match. The source remains failed;
a new case records its reply sequence and SHA-256, applies the unchanged bytes,
then runs the normal check, fresh review, commit and independent verification.
It performs no coding inference and makes only one recovery attempt; failed
review keeps the artifact for inspection instead of regenerating or resetting.
Unambiguous Markdown verdict headings use the existing exact PASS/FAIL rules.

A complete native `submit_edits` reply from a case that failed at artifact
preparation can also be replayed under the same gates: one tool call, strict
schema, no truncation, recorded blocks equal to the call's blocks, and no check
or review after the edit. It makes no coder call and no retry; preparation,
check, review and Companion run fresh.

An explicit assignment can set `planner assign ... --read-rounds N` (0 through
6, default 6). The validated task field survives admission and persisted case
recovery. Zero advertises only `submit_edits` from the first coder call;
use it when the supplied implementation plan resolves every needed edit. Other
tasks can retain a small read budget. Repeating an existing assignment with a
different budget is refused; reconcile it before starting a fresh task. Reading,
output and wall-clock budgets are separate controls.

`--reasoning-tokens N` supplies an optional per-task thinking limit to the
backend's native `reasoning_budget_tokens` field. It must be nonnegative and
below the total response cap, reserving room for an answer or edit submission.
Omitting it preserves the backend default. The supervised audit queue explicitly uses 2,048 reasoning tokens within its 16,384 output cap (operator update 2026-11-04). It leaves high reasoning effort and
model-card samplers intact. A reasoning-only response cut off at the total token
limit is recorded as output exhaustion and stops the case without repeating the
same budget; partial reasoning remains available for diagnosis.

For supervised work that should continue while progressing, call
`Trailblazer.Planner.Companion.observe(case_id)`. It persistently disables the
assignment's result deadline, including across recovery, and preserves automatic
independent verification when the case closes. It never stops the worker.
The local checked launcher uses this mode and a cleanup-only native observer;
This disables only the assignment result alarm. It does not disable the
hour-of-code execution limits: three fresh coder contexts, at most 15 minutes
each including all read/correction calls, plus one shared 15-minute verification
allowance. Preserve partial replies and pin each failed tree before reset. Three
unsuccessful attempts return decomposition_required and block the parent for
smaller tasks, rather than silently readmitting it. Verification expiry preserves
the tree for frontier checks; no new coder run is authorized.

After a failed check or review, the next coder prompt includes the exact latest
applied edit blocks as reference, captured before the check ran. The next
attempt continues from those edits (2026-11-05, operator): the worktree resets
to its base, which discards check- and tool-induced mutations, and is then
restored to the tree the model's own edits produced, so compiler lines and test
failures refer to the files the worker now sees and it makes corrective edits.
An attempt that wrote nothing carries the previous attempt's tree. Changed paths
accumulate across attempts, and each attempt's checkpoint ref is unchanged.
Resetting to the original base instead made the feedback describe code that no
longer existed.

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

## Compiling code is committed even when tests fail

The locally trusted peer policy can map each admitted repository/check to a
separate compiler command:
`"compilation": {"/path/to/worktree": {"full trusted check": "compiler command"}}`.
The worker freezes that command into the admitted task; remote payloads cannot
set it. Populate it for compiled-language checks instead of guessing whether a
failed combined command reached its test phase.

A successful compilation creates a normal hooked commit in the case's private
compiled-checkpoint branch before tests/review. The checkpoint has its own
refreshed index and recorded pending-vector count, and survives execution retries.
Failed tests produce a linked Git-bug report; a final checked/reviewed candidate
resolves reports. A compiling commit does not merge itself or pass review.
