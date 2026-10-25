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

## Live acceptance finding: asynchronous unload (b3aac14)

Root ran a real Qwen fixture under Resource.acquire. It correctly chose p1
stability work over p3 documentation. Resource.release initially returned
release_unconfirmed even though unload succeeded asynchronously. A later
observation found every model unloaded, and releasing the SAME lease then
returned :ok. Keep this fence; do not weaken resource ownership.

The installed llama router supports real status SSE at
`http://127.0.0.1:8094/models/sse`. Frames are `data: JSON\n\n`, e.g.
`{"model":"qwen3.6-35b-a3b-mtp-q4","event":"status_change","data":{"status":"unloaded","exit_code":0}}`.
Use this actual event to wake cleanup after an initial unconfirmed release;
no polling timer. Preserve a validated decision durably across cleanup so a
normal asynchronous unload does not permanently lose every planning decision.
Only dispatch that stored decision after cleanup and a fresh matching snapshot;
never repeat model inference. Interrupted dispatch must still use the existing
idempotent assignment gate. Source evidence: llama.cpp server-models.cpp
1270-1295 (asynchronous unload), 1363-1380 (status event), 2170-2191 (SSE handler).
