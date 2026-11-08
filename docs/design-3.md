Trailblazer design, continued from design-2.md

## 13. Events, messages and pipelines

Added 2026-10-18 after the first live runs. *The operator decided:*
Trailblazer is event- and message-driven throughout. Time is never how
the work moves; it is only a backstop that catches what has gone wrong,
and a backstop that fires is a reason to look, sent to Claude and Codex.

### 13.1 Why

A design built on timing assumptions fails whenever something takes
longer than assumed, and on this machine everything sometimes does:
prompt reading ran at 8–11 tokens/s with 31 GB of swap in use, a
whole-repository graph read took over 15 s, and one reviewer thought for
13 minutes. Each fixed wait in phases 1 and 2 broke this way (E19, E19b,
E23): a call timed out while the work it waited for was still going, and
the timeout was taken for the answer. On the BEAM work is processes and
messages: a reply, a `:DOWN`, an event. Waiting for one of those is
always correct, however long it takes.

### 13.2 The rules

1. **No clock as control flow.** Nothing is retried, polled, debounced or
   given up on because a time passed. Work moves when a message arrives:
   a reply, an event, a monitor's `:DOWN`, a port's exit status.
2. **A wait is for a message, with a monitor.** Every request to another
   process monitors it, so its death is an answer at once. Callers inside
   the VM use `:infinity` call timeouts together with a monitor, or ask
   asynchronously and receive the reply as a message.
3. **Progress is reported as events,** never sampled on a timer: tokens
   as they stream, the model server's prompt progress, files parsed,
   edges written, vectors embedded.
4. **Work queues, not waits.** Where order matters there is a queue and a
   process that owns it (the task queue, the store writer, the embed
   queue). Where it does not, work fans out to a bounded pool and the
   results come back as messages.
5. **Back-pressure by demand.** A stage takes the next item when it is
   free (it asks for work), so a slow stage holds up its producer instead
   of growing a mailbox without bound.
6. **One backstop per external interaction.** Something outside the VM can
   stop answering while staying alive: a check command that loops, a model
   server wedged mid-stream, an HTTP peer that never replies. Each such
   interaction has exactly one backstop, preferably a measure of progress
   (tokens, bytes of output, edit rounds) and else a wall-clock limit set
   generously from measurements. A backstop is not a path the design
   expects to take.
7. **A backstop that fires is an anomaly** (§13.5): the work it guarded
   ends in a defined way (the attempt fails, the task fails, the file is
   marked unparsed), the anomaly is recorded with the system's load, and
   an investigation request goes to Claude and Codex.
8. **Tests synchronise on messages,** never on `Process.sleep`: a test
   waits for the event that says the thing happened (`assert_receive`
   with a subscription), so a slow machine makes a test slower, not
   wrong.

### 13.3 The event bus

A local publish/subscribe registry (Elixir's `Registry` with duplicate
keys; no new dependency), with topics:

| Topic | Published by | Carries |
|---|---|---|
| `{:repo, path}` | watcher, indexer, writer, embedder | files changed, sync started/done, nodes and edges written, vectors done |
| `{:case, id}` | CaseRecord | every case event as it is recorded, and the report |
| `:model` | Model | call started, prompt progress, milestones, call ended |
| `:embedder` | embed health | up / down, with the reason |
| `:anomaly` | Backstop | each anomaly (§13.5) |

The API streams a topic to a client (`/case` with `follow`: the CLI
prints each event as it comes and exits on the report), which removes the
CLI's polling and gives callers the live log for free.

### 13.4 The pipelines

**Indexing** (replaces the per-repository loop of §6.6):

```
request for repo R (search, where, uses, status, run)   ← freshness (§13.7)
  or a git-state event (one inotify instance; one watch per repo, its git dir)
  → indexer per repo: a set of dirty paths; syncs when free, and
    whatever arrives during a sync is the next batch (no debounce)
  → parse pool: N workers (Elixir parser in-process; tree-sitter Ports,
    a small pool, each a separate OS process)
  → resolver
  → store writer: the one writing connection, batched transactions
  → embed queue: global, by repository priority; runs only while
    EmbedGate grants it; asks the embed-health process, never retries on
    a timer
```

**Reads** go through their own SQLite connections (WAL allows readers
beside the writer), so a question or a trail never waits behind a write.
Case records have a database of their own (E23).

**Coding** (§7): the task queue (Runner) takes one task at a time,
because there is one model on one CPU. Within a task, the worktree and
the trail are prepared in parallel; attempts, checks and reviews are in
order. Model calls go through one owner of the model, which knows the
single slot is busy and holds embedding (EmbedGate) for the call.

Parallelism does not speed up the model: one slot on 6 threads. What
pays for a task is fewer prompt tokens (§6.5) and the model server's
prompt cache.

### 13.5 Anomalies and investigations

`Trailblazer.Backstop` arms the one backstop of an interaction and
cancels it when the interaction's own answer arrives. When a backstop
fires:

1. the guarded work ends in its defined way, recorded (case event or
   index status);
2. an anomaly record is written: what was awaited, from whom, for how
   long, the progress seen so far, and the load at that moment (load
   average, free memory and swap, whether the model or embedder was busy
   and for whom);
3. an investigation request goes over VORTEX to Claude and Codex, one per
   distinct anomaly (same kind and subject) until one of them
   acknowledges it, so a repeating fault is one request, not a flood.

The request is short and written for a model, like the report (§7.6):
what fired, the evidence, the load, and where to look (case id, repo,
journal time). Often the answer will be "the machine was loaded"; the
load is in the request so that is quick to see. Investigation requests
are the one exception to "Claude is not woken by Trailblazer" (§7.5),
by the operator's decision.

Backstops start from measured values with a wide margin: generous enough
that firing means something is wrong, not that the machine is busy.

### 13.6 What it replaces

| Was | Now |
|---|---|
| CLI polls `/case` every second | streamed case events |
| Loop heartbeat every 15 s | prompt progress and stream milestones (done, E22) |
| Indexer 1 s debounce | dirty set, sync when free |
| Indexer 30 s embed retry | embed-health events and EmbedGate grants |
| Indexer 15 s poll without a watcher | no poll: every request reconciles its repository first (§13.7); a repo without a watch is simply cold |
| One recursive watch over every indexed repository (cost grows with every directory indexed; ~/projects alone is 81,066 directories against a 65,536-watch limit) | freshness from git on every request; one watch per repository, on its git directory (§13.7) |
| Model 500 ms retry while the model loads | the router's loading answer is retried on a backstop, logged as progress |
| GenServer call timeouts (5 s, 30 s, 10 min) | monitors and `:infinity`, or asynchronous replies |
| Model first-token and total deadlines | token budget (`max_tokens`) plus one backstop |
| Check timeout | one backstop, and output progress logged |
| `Process.sleep` in tests | `assert_receive` on events |

### 13.7 Freshness from git; one watch per repository

Added 2026-10-18 late. *The operator ruled* that a design whose cost
grows with everything indexed is wrong: one inotify watch per directory
over every repository exceeds the kernel's per-user limit (65,536 here;
~/projects holds 81,066 directories, 2,805 after pruning, and it only
grows). On ext4 there is no cheap "what changed since" query, and the one
notifier that covers a whole filesystem in one mark (fanotify with
`FAN_MARK_FILESYSTEM`) needs `CAP_SYS_ADMIN`.

*The operator's answer: track git.* Git already knows what changed, at
a cost that follows the size of the change, not of the repository:

1. **The indexed state is a git state.** Each repository records the
   HEAD commit it last indexed. On a request, `git diff --name-status -z
   --no-renames <indexed>..HEAD` names exactly the files that commits,
   checkouts, pulls and resets changed.
2. **Working-tree edits come from `git status`.** `git status
   --porcelain=v2 -z --untracked-files=all` names modified, staged,
   deleted and untracked files against HEAD, using git's own index stat
   cache (which already handles racy timestamps, `cp -p` and the rest)
   and respecting `.gitignore`, the same rule as file listing. It runs
   with `GIT_OPTIONAL_LOCKS=0`, so it never takes `index.lock` and never
   gets in the way of the operator's or an agent's git command (measured:
   it writes nothing under `.git`).
3. **Every request reconciles first.** Before Trailblazer answers a
   search, where, uses, status or run for repository R, R's indexer runs
   1 and 2, makes the union its dirty set, syncs only those files, then
   answers. The request is the event. The caller waits for a message
   (`{:fresh, repo, generation}`), never a time; progress streams on
   `{:repo, path}`; one backstop guards it.
4. **Requests coalesce.** A request joins the next reconcile that starts
   after it arrived (a reconcile already running may have read the file
   before it changed, J19); every request waiting on that reconcile is
   answered by it.
5. **One watch per repository: its git directory.** Measured on a
   scratch repository: add, commit, checkout, branch and reset all
   rewrite `index` (and `HEAD` or `logs/HEAD` when HEAD moves), all
   directly in the git directory. One non-recursive inotify watch on it
   (for a linked worktree, its own `.git/worktrees/<name>`) tells the
   indexer that git state moved, and it reconciles at once. Unstaged
   edits and new untracked files touch nothing under `.git`; they are
   picked up by the next request (3), or, for a repository with a running
   case, by the loop itself, which knows the files it edits. ~/projects'
   81,066 directories become about one watch per repository.
6. **Ignored but indexed directories** (vendored code such as `deps/`,
   which the operator wants indexed though `.gitignore` excludes it)
   change when their lockfile changes (`mix.lock`, `bun.lock`,
   `package-lock.json`, `Cargo.lock`, `poetry.lock`); git sees the
   lockfile, and a lockfile change rescans that directory by stat.
7. **A directory that is not a git work tree** falls back to a stat
   reconcile on request (size, mtime_ns, ctime_ns, inode against the
   store) and gets no watch.
8. **Embedding stays lazy and separate.** Reconcile makes the graph
   current; vectors for changed definitions go to the embed queue, and a
   search answers from the vectors present, saying how many are pending.
   The crawl that embeds every project by recency is a work queue; a
   repository nobody asks about costs one watch and nothing else.

## 7.5 (addendum) Verifying a returned fix

When a frontier returns a fix (`{base, case, commit}`), the return is held in
`waiting_verification` until `Vortex.ReturnVerifier` gives a verdict. Three
gates run first, in order, and a rejected return never runs the check: the
return's base equals the base the case was opened on; the commit is not that
base and descends from it; every path the commit changes (deletions and both
sides of a rename included) is one of the case's files, when the case names
files. A return that passes runs the admitted check and artifact policy in a
detached worktree of the exact commit (`Trailblazer.Verification`). The verdict
moves the return from `waiting_verification` to `return_verified`,
`return_rejected` or `return_failed` (only from that state, so it never
changes), and a `report` naming the verdict, commit and summary goes to the
primary. A failed fix is reported, not retried, and a second return for the
case is refused. The bridge starts the verifier for each waiting return during
reconcile, so a return still waiting after a restart is verified again.
