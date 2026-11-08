# Trailblazer: design

Written 2026-10-17 by Claude, from a design conversation with the
operator. It replaces an earlier "coder" draft, no longer in the repository,
whose parts are reused here (§9). Where this
document says *the operator decided*, that is the operator's call;
where it says *builder's call* or *Claude's call*, it is a default that
can be changed without asking.

Current implementation notes (2026-11-02): this remains a specification,
including requirements not implemented yet. The dated plans are historical;
the following gaps must not be read as completed features:

| Requirement | Current implementation and remaining work |
|---|---|
| Verify a frontier's returned fix (§7.5) | VORTEX stores the return as `waiting_verification`; ancestry, scope, trusted checks and fresh review are not wired. See bug:a3339f5. |
| Integrate and clean a resource-gated task (§7.7) | `Loop.Coordinator` implements integration/archive/cleanup and the HTTP API accepts an explicit `primary`. The current Planner/VORTEX task protocol does not admit `primary`, so those cases stop at a candidate; live gated acceptance remains open in bug:1beebca. There is no age-based prune. |
| Repair a real harness incident (§11) | The incident-emitter and returned-fix end-to-end acceptance remain required, not demonstrated by local coding trials (bug:a3339f5). |
| Event-only observation (§13) | The local bounded-launch cleanup observer currently reads case status every five seconds. It makes no model calls or retries; this is a known exception to reconcile, not an event-driven implementation. |
| Operate running services (§12) | Still deferred; the coding worker has no general restart/deployment authority. |

## 1. What it is, and why

Trailblazer is a local coding tool **for AIs, not for people**, in the
way VORTEX is a collaboration tool for AIs.

Agent models such as LFM2.5-24B, Mirai's conscious mind, are good
agents and poor coders. Until now coding has been delegated over
VORTEX to Claude, Codex and OpenCode (MiniMax M3.1 Flash). That works, and it
is expensive: it spends paid usage, delegates run out of usage close to
the end of a task, and intent gets lost between the brief and the
delegate. The result is design mistakes that are found in review and
fixed inside multi-million-token Claude sessions, where every token
costs the most.

Trailblazer puts the operator-selected local code model (§7.2) in a harness
built for coding. It is not Mirai's harness: a code model placed inside
her two-minds runtime would be confused by it. Trailblazer uses her
**body** (the model router, the embedder, Qdrant, VORTEX) and none of
her **brain**.

The name says what it does. A trailblazer marks the trail so that
others can follow it safely. Its core, a port of ranger to Elixir,
already knows the lay of the land: before the code model asks where
something is, what uses it or what design it follows, the answer is in
front of it.

The name is the operator's choice. Salesforce uses TRAILBLAZER heavily,
and the operator expects to get a waiver before release.

## 2. Who calls it

- **Primary user:** Mirai. A fault in her harness must be able to create a
  Trailblazer case for triage and bounded repair. After three failed local
  attempts, the case goes to an available recognized frontier collaborator
  with its evidence and continuation state. Once that path works, Mirai can
  use it to request tools and features directly.
- **Supporting callers:** Claude, Codex and OpenCode, both for direct work
  and for taking over escalated cases.
- **Eventually:** other people's agents; the operator intends to market
  it.

Callers are models. The report is written for a model to read (§7.6),
and the caller does not watch the run.

## 3. Goals, non-goals, anti-goals

**Goals**
1. Fix what a local model can fix, verified, and commit it on a branch,
   without spending paid tokens.
2. When it cannot fix something, hand a stronger model a dossier good
   enough that the stronger model spends its tokens on the fix, not on
   finding its way around.
3. Keep intent from getting lost: the design behind the code travels
   with every task automatically (§6.4, §7.4).
4. Answer "where is this declared", "what uses this" and "what does
   changing this affect" from a graph, without a model.
5. Record every case completely, so the local model can later be
   trained on its own mistakes (§8).

**Non-goals**
- Being a human-facing coding assistant: no chat UI, no TUI.
- Mirai's minds, memory or experience. Trailblazer has none of them.
- Training the model. v1 only records the data (§8).
- Acting on running services (restarts, config changes). Deferred; see
  §12.

**Anti-goals: this fails even if it works when**
- it commits code that passes the check but breaks the design;
- it spends more of the caller's tokens than doing the work directly
  would have (long reports, a babysitting loop, vague escalations);
- it keeps trying a fix it cannot make instead of escalating.

## 4. Constraints

- **Hardware.** The coding preset is CPU-only with 6 threads. Earlier
  Qwen/MTP measurements (about 24 GB loaded, 8–11 prompt tokens/s under
  swap pressure) describe that historical deployment, not Spark's current
  memory use or throughput. Every token in the prompt still has to earn
  its place (§6.5); measure the active deployment rather than inferring
  capacity or time from those old runs.
- **No timing assumptions** (the operator decided, §13). How long
  anything takes depends on the machine's load; work moves by messages,
  and time is only a backstop.
- **Embedding is slow:** EmbeddingGemma 2 manages about 0.4 code chunks
  a second here. The first full index of a repo takes hours, so
  re-embedding must be incremental.
- **Resource coordination.** Standalone core retrieval has no global
  inference-lock requirement. Dedicated coding mode is the explicit
  exception: `Vortex.Resource` holds the shared kernel flock while its
  inference lease is granted, requires the other runtime offline, and
  verifies router unload before releasing ownership. This serializes
  cooperating inference clients, not arbitrary processes on the host.
- **Toolchain:** Erlang/OTP and Elixir as mirai-agent pins them;
  dependencies at latest while developing, pinned at release.
- **Licence:** the Aider-derived parts are Apache-2.0 and carry the
  attribution in `NOTICE` at the repository root.

## 5. The path of one task

| # | Stage | Done by | What happens |
|---|---|---|---|
| 1 | Intake | caller | Request, repo, optionally files, design sections and a check command (§7.1). |
| 2 | Workspace | Trailblazer | A worktree and branch for the task (§7.7). |
| 3 | Trail | core | Entry points by vector search, then a graph walk; the trail is packed within a budget (§6.5). |
| 4 | Attempt | code model | Edits as SEARCH/REPLACE blocks; the core re-indexes what changed. |
| 5 | Check | the project's check command | Format, compile, tests. |
| 6 | Review | code model, against the design sections | Does the diff do what was asked, only that, as the design says? |
| 7 | Retry or escalate | Trailblazer | Stages 4–6 fail: try again, at most 3 attempts. After the third, escalate with a dossier (§7.5). |
| 8 | Commit | Trailblazer | Only after check and review both pass. |
| 9 | Report | Trailblazer | To the caller (§7.6). The case is recorded (§8). |

## 6. The core

The core is ranger, ported to Elixir, kept running, and given a graph.
Today's ranger (`~/.claude/skills/ranger/`, about 800 lines of Python)
indexes 40-line chunks and has a regex graph of imports and top-level
names for JS and Python. The core replaces both.

### 6.1 Parsing

- **Elixir** with Elixir's own parser (`Code.string_to_quoted` with
  columns and token metadata). It is exact, and Elixir is the language
  of most of the work.
- **Every other language** with tree-sitter, run as an external OS
  process behind an Erlang Port, never as a NIF, so a parser crash
  costs that process and not the VM. The operator agreed to
  tree-sitter on that condition.
- **v1 languages (Claude's call):** Elixir, TypeScript/JavaScript
  (VORTEX) and Python (ranger, tools). The other grammars come when a
  repo needs them.

### 6.2 The graph

Nodes are **definitions**: modules, functions (by name and arity),
types, test cases, and **sections of design documents**. Each has a
stable id derived from its repo, kind and qualified name (not its line
number, so a move within a file keeps the id).

Edges (builder's call on the exact set; these are the minimum):

- `contains`: module → function, document → section
- `calls` / `references`: function → function or module
- `imports` / `aliases` / `uses`: module → module
- `tests`: test case → what it exercises
- `implements`: code → the design section it cites (§6.4)

**Name resolution** decides which definition a call means: aliases,
imports, `use` macros and module attributes in Elixir; imports and
re-exports in TS and Python. It is where the real work of the graph
lies. An edge the resolver cannot settle (a dynamic call, `apply/3`, a
computed import) is kept and marked *uncertain*, never silently
dropped.

The graph lives in the core's memory (ETS or `:digraph`, builder's
call) and is saved to SQLite so a restart does not re-parse
everything.

### 6.3 Vectors

Qdrant holds **one point per definition**, not the raw tree and not
line windows. The point id is the graph node's id, so a vector hit is a
graph node with no lookup in between. The vector embeds the
definition's text under a short header (its module, signature, and the
names it calls). The payload holds path, line range, kind, language,
name and a content hash. Only a definition whose hash changed is
re-embedded.

The core keeps its own collections, separate from today's ranger
collections, so the ranger skill keeps working until the core replaces
it.

### 6.4 Design documents are part of the land

Design documents are indexed like code: each section is a node and a
point. mirai-agent's source already cites the design in its comments
(for example `docs/07-conversations.md §7.6` in `Vortex.Client`). Each
citation becomes an `implements` edge. A citation that points at a
section which no longer exists is reported as **stale**;
`docs/12-status.md` counts 98 files that cite the old documents.

This is how the design travels with a task: the trail of any code
includes the sections it implements, without the caller restating them.

### 6.5 The trail

For a request:

1. **Seeds.** Files and names given by the caller; definitions named in
   an error or stack trace; then the nearest definitions by vector
   search.
2. **Walk.** Personalized PageRank from the seeds over the graph, with
   each step also scored by the neighbour's similarity to the request,
   so that paths drifting away from the request are cut. Uncertain edges
   count for less.
3. **Pack.** The highest-ranked definitions in full, the next ones as
   signatures, the design sections they implement, all within a token
   budget.

The default budgets (Claude's call, to be tuned against measurements):
system prompt at most 900 tokens, as in the draft; trail at most 4,000
tokens. Named files contribute a path/line-count manifest and seed the
trail, not an additional full-file copy (the revision below supersedes
the original files-in-full plan).

**The coder's prompt is as short as it can be, plus a head start**
(the operator's aim; Claude's call on the means, revised 2026-10-18
after T1 of L9, whose 6,500-token prompt was 72% trail, mostly noise):

1. *Files named are never sent whole* (operator, 2026-10-25, replacing
   D21's files-in-full). They seed the trail, which packs their relevant
   chunks with what they touch (callers, callees, the design they
   implement) within the 4,000-token trail budget; under Files the model
   sees only each named file's path and line count, and reads anything
   else it needs with `read`/`search`. Chunks are embedded so that no
   prompt has to carry a whole file.
2. *The head start* is what the model would otherwise spend a tool round
   or an attempt finding out, and only that: the check command it must
   pass and, when the request asks for a test, the project's test file
   for that module (or the nearest one) as the pattern to follow;
   the design rules that apply. No general instructions it does not
   need.
3. *Stable before variable.* Each attempt's prompt keeps the previous
   one's text as an unchanged prefix and appends what failed, so the
   model server's prompt cache can spare a retry the re-read. With one
   slot the reviewer can displace the coder's active prefix. The current
   serving preset uses `parallel = 1` and `cache-ram = 2048`; cache reuse
   and its memory cost are measurements, not a correctness guarantee (§13.4).
4. *Measured, not guessed:* every case records its prompt's tokens by
   section, and the time to first token, so budgets are tuned against
   the record (§10).

### 6.6 Kept current

The core is a long-running OTP application. It watches the repos it is
told about and re-parses and re-embeds what changed, as a pipeline of
processes passing messages (§13.4): file events in, a parse pool, one
store writer, one embed queue. Embedding and the code model share the
same 6 CPU threads, so embedding is held while the code model is
generating (EmbedGate, Claude's call). Before a trail is built, the
files it uses are brought up to date, so the trail always reflects the
working tree.

A repo is added with an explicit command (`trailblazer watch <repo>`)
or by its first task. Parsing a repo takes seconds and embedding it
takes hours, so a repo that is not fully embedded is still usable: the
graph and exact search work at once, and vector seeds join as
embedding catches up (Claude's call).

### 6.7 Questions anyone can ask

The core answers without a model:

- `where_declared(name or position)`
- `who_uses(definition)`
- `impact_of(definition)`: walks the reverse edges outward
- `read_range(path, lines)`
- `search(text)`: semantic search and exact search together
- `trail(request)`: the packed context of §6.5

The code model reaches these as tools (§7.3). Claude and Codex can
reach them directly too, which would make the core the replacement for
the ranger skill. Claude's guess at a good second use; the surface
(CLI, MCP or both) is the builder's call.

Continued in design-2.md: §7–§12; §13 is in design-3.md.
