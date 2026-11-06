#!/usr/bin/env python3
"""Replay-memory density probe (history-retrieval plan step 0).

Embeds every history entry (commit x file) from our owned repos, replays each
bug's request as a retrieval query against the corpus built from strictly
older, different-bug commits, and reports sibling recall@k, MRR, the density
curve (pool subsampled to 25/50/100%) and score histograms. One script, no
infra. See docs/2026-11-05-history-retrieval-plan.md part 2/3 and step 0.

Python 3 stdlib + numpy only. Outputs (never in git):
  ~/.local/share/claude-handoff/replay-probe/
    entries.jsonl, vectors.npy, queries.jsonl, report.md, dropped.log,
    embed_cache.jsonl (resumable: entries keyed by sha256 of the embed input).
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import math
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

REPOS = ["trailblazer", "vortex", "ranger", "planner", "scout", "mirai-agent", "sojourney"]
BASE = Path.home() / "projects"
OUT_DIR = Path.home() / ".local/share/claude-handoff/replay-probe"
PII_FILE = Path.home() / ".config/git/pii-patterns"
EMB_URL = "http://127.0.0.1:8091/v1/embeddings"

BATCH = 16
SLEEP = 0.2
MAX_CHARS = 6000
HOME_LIT = "/home/mirai"
DOC = "title: {path} | text: {body}"
QRY = "task: code retrieval | query: {text}"

BUG_RE = re.compile(r"bug:([0-9a-f]{7,})")
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@(.*)$", re.M)
SKIP_DIRS = {"_build", "deps", "node_modules", "dist"}
LOCK_PATS = ("*.lock", "package-lock.json", "mix.lock", "bun.lock*")
SQUASH_PREFIX = "Squashed snapshot"
K_LIST = (1, 3, 10, 50, 200)
FRACTIONS = (0.25, 0.50, 1.00)
SEEDS = 5
WIDEN = 20


def log(msg: str) -> None:
    print(f"[probe] {msg}", flush=True)


# ---------------------------------------------------------------- screen ----


def load_patterns() -> list:
    text = PII_FILE.read_text(encoding="utf-8")
    pats = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        pats.append(re.compile(line))
    if not pats:
        sys.exit(f"no usable patterns in {PII_FILE}")
    return pats


def screen_value(value: str, pats: list) -> bool:
    if HOME_LIT in value:
        return True
    for p in pats:
        if p.search(value):
            return True
    return False


# -------------------------------------------------------------- git I/O -----


def git(repo: str, *args: str) -> str:
    proc = subprocess.run(
        ["git", *args], cwd=BASE / repo, capture_output=True,
        text=True, encoding="utf-8", errors="replace", check=True,
    )
    return proc.stdout


def collect_commits(repo: str) -> list:
    refs = [r for r in git(repo, "for-each-ref", "--format=%(refname)",
                           "refs/heads", "refs/tags").splitlines() if r]
    if not refs:
        return []
    fmt = "%x1f%H%x1f%P%x1f%aI%x1f%B%x1e"
    commits, seen = [], set()
    for rec in git(repo, "log", "--no-merges", *refs, f"--format={fmt}").split("\x1e"):
        rec = rec.strip("\n\t ")
        if not rec:
            continue
        f = rec.split("\x1f")
        if len(f) < 5:
            continue
        sha, parent, date_iso, message = f[1].strip(), f[2].strip(), f[3].strip(), f[4].rstrip()
        if sha in seen:
            continue
        seen.add(sha)
        if message.split("\n", 1)[0].startswith(SQUASH_PREFIX):
            continue
        dt = parse_date(date_iso)
        commits.append({"repo": repo, "commit": sha, "parent": parent,
                        "date_iso": date_iso, "dt": dt, "message": message})
    return commits


def parse_date(s: str) -> datetime:
    dt = None
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def numstat(repo: str, sha: str) -> list:
    out = git(repo, "diff-tree", "--no-commit-id", "-r", "--numstat", "-z", sha)
    files = []
    for chunk in out.split("\x00"):
        if not chunk:
            continue
        parts = chunk.split("\t")
        if len(parts) >= 3:
            files.append((parts[0].strip(), parts[1].strip(), "\t".join(parts[2:]).strip()))
    return files


def keepable_path(path: str) -> bool:
    parts = path.split("/")
    if any(d in parts[:-1] for d in SKIP_DIRS):
        return False
    name = parts[-1]
    return not any(fnmatch.fnmatch(name, p) for p in LOCK_PATS)


def parse_hunks(patch: str) -> list:
    hunks = []
    for m in HUNK_RE.finditer(patch):
        start = int(m.group(1))
        n = int(m.group(2)) if m.group(2) is not None else 1
        end = start + n - 1 if n > 0 else start - 1
        hunks.append({"range": [start, end], "ctx": m.group(3).lstrip()})
    return hunks


def bug_request(repo: str, bug: str) -> str | None:
    try:
        d = json.loads(git(repo, "bug", "bug", "show", bug, "--format=json"))
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return None
    parts = [d.get("title") or ""]
    comments = d.get("comments") or []
    for i, c in enumerate(comments):
        msg = (c.get("message") or "").strip()
        if msg and (i == 0 or msg.startswith("Implementation plan:")):
            parts.append(msg)
    req = "\n\n".join(p for p in parts if p).strip()
    return req or None


# ------------------------------------------------------------ embedding -----


def embed(texts: list, cache: dict, cache_path: Path) -> int:
    fresh = 0
    pending = [(i, t) for i, t in enumerate(texts)
               if hashlib.sha256(t.encode()).hexdigest() not in cache]
    for start in range(0, len(pending), BATCH):
        batch = pending[start:start + BATCH]
        arr = post_embed([t for _, t in batch])
        with cache_path.open("a", encoding="utf-8") as fh:
            for (_, text), vec in zip(batch, arr):
                key = hashlib.sha256(text.encode()).hexdigest()
                cache[key] = vec
                fh.write(json.dumps({"k": key, "v": vec}) + "\n")
        fresh += len(batch)
        time.sleep(SLEEP)
        log(f"  embedded {fresh}/{len(pending)} new texts")
    return fresh


def post_embed(inputs: list) -> list:
    body = json.dumps({"input": inputs}).encode()
    req = urllib.request.Request(EMB_URL, data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = json.loads(r.read().decode())
    arr = [None] * len(inputs)
    for item in data["data"]:
        arr[item["index"]] = item["embedding"]
    if any(v is None for v in arr):
        raise RuntimeError("embeddings response incomplete")
    return arr


def l2(mat: np.ndarray) -> np.ndarray:
    norm = np.linalg.norm(mat, axis=1, keepdims=True)
    norm[norm == 0] = 1.0
    return mat / norm


def load_cache(path: Path) -> dict:
    cache = {}
    if path.exists():
        with path.open() as fh:
            for line in fh:
                line = line.strip()
                if line:
                    d = json.loads(line)
                    cache[d["k"]] = d["v"]
    return cache


# ------------------------------------------------- corpus, queries, scoring --


def build_corpus(repos: list, pats: list):
    dropped = []
    drop_counts = {}
    per_repo = {}
    entries = []
    seen = set()
    bug_reqs = {}
    for repo in repos:
        t0 = time.time()
        commits = collect_commits(repo)
        n_bug = sum(1 for c in commits if BUG_RE.search(c["message"]))
        kept = drop_n = 0
        for c in commits:
            m = BUG_RE.search(c["message"])
            bug = m.group(1) if m else None
            for add, dele, path in numstat(repo, c["commit"]):
                if (c["commit"], path) in seen:
                    continue
                seen.add((c["commit"], path))
                if add == "-" or dele == "-" or add == "0":
                    continue  # binary or deletions-only
                if not keepable_path(path):
                    continue
                key = (repo, bug)
                if key not in bug_reqs:
                    bug_reqs[key] = bug_request(repo, bug) if bug else None
                request = bug_reqs[key]
                if request is None:
                    request = c["message"].strip()
                patch = git(repo, "show", "--format=", "-U3", c["commit"], "--", path)
                bad = None
                if screen_value(request, pats):
                    bad = "request"
                elif screen_value(c["message"], pats):
                    bad = "message"
                elif screen_value(patch, pats):
                    bad = "patch"
                if bad:
                    dropped.append(f"{repo} {c['commit']} {path} {bad}")
                    drop_n += 1
                    continue
                e = Entry(repo, c["commit"], c["parent"], c["date_iso"], c["dt"], bug,
                          path, request, patch, parse_hunks(patch))
                entries.append(e)
                kept += 1
        drop_counts[repo] = drop_n
        per_repo[repo] = {"commits": len(commits), "bug_commits": n_bug, "entries": kept}
        log(f"corpus {repo}: {len(commits)} commits ({n_bug} bug), {kept} entries, {drop_n} dropped ({time.time()-t0:.1f}s)")
    return entries, dropped, per_repo, drop_counts


class Entry:
    __slots__ = ("repo", "commit", "parent", "date_iso", "dt", "bug", "path",
                 "request", "patch", "hunks")

    def __init__(self, repo, commit, parent, date_iso, dt, bug, path, request, patch, hunks):
        self.repo, self.commit, self.parent = repo, commit, parent
        self.date_iso, self.dt, self.bug, self.path = date_iso, dt, bug, path
        self.request, self.patch, self.hunks = request, patch, hunks


def build_queries(entries: list) -> list:
    groups = {}
    for i, e in enumerate(entries):
        if e.bug:
            groups.setdefault((e.repo, e.bug), []).append(i)
    queries = []
    for (repo, bug), idxs in groups.items():
        mem = [entries[i] for i in idxs]
        base = min(mem, key=lambda e: (e.dt, e.commit))
        paths = sorted({e.path for e in mem})
        text = (base.request + "\nFiles: " + ", ".join(paths)).strip()
        qhunks = {}
        for e in mem:
            qhunks.setdefault(e.path, []).extend(e.hunks)
        queries.append({"repo": repo, "bug": bug, "base": base.commit, "dt": base.dt,
                        "text": text, "paths": paths, "qhunks": qhunks, "idxs": idxs})
    return queries


def annotate_pool(queries: list, entries: list) -> None:
    for q in queries:
        pool = [i for i, e in enumerate(entries)
                if e.dt < q["dt"] and e.bug != q["bug"]]
        qpaths = set(q["paths"])
        path_rel, region_rel = [], []
        qlook = [(hp, hi["range"], hi["ctx"]) for hp in q["paths"]
                 for hi in q["qhunks"].get(hp, [])]
        for i in pool:
            e = entries[i]
            if e.repo != q["repo"] or e.path not in qpaths:
                continue
            path_rel.append(i)
            hit = False
            for cs, ce, cctx in [(h["range"][0], h["range"][1], h["ctx"]) for h in e.hunks]:
                if ce < cs:
                    continue
                for _p, (qs, qe), qctx in qlook:
                    if _p != e.path or qe < qs:
                        continue
                    if (cs <= qe + WIDEN and ce >= qs - WIDEN) or (cctx and cctx == qctx):
                        hit = True
                        break
                if hit:
                    break
            if hit:
                region_rel.append(i)
        q["pool"] = pool
        q["path_rel"] = path_rel
        q["region_rel"] = region_rel
        # aliases so tier-keyed reads (q["path"], q["region"]) work everywhere
        q["path"] = path_rel
        q["region"] = region_rel


def first_rank(pool: list, order: np.ndarray, rel: list) -> int:
    if not rel:
        return -1
    relset = set(rel)
    rank_of = {}
    for pos, j in enumerate(order, start=1):
        rank_of[j] = pos
    return min(rank_of[j] for j in range(len(pool)) if pool[j] in relset)


def eval_full(queries: list, tiers=("path", "region")) -> dict:
    for q in queries:
        q["order"] = np.argsort(-q["scores"], kind="stable") if q["scores"].size else np.array([], int)
        q["first_path"] = first_rank(q["pool"], q["order"], q["path_rel"])
        q["first_region"] = first_rank(q["pool"], q["order"], q["region_rel"])
    out = {}
    for tier in tiers:
        key = f"first_{tier}"
        per = {}
        rows = [(q["repo"], q[key]) for q in queries if q[f"{tier}_rel"]]
        for repo in sorted({r for r, _ in rows}):
            per[repo] = summarize([x for r, x in rows if r == repo], K_LIST)
        per["ALL"] = summarize([x for _, x in rows], K_LIST)
        out[tier] = per
    return out


def summarize(ranks: list, ks) -> dict:
    r = np.array(ranks, dtype=float)
    return {"n": int(r.size),
            "recall": {k: float(np.mean(r <= k) * 100) for k in ks},
            "mrr": float(np.mean(1.0 / r)) if r.size else 0.0,
            "median": float(np.median(r)) if r.size else float("nan")}


def eval_density(queries: list, tiers=("path", "region")) -> dict:
    table = {}
    for frac in FRACTIONS:
        per_seed = []
        for si in range(SEEDS):
            rng = np.random.default_rng(1000 + si)
            have = {t: 0 for t in tiers}
            keep = {t: 0 for t in tiers}
            firsts = {t: [] for t in tiers}
            for q in queries:
                pool = q["pool"]
                m = len(pool)
                take = m if frac >= 1.0 else max(1, int(round(m * frac)))
                if take < m:
                    sub = np.sort(rng.choice(m, size=take, replace=False))
                else:
                    sub = np.arange(m)
                ordsub = np.argsort(-q["scores"][sub], kind="stable")
                in_sub = set(sub.tolist())
                for t in tiers:
                    rel = q[f"{t}_rel"]
                    if not rel:
                        continue
                    have[t] += 1
                    relset = set(rel)
                    hits = any(pool[jj] in relset for jj in sub)
                    if hits:
                        keep[t] += 1
                        firsts[t].append(
                            min(pos for pos, jj in enumerate(ordsub) if pool[sub[jj]] in relset) + 1)
            per_seed.append({"sib": {t: (keep[t] / have[t] * 100 if have[t]
                                         else 0.0) for t in tiers},
                             "recall": {t: {f"r{k}": float(np.mean([r <= k for r in firsts[t]]) * 100)
                                            if firsts[t] else 0.0 for k in DENSITY_K}
                                         for t in tiers}})
        table[f"{int(frac * 100)}%"] = agg_seeds(per_seed)
    return table


def agg_seeds(cells: list) -> dict:
    out = {"sib": {}, "recall": {}}
    for t in cells[0]["sib"]:
        v = np.array([c["sib"][t] for c in cells])
        out["sib"][t] = _sss(v)
    for t in cells[0]["recall"]:
        for k in cells[0]["recall"][t]:
            v = np.array([c["recall"][t][k] for c in cells])
            out["recall"].setdefault(t, {})[k] = _sss(v)
    return out


def _sss(v: np.ndarray) -> str:
    return f"{np.nanmean(v):.0f} [{np.nanmin(v):.0f}-{np.nanmax(v):.0f}]"


# ------------------------------------------------------- report + examples --


def hist(values: np.ndarray):
    if values.size == 0:
        return None
    lo = math.floor(values.min() / 0.02) * 0.02
    hi = math.ceil(values.max() / 0.02) * 0.02
    if hi <= lo:
        hi = lo + 0.02
    counts, edges = np.histogram(values, bins=max(1, int(round((hi - lo) / 0.02))),
                                 range=(lo, hi))
    return [f"{edges[i]:.2f}-{edges[i+1]:.2f}" for i in range(len(counts))], counts


def draw_hist(h, title: str, L: list) -> None:
    L.append(f"\n**{title}**")
    if h is None:
        L.append("(no data)")
        return
    labels, counts = h
    mx = max(int(counts.max()), 1)
    L.append("```")
    for lab, c in zip(labels, counts):
        L.append(f"{lab}  {int(c):5d} {'#'*int(round(50*c/mx))}")
    L.append("```")


def examples_block(queries: list, pats: list, entries: list, L: list) -> None:
    used = 0
    for q in queries:
        if used >= 5 or not q["path_rel"]:
            continue
        top = q["order"][:3]
        out = [f"- bug:{q['bug']} [{q['repo']}] query: {' '.join(q['text'].split())[:120]}"]
        relpath, relreg = set(q["path_rel"]), set(q["region_rel"])
        for pos, j in enumerate(top, 1):
            idx = q["pool"][j]
            e = entries[idx]
            rel = ("region" if idx in relreg else "path") if idx in relpath else "no"
            out.append(f"  {pos}. {e.path}  score={q['scores'][j]:.3f}  relevant={rel}")
        block = "\n".join(out)
        if screen_value(block, pats):
            continue
        L.append(block)
        used += 1


def build_report(entries, queries, per_repo, drop_counts, full, dens, pats, t0, n_emb, model) -> str:
    L = []
    w = L.append
    w("# Replay probe report (plan step 0, density)")
    w()
    w(f"Run {datetime.now(timezone.utc).isoformat(timespec='seconds')} — {len(entries)} entries, "
      f"{len(queries)} queries, {n_emb} embeddings made this run ({model}). "
      f"Wall {(time.time()-t0)/60:.1f} min.")
    w()
    w("## 1. Corpus")
    w()
    w("| repo | commits | bug commits | entries | dropped | queries |")
    w("|---|---:|---:|---:|---:|---:|")
    tc = tb = te = td = 0
    for repo, s in per_repo.items():
        nq = sum(1 for q in queries if q["repo"] == repo)
        tc += s["commits"]; tb += s["bug_commits"]; te += s["entries"]
        td += drop_counts.get(repo, 0)
        w(f"| {repo} | {s['commits']} | {s['bug_commits']} | {s['entries']} | "
          f"{drop_counts.get(repo, 0)} | {nq} |")
    nq_all = len(queries)
    w(f"| **ALL** | {tc} | {tb} | {te} | {td} | {nq_all} |")
    w()
    pools = [len(q["pool"]) for q in queries]
    w(f"Median pool size {np.median(pools):.0f} (q0: max pool {max(pools) if pools else 0}); "
      f"empty-pool queries: {sum(1 for p in pools if p == 0)}.")
    for tier in ("path", "region"):
        w(f"- queries with >=1 {tier} sibling: {sum(1 for q in queries if q[f"{tier}_rel"])}/{nq_all}")
    w()

    # 2. recall tables
    for tier in ("path", "region"):
        w(f"## 2. Recall — {tier} tier (over queries with a {tier} sibling; score = cosine)")
        w()
        w("| repo | n | recall@1 | recall@3 | recall@10 | recall@50 | recall@200 | MRR | median first rank |")
        w("|---|---:|" + " ---:|" * 8)
        for repo, s in full[tier].items():
            r = s["recall"]
            w(f"| {repo} | {s['n']} | " + " | ".join(f"{r[k]:.0f}%" for k in K_LIST)
              + f" | {s['mrr']:.2f} | {s['median']:.0f} |")
        w()

    # 3. density
    w("## 3. Density curve — recall as the corpus grows (5 seeds, mean [min-max])")
    w()
    w("| pool | PathR@3 | PathR@10 | RegR@10 | still-has-sibling (path) |")
    w("|---|---|---|---|---|")
    for frac, a in dens.items():
        w(f"| {frac} | {a['recall']['path']['r3']} | {a['recall']['path']['r10']} | "
          f"{a['recall']['region']['r10']} | {a['sib']['path']} |")
    w()
    w("Reading: PathR@k is sibling recall@k over queries that still have a sibling in the")
    w("subsampled pool; the last column is what fraction of queries that is relative to all")
    w("sibling queries.")
    w()

    # 4. histograms
    w("## 4. Score histograms (0.02 bins)")
    w()
    rels_all, irr_all, top_rel, top_irr = [], [], [], []
    for q in queries:
        if not q["path_rel"] or q["scores"].size == 0:
            continue
        relp = set(q["path_rel"])
        sc = [(s, q["pool"][i]) for i, s in enumerate(q["scores"])]
        rels_all += [s for s, idx in sc if idx in relp]
        irr_all += [s for s, idx in sc if idx not in relp]
        top_rel.append(max(s for s, idx in sc if idx in relp))
        top_irr.append(max(s for s, idx in sc if idx not in relp))
    top_rel, top_irr = np.array(top_rel), np.array(top_irr)
    rels_all, irr_all = np.array(rels_all), np.array(irr_all)
    for h, ttl in ((hist(top_rel), "top-1 relevant score per sibling query"),
                   (hist(top_irr), "top-1 irrelevant score per sibling query"),
                   (hist(rels_all), "all relevant candidate scores"),
                   (hist(irr_all), "all irrelevant candidate scores")):
        if h is not None:
            labels, counts = h
            mx = max(int(counts.max()), 1)
            first, last = next(i for i, c in enumerate(counts) if c), \
                max(i for i, c in enumerate(counts) if c)
            run = best = 0
            for c in counts[first:last + 1]:
                run = run + 1 if c == 0 else 0
                best = max(best, run)
            w(f"\n**{ttl}** — max consecutive empty 0.02-bins between occupied bins: {best} "
              f"({best*0.02:.2f})")
            w("```")
            for lab, c in zip(labels, counts):
                w(f"{lab}  {int(c):5d} {'#'*int(round(50*c/mx))}")
            w("```")

    if top_rel.size and irr_all.size:
        w()
        w(f"Separation check: min top-1 relevant {top_rel.min():.3f}, max all-scores irrelevant "
          f"{irr_all.max():.3f}; {int(np.sum(top_rel < irr_all.max()))} of {top_rel.size} top-1 relevant "
          "scores overlap that max. No perfect floor exists; rank, not absolute score, must decide.")
    w()

    # 5. examples
    w("## 5. Example queries (privacy-screened)")
    w()
    examples_block(queries, pats, entries, L)
    w()
    w("## 6. Housekeeping")
    w()
    w(f"- embeddings assembled this run (docs+queries, cache misses): {n_emb}")
    w(f"- total dropped by privacy screen: {sum(drop_counts.values())} entries (see dropped.log)")
    w("- rerun resumption: embed_cache.jsonl keyed by sha256 of each embed input")
    w()
    return "\n".join(L) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repos", default=",".join(REPOS), help="comma-separated repo subset")
    args = ap.parse_args()
    repos = [r.strip() for r in args.repos.split(",") if r.strip()]
    for repo in repos:
        if not (BASE / repo).is_dir():
            sys.exit(f"missing repo: {BASE / repo}")

    t0 = time.time()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    pats = load_patterns()

    entries, dropped, per_repo, drop_counts = build_corpus(repos, pats)
    (OUT_DIR / "dropped.log").write_text(
        "repo commit path field\n" + ("\n".join(dropped) + "\n" if dropped else ""))
    log(f"corpus: {len(entries)} entries, {len(dropped)} dropped")
    with (OUT_DIR / "entries.jsonl").open("w", encoding="utf-8") as fh:
        for e in entries:
            fh.write(json.dumps({"repo": e.repo, "commit": e.commit, "parent": e.parent,
                                 "date": e.date_iso, "bug": e.bug, "path": e.path,
                                 "request": e.request, "patch": e.patch,
                                 "hunks": e.hunks}) + "\n")

    cache_path = OUT_DIR / "embed_cache.jsonl"
    cache = load_cache(cache_path)
    docs = [DOC.format(path=e.path, body=e.request + "\n" + e.patch)[:MAX_CHARS]
            for e in entries]
    fresh_docs = embed(docs, cache, cache_path)
    docv = l2(np.asarray([cache[hashlib.sha256(t.encode()).hexdigest()] for t in docs],
                         dtype=np.float32))
    np.save(OUT_DIR / "vectors.npy", docv)

    queries = build_queries(entries)
    annotate_pool(queries, entries)
    qtexts = [QRY.format(text=q["text"])[:MAX_CHARS] for q in queries]
    fresh_q = embed(qtexts, cache, cache_path)
    qmat = l2(np.asarray([cache[hashlib.sha256(t.encode()).hexdigest()] for t in qtexts],
                         dtype=np.float32))
    for q, qv in zip(queries, qmat):
        q["scores"] = (docv[q["pool"]] @ qv) if q["pool"] else np.zeros(0)

    with (OUT_DIR / "queries.jsonl").open("w", encoding="utf-8") as fh:
        for q in queries:
            fh.write(json.dumps({"repo": q["repo"], "bug": q["bug"], "base_commit": q["base"],
                                 "pool_size": len(q["pool"]), "path_rel": len(q["path_rel"]),
                                 "region_rel": len(q["region_rel"])}) + "\n")

    full = eval_full(queries)
    dens = eval_density(queries)
    model = ""
    try:
        body = json.dumps({"input": ["ping"]}).encode()
        req = urllib.request.Request(EMB_URL, data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            model = json.loads(r.read().decode()).get("model", "")
    except Exception:
        pass
    report = build_report(entries, queries, per_repo, drop_counts, full, dens, pats,
                          t0, fresh_docs + fresh_q, model)
    (OUT_DIR / "report.md").write_text(report, encoding="utf-8")
    log(f"done in {(time.time()-t0)/60:.1f} min: {len(queries)} queries; report at {OUT_DIR/'report.md'}")


if __name__ == "__main__":
    main()
