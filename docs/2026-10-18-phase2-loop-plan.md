# Trailblazer Phase 2 (the loop) Implementation Plan

**Goal:** Trailblazer does a coding task itself: `trailblazer run --repo R "request"` gives the task to the local code model with a trail, applies its edits in a worktree of its own, runs the project's check, has the change reviewed against the request and the design, retries up to three attempts, and commits on a `trailblazer/<case>` branch only when check and review pass. It answers with one fixed-shape report and keeps a complete case record. This is what makes Trailblazer more than ranger with more steps (the operator, 2026-10-18).

**Spec:** `docs/design.md` §5 and §7.1–7.4, §7.6, §7.7 and §8. Phase 3 (§7.5 friends over VORTEX, §7.8 doors and queue persistence) is out of scope; until then an exhausted task's dossier comes back in the report.

**Who:** Codex and Claude work in parallel from this plan; MiniMax M3.1 Flash (OpenCode Go) takes tasks as its budget allows. **Every task is reviewed by someone who did not write it** (the review column). Reviews run alongside the next task and never block it; the author folds the findings into their next commit. The edge-case register in the phase-1 plan's Task 1 is shared and grows with this phase.

**Protocol:** each author works on a branch in their own worktree from current `main`, runs the full suite (`mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`, and `cargo test` when Rust changed, native work under `inference-lock`), rebases, fast-forwards `main` and sends one VORTEX note (SHA, tests, register entries). Nobody restarts the deployed service except Claude.

## Order

```
L1 model client ─┐
L2 edit blocks  ─┤
L3 workspace    ─┤
L4 check runner ─┼──> L7 the loop ──> L8 run on API and CLI ──> L9 evaluation on sojourney
L5 case records ─┤
L6 model tools  ─┤
L10 prompts     ─┘
```

L1–L6 and L10 have no dependencies on each other: their interfaces are fixed below, so each can be built and tested alone. L7 needs all of them. L8 needs L7. L9 needs L8.

| Task | Author | Review | Depends on |
|---|---|---|---|
| L1 Model client | Codex | Claude | none |
| L2 SEARCH/REPLACE edit blocks | Claude | Codex | none |
| L3 Workspace (worktree, branch, commit) | Codex | Claude | none |
| L4 Check runner | Codex | Claude | none |
| L5 Case records | Claude | Codex | none |
| L6 The core's questions as model tools | Claude | Codex | none |
| L10 Coder, reviewer and dossier prompts | Claude | Codex | none |
| L7 The loop | Claude | Codex | L1–L6, L10 |
| L8 `run` on the API and the CLI | Codex | Claude | L7 |
| L9 Evaluation on sojourney | Claude and Codex | each other | L8 |

## Global constraints

- Model: from `Config.get(:code_model)` (default `"qwen3.6-35b-a3b:mtp-q4"`) at `Config.get(:code_model_url)` (default `"http://127.0.0.1:8094/v1"`), OpenAI-compatible chat completions, streaming. Settings from Unsloth's card (design §7.2): temperature 0.6, top_p 0.95, top_k 20, min_p 0, presence_penalty 0, thinking on with `chat_template_kwargs: {preserve_thinking: false}`. Reasoning is recorded, never sent back.
- One task at a time: one model on one CPU. While the model generates, embedding is paused on every watched repository (`Indexer.pause_embedding/1`, resumed after), so the two do not fight for the CPU.
- The router holds one model (`--models-max 1`): a ranger query evicts Qwen. A model call that finds its model loading waits (up to `Config.get(:code_model_timeout)`, default 20 minutes for the first token) instead of failing.
- Trailblazer never edits a repository's checkout, never merges, never pushes, and never works on its own repository (operator's rule). Edits happen only inside the task's worktree; every path an edit names goes through the same containment check as `Files.read/3`.
- `check` is a shell command from a trusted caller (CLI or the API's bearer token); it runs inside the worktree with a timeout, and nothing else is run.
- Prompts and replies are recorded verbatim (design §8). No case may be lost or recorded partially.

## Forward from the register (all tasks)

- A4/A5/A6: model output is text from a model: invalid UTF-8, look-alike quotes, CRLF and fences that do not close must be handled, never crash the loop (L2, L1).
- A9/A10/E3: an edit's path is data: `../`, absolute paths, symlinks out and paths with `:` or spaces are refused or quoted, never followed outside the worktree (L2, L3).
- D4: a reply that is not the expected shape (no blocks, half a block, a tool call with bad arguments) is a failed attempt with feedback, not an exception (L1, L2, L6, L7).
- D6: an HTTP 200 from the router that holds no message, or a stream cut short, is an error, not an empty answer (L1).
- E5/E7/E9: a model call or a check that times out, a router that restarts mid-stream, and a task killed mid-attempt leave a complete record of what happened up to then (L5, L7).
- E16: one bad task never takes the service down; a crash in the loop ends that task as `failed` with its record (L7, L8).
- H1: a check that prints megabytes, a huge file in the trail, and a budget too small are bounded (last 4,000 characters of check output; files in full only within the budget) (L4, L7).
- G-class: two tasks on one repository get two worktrees and two branches; branch names never collide (case ids are unique) (L3).

## L1 Model client (Codex; review Claude)

**Files:** `lib/trailblazer/model.ex`, `test/trailblazer/model_test.exs`. Copy, do not depend on, mirai-agent's `ModelClient`, `SSE.Parser` and `Turn.NativeToolCalls` (design §9).

**Interface:** `Trailblazer.Model.chat(messages, opts) :: {:ok, %{content: String.t(), reasoning: String.t(), tool_calls: [%{id, name, arguments}], usage: %{prompt_tokens, completion_tokens}, ms: integer()}} | {:error, term()}`. `messages` are OpenAI-shaped maps; `opts[:tools]` are OpenAI tool definitions; `opts[:req_options]` is merged for tests. Streaming with SSE; `reasoning_content` deltas go to `reasoning`. Errors: `:model_down` (connection refused), `{:http, status}`, `:timeout`, `{:bad_response, why}` (D6).

**Tests (Req.Test stubs):** a streamed answer with reasoning and content; a streamed tool call assembled from deltas; the settings above in the request body; a cut stream and a 200 with no choices are `{:bad_response, _}`; connection refused is `:model_down`. One `@tag :live` call to the router.

## L2 SEARCH/REPLACE edit blocks (Claude; review Codex)

**Files:** `lib/trailblazer/loop/edits.ex`, `test/trailblazer/loop/edits_test.exs`. Ported from Aider (Apache-2.0; NOTICE updated).

**Interface:** `Edits.parse(text) :: {:ok, [%{path, search, replace}]} | {:error, reason}`; `Edits.apply(worktree, blocks) :: {:ok, [path]} | {:error, [%{block, reason, closest}]}`. Matching: exact, then whitespace-tolerant (leading indentation and trailing spaces), then `...` elision; an empty SEARCH creates a new file; a miss reports the closest lines of the file. All or nothing: if any block misses, no file is written.

## L3 Workspace (Codex; review Claude)

**Files:** `lib/trailblazer/loop/workspace.ex`, tests.

**Interface:** `Workspace.open(repo, case_id) :: {:ok, %{path, branch, base}}` (a `git worktree add` of the repo's current HEAD at `<state_dir>/worktrees/<case_id>` on branch `trailblazer/<case_id>`); `Workspace.diff(ws) :: String.t()`; `Workspace.commit(ws, message) :: {:ok, sha}`; `Workspace.reset(ws)` (back to the base between attempts); `Workspace.close(ws)` (removes the worktree, keeps the branch); `Workspace.prune(repo, older_than)` (explicit cleanup only). Refuses Trailblazer's own repository. Never touches the caller's checkout.

## L4 Check runner (Codex; review Claude)

**Files:** `lib/trailblazer/loop/check.ex`, tests.

**Interface:** `Check.default(repo) :: String.t() | nil` (`mix test` with a mix.exs, `bun test` with bun.lock, `npm test` with a test script, `pytest` with pytest config, `cargo test` with Cargo.toml, `go test ./...` with go.mod); `Check.run(worktree, command, opts) :: %{status: :pass | :fail | :timeout, exit: integer() | nil, output_tail: String.t(), ms: integer()}`. Runs `sh -c` inside the worktree, with a timeout (default 15 minutes) that kills the process group, and keeps the last 4,000 characters.

## L5 Case records (Claude; review Codex)

**Files:** `lib/trailblazer/loop/case_record.ex`, schema in `priv/migrations/001_graph.sql` (new tables, `CREATE TABLE IF NOT EXISTS`), tests.

**Interface:** `CaseRecord.open(task) :: {:ok, case_id}`; `CaseRecord.event(case_id, kind, data)`, where kind is `prompt | reply | tool_call | edit | check | review | attempt | report`, written synchronously before the loop moves on; large text goes to files under `<state_dir>/cases/<case_id>/`; `CaseRecord.close(case_id, report)`; `CaseRecord.get(case_id)` gives the whole record in order.

## L6 The core's questions as model tools (Claude; review Codex)

**Files:** `lib/trailblazer/loop/tools.ex`, tests.

**Interface:** `Tools.definitions() :: [openai_tool]` for `where`, `uses`, `impact`, `read` and `search`; `Tools.call(repo, name, arguments_json) :: String.t()`, compact text for the model, capped, with argument validation (D4); an unknown tool or bad arguments give an error text, not an exception.

## L10 Prompts (Claude; review Codex)

**Files:** `priv/prompts/coder.md`, `priv/prompts/reviewer.md`, `priv/prompts/dossier.md`, `lib/trailblazer/loop/prompts.ex`. Short: the 14,317-token opening prompt of OpenCode is the figure to beat (design §10). The coder prompt defines the SEARCH/REPLACE format with one example; the reviewer prompt asks three questions (does it do what was asked, only that, the way the design says) and answers `PASS` or `FAIL: <findings>`; the dossier template is design §7.5.

## L7 The loop (Claude; review Codex)

**Files:** `lib/trailblazer/loop.ex`, tests with fake model replies (no live model in `mix test`).

**Interface:** `Trailblazer.Loop.run(task, opts) :: report` with the task and report shapes of design §7.1 and §7.6. Stages per design §5: open the case and the workspace, build the trail (`Trail.build`, the requested files included), up to three attempts (prompt, tool calls answered with L6, edits applied with L2, the worktree reset between attempts, the check, then the review in a fresh context), then commit or the dossier. Each stage is recorded with L5 before the next. A crash anywhere ends the task as `failed` with its record (E16). Embedding is paused around model calls.

## L8 `run` on the API and the CLI (Codex; review Claude)

**Interface:** API `POST /run {repo, request, files?, design?, check?}` gives `{case}` at once, and the task runs in a single serial task runner; `POST /case {case}` gives the state and, once done, the report. CLI `trailblazer run --repo R "request" [--file F]... [--design S]... [--check CMD] [--no-wait]` waits (polling `case`) and prints the report, exiting 0 for `fixed`, 1 otherwise. `trailblazer case ID` prints the record's summary.

## L9 Evaluation on sojourney (Claude and Codex)

A series of real, small tasks on sojourney (the operator's test bed), with expected outcomes written down first: a one-line bug fix, a renamed parameter across two call sites, a new pure function with a test, and a change the design forbids (the review must catch it). Each result is triaged as harness or model (operator's rule) and recorded in `docs/trials.md`. Branches are left for inspection; sojourney's own checkout is never touched.
