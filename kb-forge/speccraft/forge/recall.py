#!/usr/bin/env python3
"""kb-forge recall — structural retrieval over the KB (the memory-palace walk).

Every KB fact carries `anchors:` in its frontmatter — the code locations and
topics it governs (loci). Given what you are about to touch, recall returns
exactly the facts filed at those loci, ordered by trust:

    ratified > ratified-partial > observed > pending-ratification > challenged

Anchor forms:
    backend/app/services        path prefix, matched against repo-relative paths
    topic:content-engine        topic slug, matched against --topic

Match rule for paths: a fact matches if any input file starts with one of its
path anchors, OR one of its path anchors starts with an input path (so passing
a directory recalls facts anchored to files inside it).

Usage:
    recall.py --config <kb>/kbforge.yaml --files backend/worker/tasks/evaluate_alerts.py ...
    recall.py --config <kb>/kbforge.yaml --topic monetization
    recall.py --config <kb>/kbforge.yaml --files ... --all   (include weak matches)

This is doc 06's Ground step at laptop scale: run it before starting work on a
module; zero hits on a risk-tagged path means the KB has no coverage there —
elicit or excavate before building.
"""
import argparse, json, os, sys
from datetime import datetime, timezone

RANK = {"ratified": 0, "ratified-partial": 1, "observed": 2,
        "pending-ratification": 3, "challenged": 4, "ruled": 1}

def log_telemetry(kbroot, event, detail, harness):
    """recall.py owns the recall_ran event, tagged by harness (spec
    2026-07-25-harness-agnostic-recall-proxy.md rev 2, Part C). Mirrors
    telemetry-lib.sh: same file, same fields + harness, same size guard,
    fire-and-forget — telemetry must never break recall output."""
    try:
        d = os.path.join(kbroot, "evals")
        os.makedirs(d, exist_ok=True)
        f = os.path.join(d, "telemetry.jsonl")
        if os.path.exists(f) and os.path.getsize(f) > 5242880:
            with open(f, encoding="utf-8") as fh:
                keep = fh.readlines()[-10000:]
            with open(f, "w", encoding="utf-8") as fh:
                fh.writelines(keep)
        sid = (os.environ.get("KB_SESSION_ID")
               or os.environ.get("CLAUDE_SESSION_ID") or "nosession")
        with open(f, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "session": sid, "event": event, "detail": detail,
                "harness": harness}) + "\n")
    except Exception:
        pass

def frontmatter(path):
    """Parse the leading YAML block just enough: scalars + one-level lists."""
    meta, key = {}, None
    with open(path, encoding="utf-8") as fh:
        first = fh.readline()
        if first.strip() != "---":
            return {}
        for line in fh:
            if line.strip() == "---":
                break
            if line.startswith((" ", "\t")) and line.strip().startswith("- "):
                if key:
                    meta.setdefault(key, []).append(
                        line.strip()[2:].strip().strip('"'))
            elif ":" in line:
                k, v = line.split(":", 1)
                key = k.strip()
                v = v.split("#")[0].strip().strip('"')
                if v:
                    if v.startswith("[") and v.endswith("]"):
                        # flow-style list: anchors: [src/app.py, topic:x]
                        meta[key] = [x.strip().strip('"').strip("'")
                                     for x in v[1:-1].split(",") if x.strip()]
                    else:
                        meta[key] = v
                    key = None
    return meta

def collect(kbroot):
    facts = []
    for root, dirs, files in os.walk(kbroot):
        dirs[:] = [d for d in dirs if d not in {".git", "derived"}]
        for f in sorted(files):
            if not f.endswith(".md"):
                continue
            p = os.path.join(root, f)
            meta = frontmatter(p)
            anchors = meta.get("anchors") or []
            if isinstance(anchors, str):
                anchors = [anchors]
            if anchors:
                facts.append((os.path.relpath(p, kbroot), meta, anchors))
    return facts

def match(anchors, files, topics):
    hits = []
    for a in anchors:
        if a.startswith("topic:"):
            if a[6:] in topics:
                hits.append(a)
        else:
            for f in files:
                if f.startswith(a.rstrip("/")) or a.startswith(f.rstrip("/")):
                    hits.append(a)
                    break
    return hits

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--files", nargs="*", default=[],
                    help="repo-relative paths you are about to touch")
    ap.add_argument("--topic", action="append", default=[],
                    help="topic slug (repeatable)")
    ap.add_argument("--all", action="store_true",
                    help="also list facts with no matching anchors")
    ap.add_argument("--lanes", default="",
                    help="comma-separated KB lanes to include, e.g. normative "
                         "or normative,inferred (default: all lanes)")
    ap.add_argument("--gate-check", action="store_true",
                    help="recall-gate mode: exit 3 if any ratified/"
                         "ratified-partial fact matches, else exit 0")
    ap.add_argument("--harness", default="cli",
                    help="who is invoking recall (claude-hook, claude-skill, "
                         "opencode, codex, cli) — tags the recall_ran event")
    ap.add_argument("--coverage-count", action="store_true",
                    help="print '<files-with-coverage> <files-checked>' and "
                         "exit — commit-side recall_eligible proxy")
    args = ap.parse_args()
    if not args.files and not args.topic:
        sys.exit("give --files and/or --topic")
    kbroot = os.path.dirname(os.path.abspath(args.config))
    files = [f.lstrip("./") for f in args.files]
    lanes = [l.strip() for l in args.lanes.split(",") if l.strip()]

    facts = collect(kbroot)

    if args.coverage_count:
        # Internal query (no telemetry): per-file any-lane coverage count,
        # consumed by the pre-commit recall_eligible proxy (Part B).
        cov = sum(1 for f in files
                  if any(match(a, [f], set(args.topic)) for _, _, a in facts))
        print(cov, len(files))
        return

    matched, unmatched = [], []
    for kbf, meta, anchors in facts:
        if lanes and not any(kbf.startswith(f"kb/{l}/") for l in lanes):
            continue
        hits = match(anchors, files, set(args.topic))
        status = (meta.get("status") or meta.get("ruling") or "?").split()[0]
        row = (RANK.get(status, 9), kbf, status, hits)
        (matched if hits else unmatched).append(row)

    matched.sort()
    if not matched:
        print("NO KB COVERAGE for the given loci — the palace has no room here.")
        print("Elicit intent or run archaeology before building on this ground.")
    for _, kbf, status, hits in matched:
        print(f"[{status:<20}] {kbf}   <- {', '.join(hits)}")
    if args.all and unmatched:
        print("\n(no anchor match:)")
        for _, kbf, status, _ in sorted(unmatched):
            print(f"[{status:<20}] {kbf}")

    if args.gate_check:
        # Gate fires only on founder-granted trust (rank <= 1: ratified,
        # ratified-partial, ruled). Demoted/pending facts never deny an edit.
        # Internal query — no recall_ran self-log: the gate hook records the
        # delivery as recall_gate_block; logging both would double-count.
        sys.exit(3 if any(r[0] <= 1 for r in matched) else 0)

    if matched:
        log_telemetry(kbroot, "recall_ran", " ".join(files)[:200], args.harness)

if __name__ == "__main__":
    main()
