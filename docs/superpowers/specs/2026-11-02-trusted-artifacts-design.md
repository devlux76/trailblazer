# Trusted artifact preparation before candidate verification

Status: helper independently reviewed; admission, execution, Companion and
Coordinator wiring implemented on codex/trusted-artifacts, awaiting peer review
and deployment/trial evidence. Issue: trailblazer:0981773.

Observed: the F9 candidate passed checks, but a subsequent `v6:build` changed
shipped bundles for already-reviewed F30/F7/F25 fixes. A non-mutating check is
correctly forbidden from blessing a tree different from the one it checked.
The worker needs an explicit generation stage, not a weaker verification rule.

## Trusted input

Add optional `artifacts` metadata to a locally configured VORTEX peer policy,
keyed by canonical repository and an already-admitted exact check string:

```json
{"artifacts": {"/absolute/repo": {"exact admitted check": {
  "prepare": "bun run v6:build",
  "paths": ["v6/plugins/codex/dist/server.js"],
  "definitions": ["package.json", "v6/build.ts"]
}}}}
```

The real deployment lists every intended output explicitly. No globs, absolute
output paths, traversal, `.git`, dependency trees or symlink destinations.
Reject metadata for a repository/check not admitted by that same peer policy.
Settings are frozen at boot like the rest of the policy. The protocol continues
to reject peer-supplied artifact commands/metadata; admission resolves the local
policy into internal task data and records its exact value/hash with the case.
No matching policy preserves today's behavior. HTTP/direct callers do not gain
an arbitrary preparation command through request fields.

## Execution and evidence

1. After all coder edits apply, capture repository changes, including untracked
   paths. Run the trusted preparation command through the existing Check runner
   (bounded output, process group and backstop), before capturing the check tree.
2. Compare before/after changes. Preparation may alter only declared output paths;
   unrelated source changes, undeclared new/deleted paths, symlinks and submodule
   changes stop the case with evidence. `files` remains a context hint, not a
   claim that the current edit engine enforces a source-path permission list.
   The guard hashes owned files and modes, including ignored nondependency
   files; provisioned dependency/build caches are excluded but tracked files
   there are still protected. HEAD/index changes are refused. Repositories
   with submodules are unsupported in the first implementation and are refused
   before running preparation.
   All provisioned/reset-preserved trees (`deps`, `node_modules`, `_build`,
   `target`) are forbidden output/definition destinations.
   Cache exclusions are root-only: nested dependency/cache writes are guarded
   and fail closed. Policy authors must avoid undeclared cache writes, including
   gitignored caches; this stage is not a package installer.
   A real directory that is an ancestor of a declared output may remain a real
   directory while its mode loses permission bits (for example, a build's
   `rm/mkdir` changes 0775 to 0755). It may not gain any permission/special bits.
   Parent deletion/type replacement and unrelated directory changes remain
   outside scope. Existing new-parent creation behaviour is unchanged. Parent
   directories never become committed paths merely because their modes changed.
3. Include changed declared outputs in the candidate's changed paths, review and
   commit. Record preparation command, exit/status, output tail and generated
   paths. Inform the reviewer which changes came from trusted generation and
   highlight declared outputs that disappeared (`deleted_paths`). Deletion is
   not silently treated as an ordinary rebuilt bundle.
4. The existing non-mutating project check, checked-tree comparison and fresh
   review remain mandatory. A normal build failure can feed the next bounded
   attempt; a policy/scope violation stops without retrying. Replay recovery
   repeats preparation/check/review without another coding call and refuses a
   frozen policy that differs from the saved source case.
5. Companion provisions a fresh candidate checkout, reruns the same recorded
   preparation, and requires that it change nothing before its independent
   project check. A stale or non-reproducible artifact cannot become `done`.
   It never resolves a newer policy in place of the admitted one.
6. Integration is another generation boundary: a human/Codex integration or
   `Loop.Coordinator` must rerun the recorded preparation on the merged source
   and recheck the exact resulting tree. Correct per-candidate bundles do not
   prove correct merged bundles. In the first Coordinator implementation, a
   non-clean rebuild blocks ref advancement with evidence; a human may instead
   record a separate regeneration commit, then check/review the final tree.
   Source or generated-file merge conflicts remain blocked, not silently
   resolved. This adds no automatic gated-primary admission (bug:1beebca).

A trusted build has the same host-command authority as an admitted check; the
repository-change guard is not an OS sandbox. This design grants no model shell
access, automatic primary integration, deployment, or push authority.
The command string is frozen, but `bun run v6:build` executes `package.json`,
the build entry and their repository dependencies, which the coder can edit.
Record edits to the policy's explicit build-definition paths and flag them in
the reviewer prompt. That flag is not a claim to enumerate all executable
dependencies or to make model-edited build code safe.

## Acceptance

- Local policy selects only its admitted repo/check; forged task metadata fails.
- Without policy, existing coding and replay behavior is unchanged.
- A source edit regenerates an allowed tracked or new output, passes check and
  fresh review, and commits that output with the source.
- Nonzero preparation, out-of-scope mutation/deletion, or symlink escape cannot
  produce a checked candidate.
- The check still rejects tracked mutation after its tree snapshot.
- Companion rejects a candidate whose declared output needs regeneration, and
  accepts the exact reproducible candidate even after host policy changes.
- Build identical source in two different absolute checkout paths, one with a
  space: declared output bytes must match, including maps/timestamps if emitted.
- Merge two individually correct candidates, then rebuild: require clean output
  or an explicit regeneration commit; Coordinator never advances a ref with a
  stale merged artifact. Exercise the dirty-merge refusal before ref mutation.
- Editing a configured build-definition path is visibly flagged for review.
- One bounded real VORTEX-source trial proves artifacts are committed by the
  worker; a second build is clean. No paid/free provider calls are needed.

## Deployment boundary

A policy takes effect only after an idle Trailblazer rebuild/restart, as with
all cached local peer settings. Configure it on the sending peer's local policy
for each exact admitted worktree/check pair; main-checkout admission is separate.
Do not retrofit an already admitted case: its saved manifest is authoritative.
Cases with no manifest retain the existing path. A replay with changed artifact
policy is refused rather than silently rebuilding under new authority.

The worker records preparation evidence as an `attempt` event with stage
`artifacts`; failures retain their scope/build reason. The case task and
lifecycle journal both retain the frozen manifest. Companion and Coordinator
use this recorded value, not the current peer settings. A generated deletion
is staged exactly once and stays visible in the checked tree and review diff.
No policy has been enabled or deployed merely by adding this implementation.
