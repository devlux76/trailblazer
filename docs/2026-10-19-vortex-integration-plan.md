# VORTEX integration implementation plan

Operator authorizes Codex to use best judgment and deliver, with independent
review. Execute inline. The local model does not change its own harness.
Spec: docs/2026-10-19-vortex-integration-design.md; design.md §§7.5,7.8,11,13.5.

1. Protocol and transactional inbox/outbox: strict versioned schema, authenticated
   peer/room and repository/check policy, exactly one case per request; receipts
   bind peer/message. Add failing tests first. Same cases.db transaction stores
   admission, queue state and accepted outbox. No automatic ack-of-ack.
2. Model-free bridge and serial dispatch: receive through the app's own VORTEX
   endpoint, never peer credentials; reconcile on startup/ring/case events.
   Wait for a configured resource gate; production default denies inference.
   Preserve waiting-resource cases on restart. Interruptions escalate without
   replay. Add Runner submit-existing for pre-admitted cases, reject duplicates.
3. Reports and frontier handoff: actual Loop success and three failures are
   delivered to caller/frontier through durable outbox. Stable message IDs,
   receipt distinct from claim, preserve complete artifacts and bounded wire
   payload. Resource ownership remains fenced after worker death. Returning a
   fix is data awaiting independent verification, not shell instructions.
4. Isolated end-to-end: disposable real VORTEX services, real SQLite/Loop/git/
   checks, scripted model and resource gate. Verify success, three-failure
   handoff, acknowledgments, duplicate delivery and restart while waiting.
5. Independent review, meaningful fixes RED->GREEN, full suite and release.
   Install model-free ring adapter and do a controlled Codex/app exchange with
   execution blocked. Do not touch Mirai/router/OpenCode services or wake Claude.

Live Mirai incident emission, actual residency ownership and returned-fix
execution remain explicitly gated; do not claim model autonomy from mocks.
T1-T4 and cost comparisons stay deferred. Keep pre-existing .gitignore unchanged.

## Review and verification record

Independent review found synchronous transport could block coordination and
transport timeout anomalies could recursively trigger the failing send. Both
were reproduced as failing regressions, then fixed with asynchronous inbox and
per-peer senders and local-only retention of transport failures. Successful
reports now retain commit/files/check; returned fixes are visible, correlated,
idempotent and retained across bridge restart without execution. Lost cursor
ack replay preserves the same admitted case. A genuinely running scripted Loop
is stopped in the real transport acceptance; recovery retains its trail,
escalates it and fences unconfirmed residency without replay.

The new asynchronous boundary exposed existing Backstop.guard owner-death
cleanup: its unlinked IO survived a killed waiter indefinitely after that
waiter's backstop was removed. A failing regression reproduces this; guarded IO
now has an owner lifetime monitor without linking crashes back to the caller.
The earlier global armed-count race was test synchronization: investigation's
callback precedes its mark_sent write. The test joins that worker before its
unchanged assertion rather than weakening the count or altering production
semantics.

Runtime deployment and live exchange evidence are recorded separately from
scripted acceptance. No acceptance result here proves Qwen's Elixir quality,
actual model residency transfer, Mirai fault emission, or returned-fix execution.

The controlled live exchange exposed VORTEX's model wake cap (four per room per
hour) also charging the lightweight adapter. Production now uses the existing
VORTEX wait/read/ack event path continuously, without model wake credit or
polling. Its bounded IO worker leaves status/release processing free. Transport
failure stops the listener until a later ring/recovery call; it does not spin.
A failing regression and a subsequent live exchange verify this separately
from the explicit-pump integration tests.
