# Embedder latency: queries first, flash attention off (2026-11-06)

Measured on the shared embedder (EmbeddingGemma 2 Q8_0 on the RX460 through
Vulkan, `ranger-embed`, port 8091: `-c 32768 -b 8192 -ub 8192 --parallel 4`).

## Queries waited behind document batches

llama-server serves requests in arrival order and has no priority between
them. A trail or memory query sent while document work is queued waits for
all of it:

| Query sent | Latency |
|---|---|
| embedder idle | 0.18 s |
| during one 16-document request (about 1,500 tokens each) | 194 s |
| during a stream of 1-document requests | 9 to 11 s |
| after the client of a 16-document request hung up | 35 s (queued work is dropped; the 4 running slots finish) |

**Change (`EmbedGate`, `Embed`):** a query runs inside `EmbedGate.query/2`,
and every document request first calls `EmbedGate.clear/1`, which waits while
any query runs. A query now waits for at most the one request already on the
embedder. Batch sizes and document limits are unchanged (16 per request, 2,400
characters per definition): the code embedding mix stays as it was.

The history backfill (`Trailblazer.History.ingest/2`) registers at
`EmbedGate.idle_priority/0`, below every indexer. It takes the gate one batch
at a time, only when no indexer has work, and queries preempt it between
requests like all document work.

## Flash attention off on Polaris

One document per request, same build and flags, flash attention on (the
default) and off:

| Tokens | on | off |
|---|---|---|
| 378 | 617 tok/s | 592 tok/s |
| 746 | 556 tok/s | 570 tok/s |
| 1,482 | 300 tok/s | 431 tok/s |
| 2,954 | 201 tok/s | 302 tok/s |

RADV's flash-attention path on Polaris is the slower one for longer inputs;
short inputs are unchanged. With the operator's approval, the Vulkan branch of
`~/.local/share/ranger/serve-embed.sh` (used by the `ranger-embed` unit and by
mirai-agent's inference config) now passes `-fa off`. Live after the restart:
1,482 tokens at 444 tok/s, 2,954 tokens at 322 tok/s. The CPU fallback keeps
the default. To undo: remove `-fa off` from that line and
`systemctl --user restart ranger-embed`.

Throughput still falls with input length (about 550 tok/s up to 750 tokens,
about 320 at 3,000), so a long document costs more per token than a short one.
