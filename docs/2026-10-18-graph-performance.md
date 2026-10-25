# Graph sync performance, 2026-10-18

Graph-only runs against `/home/mirai/projects/sojourney`, with a fresh temporary
SQLite store, embedding paused and filesystem watching disabled. No model or
vector service calls. The repository had 229 supported files.

| Stage | Before (seconds) | After (seconds) |
| --- | ---: | ---: |
| List and hash supported files | 0.60 | 0.22 |
| Parse and extract citations | 35.79 | 6.16 |
| Store parsed files | 7.35 | 6.24 |
| Resolve references | 104.13 | 0.35 |
| Store resolved edges | 3.23 | 0.83 |

The separate first-watch measurement after the changes was **14.34 seconds**:
229 files, 2,542 nodes, 9,796 edges, zero stale files. The staged profile and
first-watch measurement ran concurrently; these are wall times on this host,
not a portable benchmark guarantee. The earlier acceptance run reported 215
seconds; its baseline had other acceptance/embedding work running as well.

The resolver now indexes one coherent snapshot by key, name, path and imported
name, rather than repeatedly scanning all refs and nodes. Tree-sitter queries
are compiled once per language per Port process; parsers and query cursors
remain local to each parse. A first watch awaits its initial sync instead of
performing a second listing and resolution pass.

To repeat the first-watch measurement with a throwaway store:

```sh
MIX_ENV=test mise exec -- mix run bench/graph_sync.exs /home/mirai/projects/sojourney
```

The benchmark uses the normal indexer, including file-module attribution,
constructor/type references and citation resolution. Pending vectors remain
pending; it does not contact embedding or vector services.
