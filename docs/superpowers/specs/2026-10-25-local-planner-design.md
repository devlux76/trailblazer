# Local planner brain

Operator request (trailblazer:cf1c78a): use local inference to prioritize and
dispatch tasks when frontier agents are unavailable. Trailblazer is the only
valid worker. Prior conversation delegates routine design choices to Codex;
all supervision stays in Elixir/OTP.

Use the existing Qwen coding model in a short structured planning call under
the existing dedicated resource adapter. Only consider open, unclaimed todo
cards bearing `dispatch:ready`, from admitted repository/check pairs. This
explicit current-work marker prevents unattended revival of the stale backlog.
The model selects a listed reference and target `trailblazer`, or waits, with
a short reason. It cannot invent commands, targets or repositories.

An OTP brain listens to real board-file changes and planner completion/resource
release events, coalesces notices, and runs one planning cycle while the worker
is idle. No periodic model polling. Persist the snapshot and resource intent
before inference; never automatically replay an interrupted/failed planning
call for the same snapshot. Recover resource cleanup before more work. Recheck
the snapshot and resource release before using the existing idempotent planner
assign command. Existing candidate verification remains unchanged.

Bound prompts, tokens and calls. Model failure, bad JSON, stale selection,
blocked cleanup or missing watcher stays visible and dispatches nothing.
No paid fallback, self-repair, automatic candidate merge or backlog relabeling.
