# Model-free VORTEX bridge

The bridge admits tasks durably, reports completion and hands failed cases to
an explicitly configured frontier peer. It does not start a model unless a
trusted in-process resource adapter grants exclusive ownership. The deployed
adapter currently denies every request: `waiting_resource` is expected.
Legacy supervised `run` remains unchanged.

Set `TRAILBLAZER_VORTEX_CONFIG` in Trailblazer's service environment to a trusted
local JSON file (0600). The file contains:

```json
{
  "endpoint": "/absolute/path/to/apps-own-vortex/endpoint.json",
  "owner_peer": "APP_PEER_ID",
  "peers": [
    {
      "peer": "RECOGNIZED_CODEX_PEER_ID",
      "room": "[\"APP_PEER_ID\",\"RECOGNIZED_CODEX_PEER_ID\"]",
      "role": "collaborator",
      "repos": {"/absolute/repair/repo": ["mix test"]}
    }
  ]
}
```

Use the exact mutually accepted room from VORTEX. The endpoint belongs to the
application; it never reads another owner's credential file. Role `caller`
admits requests, `frontier` accepts escalations, and `collaborator` does both.
Repository paths are canonicalized; checks must equal a locally configured
string. No peer-supplied shell command widens this policy. Trailblazer's own
repository is rejected. Unavailable peers should not be configured as frontier
recipients. Each task's first frontier assignment remains binding.

Production continuously waits for mail through the own authenticated endpoint,
then reads, persists and acknowledges it. This uses no model and does not spend
VORTEX's model wake budget. A failed endpoint stops listening until a later
local ring/recovery call; there is no busy reconnect loop.

Install `trailblazer-ring` as an executable and pass its absolute path to the
application's VORTEX service `serve --on-ring`. It calls the authenticated local
`trailblazer vortex` API, never model inference. It returns 75 when unavailable
or busy, so VORTEX retains and retries unread mail. Restarting this connector
preserves its state directory, identity and unread history. An explicit
`trailblazer vortex` reconciles after an interrupted delivery when no listener
is already active (an active reader returns busy).
`trailblazer vortex_status` shows queue states, pending delivery, resource fences
and retained returned fixes.

Messages are JSON with keys `protocol: "trailblazer/1"`, `type`, `id`,
`request_id`, `payload`, capped at 16,384 serialized bytes, optionally prefixed
`From NAME, not typed by the operator:` and a newline. A task payload contains
`repo`, `request`, `check`, optional `files` and `design` lists. Replaying the
same peer/request/task returns the same durable case; conflicting reuse is
refused. A `cancel` with payload `{"case":"CASE_ID"}` and the original
`request_id` cancels only that caller's waiting task.

Receipt payload `{"message_id":"ID"}` confirms application delivery of a
particular message, not success or resolution. Only the assigned frontier can
`claim` (`{"case":"CASE_ID"}`), then `returned_fix`
(`{"case":"CASE_ID","base":"40-hex-sha","commit":"40-hex-sha"}`), with
the original request ID. Returns remain `waiting_verification`; this slice
neither executes them nor proves their base/scope. Identical retransmission is
idempotent. Receipts themselves are not receipted.

Transport calls run outside the coordinator, with at most one inbox operation
and one sender per configured peer. A stalled recipient cannot block status,
inbox processing or worker-release handling. Unreceipted messages remain in the
outbox and retry on a later ring/recovery call. Transport timeout anomalies stay
in the local anomaly ledger; they do not recursively send through the same
failed transport. Other anomalies are retained and delivered to the configured
frontier; only its receipt marks delivery, never resolution (`trailblazer ack`).

Acceptance uses disposable real VORTEX services, SQLite, the actual repair loop,
git and an Elixir check with scripted model replies. It proves one repair and
three-failure escalation without local inference. Run
`mix test test/trailblazer/vortex --include vortex_integration` explicitly.
Real Mirai fault emission, exclusive residency transfer and returned-fix
verification/execution remain subsequent gates. Qwen's Elixir competence needs
its own isolated Mirai regression; scripted replies do not establish it.

## Dedicated Trailblazer mode

With the operator keeping Mirai offline, trusted local policy may set
`"resource_mode": "dedicated"`. The adapter requires the system mirai-agent
unit to report inactive and the router to have no resident model except idle
Qwen. A no-fork flock/cat Port holds the shared local inference lock across
preparation, coding, checks and review. Qwen may load on the first model call.
Release requests router unload and confirms all router models unloaded before
releasing the lock. An unconfirmed release remains fenced; the next event or
explicit recovery rechecks it. This does not automatically resume Mirai.

Acquisition intent is durable before contacting the adapter. Interrupted grants
are closed for diagnosis and cleaned up, never silently replayed. Resource
failure restarts its dependent Runner and Bridge; lock-holder exit revokes the
resource owner. Resource IO runs outside the bridge, retaining responsive mail
and status. Supervised CLI `run` is refused in dedicated mode: use authenticated
VORTEX admission through the same gate. Other repositories and check commands
remain forbidden unless the operator's local policy explicitly allows them.
