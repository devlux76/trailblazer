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
