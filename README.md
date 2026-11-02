# Trailblazer

A local coding tool for AIs. It indexes a repository the way a person who knows
the land knows it — definitions, references, design sections and how they use
each other — so that a code model is given the trail of the task instead of
being sent to find it.

It was built in phases: the core (parsing, the graph, vectors, design-document
nodes, the questions answered without a model, and the indexer that keeps them
current), the coding loop, its events, and much of the VORTEX integration are
in. The design is [`docs/design.md`](docs/design.md); the work still open is
tracked by [`docs/2026-10-23-design-review.md`](docs/2026-10-23-design-review.md)
and the repository's git-bug issues. The dated plans in `docs/` are historical.

## Requirements

- Erlang/OTP 29.1.1 and Elixir 1.20.4-otp-29, both pinned in `.tool-versions`
  and installed with [mise](https://mise.jdx.dev)
- `ripgrep` on `PATH` (the file listing is `rg --files`, as ranger's is)
- Rust and cargo, for the tree-sitter parser process
- For the live tests (`mix test --only live`): EmbeddingGemma 2 on
  `127.0.0.1:8091` and Qdrant on `127.0.0.1:6333`

## Getting started

```
mise install
mix deps.get
mix test
```

`mix test` is hermetic: no network and no services. Tests that need the
embedder or Qdrant are tagged `:live` and run with `mix test --only live`.

## Coding tasks

With the local service running, submit a task and wait for its report:

```sh
trailblazer run --repo /path/to/repo "Describe the change" --file lib/example.ex --check 'mix test'
trailblazer run --repo /path/to/repo "Describe the change" --no-wait
trailblazer case CASE_ID
```

`--file` and `--design` can be repeated; `--design` supplies the applicable
rules as text. Tasks run one at a time in private worktrees. A `fixed` report
has a commit on its own branch; the caller's checkout is left alone. A task
without a check is `unverified` and left uncommitted. The waiting command exits
0 only for `fixed`; `--no-wait` returns the case id immediately. `case` shows
its task, state and report. Tasks interrupted by a service restart are marked
failed; the in-memory queue is not replayed.

The authenticated JSON API exposes `POST /run` (202 with `{case}`) and
`POST /case` (`{case, status, report, record}`); case records keep spilled text
as file pointers, including invalid model bytes, so the response remains JSON.

## Where things live

- `~/.local/share/trailblazer/` — the state directory: `trailblazer.db` and
  `endpoint.json`. Set `TRAILBLAZER_STATE_DIR` to move it.
- `priv/migrations/` — the graph's SQL schema.
- `docs/` — the design and the plans, committed with the code.

Parts of this software are derived from Aider and carry the attribution in
[`NOTICE`](NOTICE).