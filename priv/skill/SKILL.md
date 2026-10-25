---
name: trailblazer
description: Ask Trailblazer, the local code-graph service, what to read before changing code - where a name is declared, who uses it, what a change affects, and a ranked, budgeted trail of definitions and design sections for a task. Use before editing, reviewing or debugging code in a repository Trailblazer watches; it replaces most exploratory grep/read loops.
---

# Trailblazer

Trailblazer keeps, for each watched repository, a graph of definitions and how they use each other (calls, references, imports, tests, `implements` links from code to design sections), plus one vector per definition. It answers from that graph without any model call.

The service runs as `systemctl --user status trailblazer`; the `trailblazer` command talks to it. Every command prints JSON and exits 0, or 1 on an error (the JSON then has `error` and often `hint`). `--repo DIR` defaults to the git root of the current directory.

## In this order

1. **`trailblazer trail "<the task in words>" [--file PATH]... [--budget N] --text`**
   Start here. Give it the task as you would state it, plus any files you already know matter, stack-trace or compiler lines (`lib/app.ex:42` in the request seeds that definition). It returns the most relevant definitions, full source first and then signatures, and the design sections they implement, headed `path:start-end`, packed to the budget (default 4000 tokens). If `notes` says `no vectors`, ranking used the graph alone.
2. **`trailblazer where NAME`** or **`trailblazer where PATH:LINE`**: where a name (`put`, `Mini.Store.put/2`, `saveHikes`) is declared, or what the reference on that line leads to.
3. **`trailblazer uses NAME|ID`**: every definition that uses it, with the line and `uncertain: true` when the name is ambiguous (defined twice, or imported from more than one place).
4. **`trailblazer impact NAME|ID [--depth N]`**: what a change could affect, breadth first through users of users (default depth 3).
5. **`trailblazer read PATH:FIRST-LAST`**: the exact lines, only inside the repository.
6. **`trailblazer search TEXT [--limit N]`**: exact names, then vector hits, then literal text matches mapped to their definitions. Put `--` before text that starts with a dash.

Also: `trailblazer watch` (start following a repository; the first sync takes a while on a large one), `trailblazer status` (files, nodes, edges, pending vectors, stale files, embedding state, and `following`: `events`, or `polling` every 15 s when no file watcher could start), `trailblazer stale_citations` (code citing design sections that no longer exist).

## Reading the answers

- `uncertain: true` means the graph could not settle which definition a reference means; check before relying on it.
- `stale: true` on a node means its file did not parse at the last edit; the node is the last good version.
- A repository that is not watched answers `409` with the hint `trailblazer watch <repo>`.
- Trailblazer never edits files. Never point it at its own repository (`~/projects/trailblazer`).
