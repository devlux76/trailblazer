# Dedicated Trailblazer resource adapter

Goal: execute one VORTEX case at a time while Mirai remains offline, then supervise bounded VORTEX repository work. Operator explicitly authorizes implementation/deployment; canonical main-only checkout and existing user edits are preserved.

Design: trusted local `resource_mode: dedicated` enables a supervised Resource GenServer. Acquire verifies mirai-agent system unit inactive, all router models unloaded except configured Qwen (idle when resident), and holds the same kernel flock used by inference-lock through a no-fork cat Port. Loop may load Qwen on demand. Release unloads Qwen and verifies every router model unloaded before dropping the lock. Failed release retains ownership/fences the next case. After resource process death, persisted bridge holds require a new lock and verified unload before clearing. This is dedicated offline-Mirai operation, not automatic Mirai resumption. Resource IO runs outside the bridge so status/inbox remain responsive. CLI run is refused in dedicated mode to prevent bypass. No self-modification, no merge of generated changes, OpenCode stopped.

1. Resource lifecycle tests RED, implement Resource with external system/router IO seams and real flock. Verify exclusion, active-Mirai/other-model denial, unload failure, stale lease, crash recovery.
2. Wire trusted Settings/Application/Bridge; asynchronous acquisition/release and supervised dispatch. Test config and bridge responsiveness; run full suite, explicit integration, format/prod compile/release; independent clean review.
3. Deploy dedicated mode only with Mirai inactive; allow only isolated probe and canonical VORTEX exact trusted checks. Exercise real one-case VORTEX coding and independently verify diff/checks. Reclassify actual failures, no blind retries.
4. Read VORTEX ISSUES/TODO; choose bounded existing TypeScript defect, supply tests/scope, submit one task, inspect case and resulting diff before dispatching any next task. Record usage/progress and arrange quiet periodic supervision if lengthy.

Review focus: lock Port lifetime after crashes; stale release cannot unload a newer owner; failed HTTP leaves fence; model response malformed fails closed; asynchronous grant arriving after cancellation never runs it.
