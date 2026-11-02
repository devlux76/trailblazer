# Incremental edge resolution after a changed sync

Status: implemented (`lib/trailblazer/store/resolution.ex`, `lib/trailblazer/graph/inputs.ex`,
`priv/migrations/003_resolution.sql`; called from `Trailblazer.Store`). The text
below is the proposal as reviewed.
Source baseline: Trailblazer main `1cd1a9b`, inspected read-only on October 22, 2026.
The reported 26,819-node llama.cpp graph and 20–30 second changed-sync cost are
handoff measurements, not new measurements made for this proposal.

## Recommendation

Keep J31's no-change fast path. For an actual changed batch, invalidate by the
**resolver inputs that were read**, including unsuccessful lookups, and replace
outgoing edges for the affected source definitions. Do not resolve only the
changed files, follow only existing incoming edges, or rebuild a whole snapshot
and then filter its edges: each either misses changes or retains the dominant
repository-wide cost.

The correctness contract is:

> After a successful sync, the semantic edge set equals a full `Resolve.edges/1`
> on exactly the same stored nodes and refs, including `line`, `kind`, candidate
> truncation and `uncertain`. No unrelated source definition is re-embedded just
> because its edge resolution was invalidated.

The invalidation set below is exactly specified and conservative, not claimed
to be the smallest set of references whose final output changes. Coarse lookup
buckets can invalidate extra sources; missing a necessary source is forbidden.
Thresholds, table names and APIs below are proposed implementation choices.

## What the current code actually depends on

`lib/trailblazer/graph/resolve.ex:6` builds all indexes from
`Store.graph_snapshot/1`, resolves every ref, deduplicates candidates, sorts by
`{path, qualified, id}`, takes eight, and deduplicates the resulting edges.
Ambiguity is computed **before** the eight-candidate cap. An unresolved ref stays
stored even when it produces no edge.

The significant branches are:

- `contains`: exact qualified name, restricted to the source's path.
- Elixir: exact qualified target with `/arity` appended when arity is an integer;
  only Elixir definitions qualify. No new import or language semantics should be
  invented by this optimization.
- Generic unqualified refs: use import bindings first; otherwise prefer local
  qualified matches, then a language-family name bucket (`c` and `cpp` share one).
- `spec#member`: resolve the module and inspect both its definitions and its
  forwarding import bindings, recursively. The cycle guard is `{file, name}`.
  `split_target/1` splits at the final `#`, not necessarily the first.
- Module selection: ordered existence probes, including missing higher-priority
  candidates. Python tries sibling/root `.py` and `__init__.py` variants; relative
  JS-family specs try the original path, extensions and index variants in the
  current order. External or escaping specs do not fall back to a homonym.
- C/C++ includes: local exact path, root exact path, then component-suffix matches.
- `implements`: exact qualified **doc-section** matches first, otherwise complete
  path-component suffix matches for that section. Adding an exact match can
  remove all previously selected suffix edges.
- Import-binding presence also affects the final uncertainty calculation
  (`resolve.ex:26`); recording dependencies only inside `candidates/3` is not
  sufficient.

Two easily missed details of `index/1` matter. `paths` is the union of node paths
**and ref paths**, not `Store.files/1`. `file_suffixes` comes from node paths only.
A ref-only path may win an exact probe without providing a module definition,
thereby suppressing a later candidate or suffix fallback. `refs_by_path` is built
but not consumed by the current resolver; it needs no dependency token.

`indexer.ex:499` already selects/parses files incrementally but calls full resolve
when any parsed/deleted/stale count changes or `edges_current` is false. A parse
failure preserves last-good definitions via `Store.mark_stale/2`.
`store.ex:205` replaces a file's refs with new row IDs and retains node IDs by key;
`delete_file/2` and `drop_missing_nodes/4` remove edges touching retired nodes.
`put_edges/2` replaces the entire repository's edge table. These are the storage
boundaries to extend, not bypass.

## Dependency vocabulary and the exact invalidation rule

A lookup token is typed and repository-scoped. It identifies a whole lookup
answer, including the empty answer. Resolution records each token under the
**originating source key**, including tokens visited while following re-exports.

| Token | Answer being watched |
| --- | --- |
| `source(key)` | `by_key[key]`, especially source ID, path and language; absence is meaningful |
| `qualified(q)` | The entire `by_qualified[q]` bucket, before branch-specific filtering |
| `name(family, name)` | The entire `by_name[{family, name}]` bucket |
| `nodes(path)` | The entire `by_path[path]` bucket, including default-export eligibility |
| `imports(path, member)` | All `references` refs containing `#`, grouped by the final split member, exactly as `index/1` groups them; absence is meaningful |
| `exists(path)` | Membership in the union of node paths and ref paths |
| `doc_suffix(suffix_with_section)` | All doc-section candidates for that exact component suffix and section |
| `file_suffix(suffix)` | Distinct node-bearing paths with that exact component suffix |

Use the same normalization, suffix derivation, language-family and splitting
rules as the full resolver. A raw SQL substring/`LIKE '%name'` approximation is
not equivalent; names containing `%`, `_`, `#` or path separators must stay literal.

The resolver-relevant node projection includes `id`, `key`, `lang`, `kind`,
`name`, `qualified`, `path`, and whether `signature` contains `export default`.
The last field is needed even if the key and name did not change. Resolution does
not read a target's body hash, vector hash, stale flag or source extent. Those
fields alone must not invalidate readers of name/member buckets. Source refs'
`kind`, `target`, `arity`, `line`, `ambiguous` and `from_key` remain resolution
inputs. For an imports bucket, forwarding uses `path` and `target`; row IDs and
reference line numbers are not its semantic identity. Canonicalize lookup answers
without discarding any distinction used by the resolver.

For a successful mutation batch, define:

- `F`: paths actually replaced/deleted in the store, not every git-status entry.
- `L`: old and new source keys named by refs in `F`, plus old/new node keys in `F`.
  Capture old keys before deleting their refs or nodes. Include keys whose new ref
  set is empty, so removed calls cannot leave surviving outgoing edges behind.
- `K`: lookup tokens whose answer changed in any committed file mutation in the
  batch. Consider old **and** new keys for renamed definitions, language changes,
  path moves, import changes and doc-section changes. A transient change that is
  undone later in the batch may cause extra invalidation; that is safe.
- `R(K)`: source keys registered as readers of any token in `K`, even if their
  previous output was zero edges or the affected candidate was outside the cap.
- `T`: source keys of old incoming edges to retired nodes, captured before
  `delete_edges_touching/2`. This is an inexpensive safety inclusion using the
  existing target-edge index; do not make it the only dependency mechanism.

Then the affected source set is:

`S = L ∪ R(K) ∪ T ∪ already_pending_sources`

The ref set to evaluate is exactly `I_refs = {r in post_sync_refs | r.from_key in S}`.
Resolve **all current refs owned by each key in S**, not just the individual ref
that first invalidated it. For a missing non-null `from_key`, retain a negative
`source(key)` dependency while refs still name it; a later definition with that
key must wake those unresolved refs. A nil source cannot produce an edge, but its
ref still contributes to imports and path existence indexes where applicable.

Nodes with stable keys keep their IDs; removed IDs remain retired. Changed or
removed source keys with no current refs resolve to an empty edge set. Replacing
an entire source's outgoing set removes obsolete `calls`, `contains`, `imports`
and `implements` edges together and avoids adding `ref_id` provenance to `edge`.
Refs cannot be a durable output identity today: `replace_file/3` recreates them.

### Why this catches the nonlocal cases

- A new homonym changes `name(family,n)` or `qualified(q)`. Existing unique edges
  may become uncertain; removal can make them certain again. Record the complete
  bucket, not just the first eight outputs, so the ninth candidate can enter.
- A new local definition supersedes a global fallback through the previously
  empty local qualified lookup. New import bindings supersede both through the
  previously empty imports lookup.
- Adding a missing earlier module path changes its `exists` token, even when
  a different module was previously selected. Deleting the selected path changes
  its token and makes the resolver inspect later choices.
- A change to a barrel's forwarding refs changes its imports bucket. Every
  original consumer that traversed that barrel is already its reader. The same
  holds for longer chains and cycles. A previously missing member has negative
  imports/node dependencies that catch its later introduction.
- Adding a second suffix match, an exact doc path, a root C include or a default
  export changes a lookup answer even if no incoming edge names the new node.

Record actual probes, including misses, at the lookup boundary. It is safe to
record all candidate path probes instead of only the prefix through the selected
winner; that is a conservative implementation option, not a semantic change.
Use a closed lookup API: an unregistered token kind requests full fallback, and
resolver semantic changes require a version bump. A cached bucket lookup must
still record a dependency for every consuming source.
If recursive member results are memoized, cache their transitive read sets too;
otherwise one consumer's cache hit silently loses another's invalidation path.

No repeated fixed-point resolution of **edges** is required: the current resolver
reads only nodes and parsed refs, never resolved edges. Following transitive
module lookups while recording the root source's dependencies supplies the
necessary importer closure. An index of only already-resolved import edges does
not: it omits unresolved bindings, ambiguity and paths that lost precedence.

Proof obligation: an unaffected source has unchanged own refs/source data and no
changed answer among its old recorded lookups. Therefore it executes the same
branches with the same lookup answers and produces the same sorted/capped edges
and uncertainty. If a branch would change, its first differing lookup was an old
recorded dependency and would have put that source in `R(K)`. This argument covers
multiple simultaneous file changes, not just one-file edits.

## Store indexes and publication

Keep these persistent and repo-scoped so restarting a service does not require
loading 26,819 nodes merely to discover that no work is needed.

1. Existing `(repo_id,key)` uniqueness, qualified/name/path node indexes, ref-path
   index and edge-from/edge-to indexes cover several lookups. Add a ref index on
   `(repo_id,from_key)` to fetch complete affected source groups cheaply.
2. Materialize import bindings by `(repo_id,path,member)` with the original
   `{path,target}` payload, deriving member with `split_target/1` semantics.
   Index that key. Maintain it from raw refs, including refs without a source.
3. Maintain node/ref path presence counts separately. `exists(path)` is their
   boolean union; C suffix membership uses node presence only. Materialize
   component file suffixes and doc-section suffixes with indexes beginning
   `(repo_id,suffix)`. These are lookup tables, not extra filesystem watches.
4. Maintain a reverse dependency table
   `(repo_id,owner_key,token_kind,token_key)` with uniqueness in that order and an
   index `(repo_id,token_kind,token_key,owner_key)`. Typed tuple keys need a stable
   encoding. All references owned by a source share its union read set.
5. Keep a source coverage record even for a successfully resolved **empty**
   result, a durable pending-source set, and a repository resolution revision and
   resolver/index format version. "No edges" must not mean "never resolved".
   Unaffected sources retain their older valid coverage revisions; do not rewrite
   every coverage row on each sync. Persist the baseline-complete/version marker
   rather than scanning all sources to re-prove coverage on each request.

Update changed lookup tables, derive `K`, enqueue `L/R(K)/T`, and advance the
revision in the same transaction as each file replacement/deletion. Capture old
identities and incoming owners first. Do not delete dependency information and
hope the indexer remembers the delta after a crash. A vector-cache or vector-hash
write must not advance the resolution revision or repeatedly invalidate graph
publication. Metadata-only stale marking leaves last-good resolution inputs and
edges intact; when parsing recovers, apply the real old/new delta.

Provide a selected-source resolve operation using **one coherent read snapshot**
and indexed lookup access. Repeated independent public Store reads can cross
revisions; a single read-pool operation/transaction must pin all lookups, with
per-operation bucket caching and a captured revision. Do not hold the writer
while doing the resolution. Do not call `Store.graph_snapshot/1` or rebuild all
of `index/1` on the incremental path. Query the source refs and the buckets their
resolution actually reaches. A single Store read operation can run a lookup
facade over its own connection; it must not recursively call the public Store API.

Publish with a proposed `replace_resolved_sources` operation that atomically:

- compares the captured revision and resolver version with current state;
- validates edge endpoints are in this repo and each `from_id` is in the selected
  scope, using indexed checks on the selected IDs rather than a full repo-ID scan;
- deletes/replaces only those sources' outgoing edges, including empty results;
- replaces their dependency/coverage records and consumes their pending markers;
- invalidates the old repository-wide edge-batch digest, and records an idempotent
  batch identity including revision and source scope for commit/ack-gap retries.

Only mark the revision resolved after its complete pending set is empty and the
sync's file-write pass succeeded. A concurrent mutation makes publication fail
its revision check; reschedule against the accumulated durable pending set, never
clear it with an old answer. Failed saves publish neither new edges nor new read
sets. Deleted sources with remaining dangling raw refs keep the negative source
watch; a source with no remaining refs can retire its coverage/dependencies after
its old edges have been removed. Preserve current no-dangling-node guarantees.

The present indexer serializes syncs per repository, but Store APIs and recovery
are independent mutation boundaries; correctness must not rely only on that
in-memory serialization or on `edges_current`. A crash after file writes but
before edge publication must be recoverable from the durable ledger, even if git
now reports no further changes. Request waiters are answered only after the
matching reconcile finishes, preserving J19. No source-text reads or embedding
calls are needed to re-resolve unchanged importers from their stored refs.

## Git gate and full fallback

The event is a git-proven delta: committed diff plus staged/unstaged/deleted/
untracked status, compared with stored file hashes. HEAD equality alone proves
nothing about worktree edits; repeated git-dirty paths with unchanged stored
hashes must still take J31's no-write fast path. Rename remains delete plus add.
Git, watcher and loop path hints coalesce into that reconcile; they are not proof
that a graph or embedding stage has work to do.

Keep embedding separate: enqueue only new/changed definition text (and existing
previously-proven pending work), never every invalidated source/importer. No
model is required by this design.

Use full resolution of the **post-sync stored snapshot**, with new dependency
coverage, when:

- this is the first changed batch without a complete compatible dependency/index
  baseline, including upgrade/hot-load into an old store;
- an earlier interrupted sync lacks a complete reconstructable mutation ledger;
- resolver/parser/index rules changed and the persisted coverage version is not
  compatible, or an unsupported lookup appears that cannot be tracked;
- a lookup table/coverage invariant is broken, or revision-safe publication cannot
  be established;
- a git-proven lockfile/vendor reconciliation or another broad actual mutation
  affects much of the graph; or the accumulated affected workload is already
  comparable to a full resolve.

For workload fallback, use affected-source/ref counts from indexed metadata, not
a full snapshot just to choose the mode. A private starting policy of one quarter
of source groups is a tuning proposal, not a measured crossover or public option;
validate it against bucket sizes and real timings before fixing the threshold.
Large imports/name buckets may make an incremental lookup expensive even with
few sources, so include projected lookup volume in that decision.

Full fallback changes the resolution strategy, not the filesystem change scope:
missing dependency metadata alone does not justify reparsing or embedding the
repository. If existing edges are known current and git proves no new mutations,
return J31's no-change result; build missing incremental metadata lazily on the
next proven changed batch (or explicit maintenance), rather than undoing the
210 ms fix. A durable dirty revision is evidence of previously-proven work and
may be repaired without a new git diff. Never label an unknown/incomplete graph
fresh just to keep this fast path.

An initial repository baseline requires a git inventory. Git errors must not be
silently reinterpreted as permission to scan/embed everything under this new fast
path. Report freshness failure and retain the previous graph unless an explicit
existing full-reconcile/recovery policy authorizes the fallback. Existing
non-git compatibility is a separate policy; this proposal does not add periodic
scanning, new watches, model work or a replacement for git. A lockfile's git
change remains the explicit cause for an authorized ignored-vendor reconciliation.

## Equivalence and performance acceptance

Use the current full resolver as the reference, with its existing tests intact.
On a scratch store, start from a fully resolved graph with coverage, apply a
batch, publish the incremental result, and compare it with `Resolve.edges/1` on
that **same final snapshot**. Normalize to a set of
`{from_id,to_id,kind,line,uncertain}`; edge-table row IDs/insertion order are not
semantic. When comparing separate stores, normalize node IDs to repo-scoped
node keys first. Do not omit uncertainty, nil lines or empty outputs.

Generate small seeded mutation sequences over actual Store/parser data and
supported synthetic raw refs: add/edit/delete/re-add/move files; add/remove/
rename definitions; change imports/exports, language, arity, line and ambiguity;
and occasionally apply several edits before resolving. Assert equality after
every successful batch, not just at the end, and retain/shrink failing seeds.
Include actual git scratch-repository sequences for HEAD moves, dirty paths and
vendor triggers. No new property-test dependency is required: seeded ExUnit
sequence generation can establish the first harness.

Required adversarial examples:

- Unique to ambiguous and back; 8/9/10 candidates with insert/delete changing
  the sorted cap; same names across language families and other repositories.
- A ref that previously had no candidates becomes resolvable; a missing source
  key becomes present; a source loses its final ref while its node ID survives.
- New local binding/import hiding a global fallback; import alias changes;
  missing members added to a module; default-export eligibility changing with
  the same node key; unrelated exported members exercising coarse invalidation.
- JS extension and index precedence; Python sibling versus root and relative
  package precedence; external/escaping specs; paths containing `#`.
- Single/multi-hop barrels, cycles, changing a forwarding ref without changing
  definition names, and the same memoized lookup used by two different sources.
- C local/root/suffix precedence, duplicate suffixes, ref-only exact paths versus
  node-only suffix membership; doc exact/suffix/ambiguous matches, section removal
  and full path-component boundaries (`design.md` must not match `mydesign.md`).
- Parse failure retaining last-good nodes/edges, followed by recovery; deletion
  that exposes another candidate after incoming edges were removed by the store.
- Batch reorder/undo, source deletion plus target addition, store/indexer restart
  between file writes and publication, missing/versioned dependency tables,
  injected save failure, lost commit acknowledgment and concurrent revision
  change. Unaffected edge rows must survive; pending work must never disappear.

Add trace-completeness checks against the baseline snapshot: mutate a bucket
outside a source's read set and assert its output is unchanged; mutations with
changed outputs must put its source in `S`. Run the same sequence through both
incremental and forced-full strategies to compare refs, nodes, stale flags and
vector-pending eligibility as well as edges. Existing deterministic resolution
fixtures guard shared resolver semantics even if full/incremental later use a
common lookup kernel; avoid making both oracle and selector share the same
invalidation algorithm.

For complexity acceptance, instrument scratch-store reads and selected-source
counts, not only wall time. A one-file body/ref edit in a large graph must not call
`graph_snapshot/1`, enumerate all refs/IDs, delete all repo edges, or enqueue
embeddings for unchanged importers. A proven no-op must perform no parse,
resolution, graph write or new embedding enqueue. Demonstrate separately a
controlled broad change taking the full fallback, plus output equality. Record
cold/warm timings, selected source/ref/bucket counts and fallback reason. Do not
promise a latency from this design alone or benchmark live indexing under load.

## Suggested delivery boundary

First implement durable source-scoped edge replacement and tracked full-resolve
coverage, then the incremental selector/indexed lookup path behind internal
fallback. Require differential coverage before enabling the fast path. Keep the
full resolver available as an oracle and recovery path; do not bundle new
language resolution, parser behavior or embedding scheduling into this change.
Claude reviews and commits this proposal before any implementation assignment.
