# Spark coding trial implementation plan

> For agentic workers: use superpowers:executing-plans to execute these steps.

**Goal:** Run the parked VORTEX claims task through Trailblazer using Spark-X2.6-4B.

**Architecture:** Serve the pinned Q4_K_M GGUF through the existing CPU router. Change the coding client and its defaults to Spark's documented samplers; keep the planner brain and embedding service unchanged.

**Tech stack:** llama.cpp router, Elixir/OTP worker, planner/VORTEX admission.

**Spec:** Operator request to switch Trailblazer to XHToken/Spark-X2.6-4B and transfer the parked OpenCode task.

## Constraints and review focus

- AMD remains on embeddings; this trial does not deploy the historical phase split.
- Model alias is `spark-x2.6-4b:q4`; context starts at 16,384 tokens.
- Sampling: temperature 1.0, top_p 0.95, top_k 0 (disabled), min_p 0, presence penalty 0, repetition penalty 1.
- Verify the downloaded GGUF against the publisher's SHA-256.
- Preserve the existing claims draft and plan; do not merge an unchecked worker candidate.
- Admit exactly one coding task through the existing resource gate while OpenCode stays idle.

## Steps

- [ ] Update the model request regression to expect Spark and its samplers; observe failure.
- [ ] Change `lib/trailblazer/config.ex` and `lib/trailblazer/model.ex`, update the canonical model description, and run focused and full tests.
- [ ] Add the Spark preset to the serving repository's `config/llama-router.ini`; verify a real model response and tool format before dispatch.
- [ ] Integrate the verified configuration changes and hot-load Trailblazer while its worker is idle.
- [ ] Transfer the preserved claims work into the worker's admitted task context, then dispatch VORTEX bug d22121c and inspect its first real model call.
- [ ] Record the model, request timings, assignment receipt and any candidate verification on the task issues.
