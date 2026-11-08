# Trailblazer Phase 2b (events, messages and pipelines) Implementation Plan

**Goal:** no clock moves Trailblazer's work. Every wait is for a message (a reply, an event, a `:DOWN`, a port's exit), progress is published as events, work goes through queues and bounded pools with demand, and each external interaction has exactly one backstop whose firing is an anomaly: the guarded work ends in a defined way, the anomaly is recorded with the machine's load, and Claude and Codex get one investigation request over VORTEX. The coder's prompt is cut to what the task needs plus a head start. The operator decided this on 2026-10-18 after the first live runs (design §13).

**Spec:** `docs/design.md` §4, §6.5, §6.6, `docs/design-2.md` §7.8, `docs/design-3.md` §13. Register: class J (time and events) in the phase-1 plan's Task 1, written before any task starts.

**Who:** Claude and Codex in parallel, every task reviewed by the one who did not write it; reviews run beside the next task and never block it. Same protocol as phase 2 (own worktree, full suite, rebase, fast-forward main, one VORTEX note with SHA, tests and register ids). Only Claude restarts the deployed service. The deployed service and the model router stay frozen until B11 needs them (the operator paused them); unit tests do not need them.

## Order

```
B0 register class J ──> B1 event bus ──┬─> B2 backstops + anomalies ─┬─> B4 loop: prepare in parallel, backstops, head start
                                       ├─> B3 streamed case events   │
                                       ├─> B5 one watcher (E24) ─────┼─> B6 indexer: dirty set, embed health ─> B8 parse pool
                                       ├─> B7 store: writer + readers┘
                                       └─> B9 sweep: call timeouts, sleeps in tests (split)
B10 router prompt cache (measurement, any time)
B11 L9 rerun on sojourney (after B2-B4, B6, B7)
```

| Task | Author | Review | Depends on |
|---|---|---|---|
| B0 Register class J | Claude, then Codex adds | each other | none |
| B1 Event bus `Trailblazer.Events` | Claude | Codex | B0 |
| B2 `Backstop`, `Anomaly`, investigation requests | Claude | Codex | B1 |
| B3 Case events streamed to API and CLI | Claude | Codex | B1 |
| B4 Loop: parallel prepare, backstops, head start, prompt accounting | Claude | Codex | B2 |
| B5 One watcher for all repositories (E24) | Codex | Claude | B1 |
| B6 Indexer: dirty set, sync when free; embed health and gate | Codex | Claude | B1, B2, B5 |
| B7 Store: one writer process, reader connections | Codex | Claude | B1, B2 |
| B8 Parse pool (tree-sitter Ports, demand) | Codex | Claude | B6 |
| B9 Sweep: call timeouts to monitors, `Process.sleep` out of tests | split by file owner | each other | B1 |
| B10 Router prompt cache: `cache-ram`, `parallel`, measured | Codex | Claude | none |
| B11 L9 trials T1-T4 rerun, triage | both | each other | B2-B4, B6, B7, B12 |
| B12a Indexer: reconcile from git on request, `fresh/1`, stat fallback for non-git, lockfile rescans, no degraded poll (design §13.7, J19-J25) | Codex (folded into B6) | Claude | B6 |
| B12b Watcher: one non-recursive watch per repository on its git directory; drop recursive watches (J26) | Codex | Claude | B5 |
| B12c Callers: API and loop ask `fresh/1` before answering; status reports the indexed HEAD and pending working-tree changes; `Git` reader module (status/diff parsing, `GIT_OPTIONAL_LOCKS=0`) | Claude | Codex | interface below |

## Fixed interfaces

```elixir
# B1
Trailblazer.Events.subscribe(topic)            # :ok; the caller receives events
Trailblazer.Events.publish(topic, event)       # :ok; never blocks on subscribers
# a subscriber receives {:trailblazer_event, topic, event}
# topics: {:repo, path} | {:case, id} | :model | :embedder | :anomaly

# B2
ref = Trailblazer.Backstop.arm(kind, subject, {:ms, n}, evidence_fun)
Trailblazer.Backstop.disarm(ref)               # the interaction answered
# if it fires, the arming process receives {:backstop, ref, anomaly_id}
Trailblazer.Anomaly.report(kind, subject, evidence)   # {:ok, id}; for progress backstops
Trailblazer.Anomaly.list(open: true) / ack(id)        # CLI: trailblazer anomalies, trailblazer ack ID
# anomaly: %{id, kind, subject, evidence, load, at, acked}
# load: %{loadavg, mem_available_mb, swap_used_mb, model: :idle | {:busy, who}, embedder: ...}

# B3
POST /case {case, follow: true}   # chunked NDJSON: one line per case event, last line the report

# B12 (design §13.7): freshness from git; one watch per repository
Trailblazer.Indexer.fresh(repo)                # {:ok, %{generation, head, changed, removed}} | {:error, reason}
                                               # waits (:infinity + monitor) for the next reconcile that
                                               # starts after the call (J19); one backstop inside the indexer
# {:repo, path} events: %{event: :reconcile_started, generation}
#                       %{event: :reconcile_progress, generation, files, of}
#                       %{event: :fresh, generation, head, changed, removed}
Trailblazer.Git.head(repo)                     # {:ok, oid} | {:ok, :unborn} | {:error, :not_a_work_tree}
Trailblazer.Git.changed(repo, since_oid)       # {:ok, %{changed: [path], removed: [path]}} | {:error, :unknown_commit}
Trailblazer.Git.status(repo)                   # {:ok, %{changed: [path], removed: [path], untracked: [path]}}
Trailblazer.Git.git_dir(repo)                  # {:ok, abs_path}, a linked worktree's own git dir
# all with GIT_OPTIONAL_LOCKS=0, -z parsing, paths relative to the work tree (B12c, Claude)
```

Backstop limits live in `Config` (`backstop_<kind>_ms`), set from measurements with a wide margin; names, not numbers, appear in code.

## Global constraints

- No `Process.send_after`, `:timer`, `receive … after N`, `Process.sleep` or finite call timeout in `lib/` except inside `Trailblazer.Backstop`, model.ex's loading retry and EmbedHealth's retry while work is pending (each documented in the allowlist). There is no degraded poll: a repository without a watch is cold and reconciles on request (B12). A test (B9) greps for them so they do not creep back.
- Every cross-process request monitors its target. A call that must stay synchronous uses `:infinity` with the target monitored.
- Events are facts that already happened; publishing never waits for a subscriber, and a subscriber that dies does not affect the publisher.
- An investigation request goes to Claude and Codex once per open `{kind, subject}`: a repeat while one is open adds to its count, not a new message.
- Never on Trailblazer's own repository; the deployed service is restarted by Claude only.

## B0 Register class J (written now, before B1)

See the phase-1 plan's Task 1, class J. Each task below names the J entries it must test.

## B1 Event bus (Claude; review Codex)

`lib/trailblazer/events.ex` on a `Registry` (duplicate keys) started first in the application. Tests: two subscribers get one event each, in publish order (J1); a dead subscriber is dropped and the publisher is unaffected (J3); publishing with no subscribers is a no-op.

## B2 Backstops, anomalies, investigations (Claude; review Codex)

`lib/trailblazer/backstop.ex` (the only module allowed a timer besides B6's degraded poll), `lib/trailblazer/anomaly.ex` (table `anomaly` in `cases.db`), `lib/trailblazer/investigate.ex` (VORTEX send to Claude and Codex as owner `trailblazer`; the transport is a configurable command so tests stay hermetic). Load from `/proc/loadavg` and `/proc/meminfo` plus the last `:model` and `:embedder` events. Tests: J4, J5, J6, J9; disarm before firing sends nothing; a fired backstop publishes on `:anomaly` and sends one request; a repeat while open sends none; ack reopens.

## B3 Streamed case events (Claude; review Codex)

`CaseRecord` publishes each event after it is recorded (`{:case, id}`). The API's `/case` with `follow` subscribes first, then sends the record so far, then streams new events (J2: nothing lost between the two), ending with the report. The CLI's `run` (and `case --follow`) prints events to stderr as they come and the report to stdout; its 1 s poll goes. Tests: an event recorded between subscribe and replay is sent once; the stream ends on the report; a client that disconnects unsubscribes.

## B4 Loop (Claude; review Codex)

Workspace and trail prepared in parallel (`Task.async` both, monitored). The model's `max_ms`/first-token deadlines become one backstop per call (`backstop_model_ms`), with `max_tokens` the progress limit; the check's timeout becomes `backstop_check_ms`. The head start (design §6.5.2): the check command, and the module's test file as the pattern when the request asks for a test. Every case records prompt tokens by section and time to first token. Tests: J7, J8; a backstop that fires fails the attempt with the anomaly id in the record.

## B5 One watcher (Codex; review Claude)

As sent over VORTEX on 2026-10-18 (E24): one inotify instance for all repositories, events routed by longest root, restart with the new list on add/remove followed by each indexer's resync, a watcher that cannot start is an anomaly and shows in status. Tests: J10, two repositories on one watcher, adding a third keeps the first two live.

## B6 Indexer (Codex; review Claude)

The 1 s debounce goes: changed paths join a dirty set and the indexer syncs when it is free; what arrives during a sync is the next batch (J11). The 30 s embed retry goes: an embed-health process publishes `:embedder` up/down (it alone may probe, on a backstop, while down), and the embed queue runs when EmbedGate grants it and the embedder is up. The poll without a watcher stays as a degraded mode and reports an anomaly. Publishes `{:repo, path}` progress. Tests: J11, J12, the gate held while the model runs.

## B7 Store (Codex; review Claude)

One writer process owns the writing connection and takes batches from a queue; reads go through a small pool of read-only WAL connections, so a question never waits behind a write (E19, E23). The 10-minute statement and call timeouts become `:infinity` with monitors plus one backstop per transaction. Tests: a read answered while a long write runs; J13. Implemented: one writer and two read-only workers, independent demand queues, deferred read snapshots (J15), durable last-batch fingerprints (J16), caller monitors and cancellation rollback. `StoreIOTest` covers held reads/writes, read-only enforcement, backstop/caller cancellation, commit/ack crash recovery, replay after reopen and stale/parser invalidation.

## B8 Parse pool (Codex; review Claude)

N parse workers that ask for files (demand), tree-sitter as a pool of Ports (each its own OS process), the Elixir parser in-process. A Port that dies fails its file, not the batch. Tests: J14, a crash mid-batch.

## B9 Sweep (split; review each other)

Claude: `loop`, `model`, `api`, `cli`, `case_record`, `check` and their tests. Codex: `indexer`, `embed_gate`, `tree_sitter`, `runner`, `store` and their tests. Ends with the grep test of the global constraints.

## B10 Router prompt cache (Codex; review Claude)

Measure on the router (mirai-agent's `config/llama-router.ini`, Qwen section: `parallel = 1`, `cache-ram = 0`): attempt 2's time to first token with a reviewer call in between, with and without `cache-ram`, and the memory it costs (the machine runs 31 GB into swap). Recommendation to the operator if it changes Mirai's shared router.

## B11 L9 rerun (both)

T1-T4 as written in `docs/trials.md`, on the new build; time to first token and prompt tokens by section recorded; harness vs model triage; sojourney's checkout verified unchanged.
