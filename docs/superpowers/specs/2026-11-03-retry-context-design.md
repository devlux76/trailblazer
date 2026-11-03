# Preserve evidence and refuse ungrounded zero-read retries

Issue: trailblazer:9ae2ace. F15's first failed docs SEARCH copied plan prose;
neither prompt contained the literal paragraph. Edits.apply is atomic: a missed
block writes NONE of the submitted edits. Its retry omitted the rest of the
submitted blocks and the zero-read coder spent >70 minutes debating context.

Keep each complete submitted block set before Edits.apply, for both successful
and missed applications. Retry feedback calls these submitted blocks, not
applied changes; they are reference evidence, not proof of current file content.
The reset still returns to base, and a later failed submission replaces the
previous submission's evidence. Check-mutated files never become this context.

For read_rounds=0, a no_match with empty closest excerpt, or a missing file with
nonempty SEARCH, stops before another coder call. Record source_context_missing
with affected paths and tell Planner to supply literal current anchors or
explicitly authorize read rounds on a fresh admission. Do not widen the read
budget, fuzzy-apply an edit, or infer source from the plan. An available closest
excerpt permits the existing bounded retry. Nonzero read budgets retain their
current behavior. Unsafe paths retain existing containment refusals.

Plan authors must provide literal before-text for every edit in a zero-read
plan, including documentation, and the literal inserted tests. If discovery is
required, admit read_rounds>=1. This is a planning requirement, not a claim that
free-form plan text is statically validated. The new guard catches the concrete
unanswerable failure after an edit attempt, not every possible bad plan.

Acceptance: a partially matching submission is retained in the next prompt,
with no files written; a zero-read miss with no excerpt stops after one model
call with a recorded diagnostic; an excerpt-backed miss still retries; nonzero
read behavior is unchanged; retries never reuse an earlier submission or
check-mutated source. Full suite and independent Claude review before deploy.
