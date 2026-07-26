#!/usr/bin/env python3
"""kb-forge dep-diff — correlate dependency version changes with gotcha cards
(spec 2026-07-25-dep-diff.md rev 2).

drift.py reports THAT manifests changed; this answers the follow-up: what
exactly moved in the deps, and which version-pinned knowledge does that
affect? Reads the pinned version table from kb/derived/dependencies.md (the
deps0 output), re-runs the deps0 PARSERS against the working tree (== HEAD
in the post-commit ship loop), diffs, and scans
kb/inferred/09-dependency-practices.md for cards mentioning changed packages.

Contract: imports deps0's parsers only — NEVER deps0.audit(). The advisory
scanners are networked and slow; they have no place in the per-commit path
(advisory refresh is a scheduled deps0 run, not this script).

Queue tiering (--queue): items only for findings that are founder WORK —
card-matched changes (the cards may now be wrong) and RISK-tagged
new/changed packages. Routine bumps stay report-only.

Usage: python3 dep-diff.py --config /path/to/.speccraft/kbforge.yaml [--queue]
"""
import argparse, os, re, sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from deps0 import (parse_pyproject, parse_requirements, parse_poetry_lock,
                   parse_package_json, parse_package_lock, find, RISK, sh)
from drift import load_config, pinned_sha, last_code_commit

MANIFESTS = {"requirements.txt", "pyproject.toml", "poetry.lock",
             "package.json", "package-lock.json", "pnpm-lock.yaml"}
PIN_LINE = re.compile(r"^- `([^`]+)` @ \*\*([^*]+)\*\*")
CARDS = "kb/inferred/09-dependency-practices.md"

def pinned_table(kbroot):
    """{(section, name): version} from kb/derived/dependencies.md."""
    path = os.path.join(kbroot, "kb", "derived", "dependencies.md")
    table, section = {}, ""
    if not os.path.exists(path):
        return table
    for line in open(path, encoding="utf-8"):
        if line.startswith("## "):
            # "## Python (runtime) (3)" — strip only the trailing count
            section = re.sub(r"\s*\(\d+\)\s*$", "", line[3:].strip())
        m = PIN_LINE.match(line.strip())
        if m and section:
            table[(section, m.group(1))] = m.group(2)
    return table

def head_table(repo):
    """Same shape as pinned_table, from the working tree via deps0 parsers."""
    py_direct, js_runtime, js_dev = [], [], []
    py_lock, js_lock = {}, {}
    for p in find(repo, {"pyproject.toml"}):
        py_direct += parse_pyproject(p)
    for p in find(repo, {"requirements.txt"}):
        py_direct += parse_requirements(p)
    for p in find(repo, {"poetry.lock"}):
        py_lock.update(parse_poetry_lock(p))
    for p in find(repo, {"package.json"}):
        r, d = parse_package_json(p)
        js_runtime += r; js_dev += d
    for p in find(repo, {"package-lock.json"}):
        js_lock.update(parse_package_lock(p))

    def resolve(name, spec, lock):
        return lock.get(name) or (spec.lstrip("^~>=<! ") if spec else "?")

    table = {}
    for name, spec in py_direct:
        table[("Python (runtime)", name)] = resolve(name, spec, py_lock)
    for name, spec in js_runtime:
        table[("JavaScript / Node (runtime)", name)] = resolve(name, spec, js_lock)
    for name, spec in js_dev:
        table[("JavaScript / Node (dev)", name)] = resolve(name, spec, js_lock)
    return table

def card_hits(kbroot, name):
    """Cards mentioning the package: backticked mention anywhere, or
    word-boundary match on HEADING lines only — prose-level substring
    matching false-positives on short names ('click')."""
    path = os.path.join(kbroot, CARDS)
    hits = []
    if not os.path.exists(path):
        return hits
    bt = re.compile(re.escape(f"`{name}`"), re.I)
    hd = re.compile(rf"^#+ .*\b{re.escape(name)}\b", re.I)
    for i, line in enumerate(open(path, encoding="utf-8"), 1):
        if bt.search(line) or hd.match(line):
            hits.append((i, line.strip().lstrip("#").strip()[:80]))
    return hits

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--queue", action="store_true")
    args = ap.parse_args()
    cfg = load_config(args.config)
    repo = os.path.expanduser(cfg["repo"])
    kbroot = os.path.dirname(os.path.abspath(args.config))
    pin = pinned_sha(kbroot)
    head = last_code_commit(repo)

    # Early exit — one git call in the common case: no manifest moved.
    changed = sh(["git", "diff", "--name-only", f"{pin}..{head}", "--", ".",
                  ":(exclude).speccraft"], repo).splitlines()
    if not any(os.path.basename(f) in MANIFESTS for f in changed):
        return

    old, new = pinned_table(kbroot), head_table(repo)
    if not old:
        print("dep-diff: no pinned table (kb/derived/dependencies.md missing "
              "or empty) — run deps0.py to establish the baseline.")
        return

    changed_pkgs = [(k, old[k], new[k]) for k in sorted(old.keys() & new.keys())
                    if old[k] != new[k]]
    added_pkgs = sorted(new.keys() - old.keys())
    removed_pkgs = sorted(old.keys() - new.keys())
    if not (changed_pkgs or added_pkgs or removed_pkgs):
        return   # manifest touched but no version movement (comments, etc.)

    print(f"=== DEPENDENCY DIFF (pin {pin} → HEAD {head}) ===\n")
    queue_items = []   # (pkg, line) — card-matched or risk-tagged only

    print(f"CHANGED VERSIONS ({len(changed_pkgs)}):")
    for (sec, name), o, n in changed_pkgs:
        risk = "  ⚠risk" if RISK.search(name) else ""
        print(f"  {name}  {o} → {n}{risk}   [{sec}]")
        hits = card_hits(kbroot, name)
        if hits:
            print(f"    → {CARDS} mentions `{name}`:")
            for ln, txt in hits[:5]:
                print(f"      - \"{txt}\" (line {ln})")
        elif not risk:
            print(f"    (no gotcha cards reference {name})")
        if hits or risk:
            what = f"`{name}` {o} → {n}"
            why = (f"re-verify card(s) at line(s) "
                   f"{', '.join(str(l) for l, _ in hits[:5])}" if hits
                   else "risk-tagged, no gotcha coverage — consider a card")
            queue_items.append(f"- [ ] dep-diff: {what} — {why} in `{CARDS}`")

    print(f"\nNEW PACKAGES ({len(added_pkgs)}):")
    for sec, name in added_pkgs:
        risk = "  ⚠risk" if RISK.search(name) else ""
        print(f"  {name}  {new[(sec, name)]}{risk}   [{sec}]")
        if risk:
            queue_items.append(
                f"- [ ] dep-diff: new risk-tagged package `{name}` "
                f"@ {new[(sec, name)]} — no gotcha coverage yet; review and "
                f"consider a card in `{CARDS}`")

    print(f"\nREMOVED PACKAGES ({len(removed_pkgs)}):")
    for sec, name in removed_pkgs:
        print(f"  {name}  (was {old[(sec, name)]})   [{sec}]")
        hits = card_hits(kbroot, name)
        if hits:
            queue_items.append(
                f"- [ ] dep-diff: `{name}` removed — card(s) at line(s) "
                f"{', '.join(str(l) for l, _ in hits[:5])} in `{CARDS}` may "
                f"be obsolete")

    print(f"\nRun deps0.py to re-pin the dependency inventory, then update "
          f"cards for changed packages in {CARDS}.")

    if args.queue and queue_items:
        now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        with open(os.path.join(kbroot, "QUEUE.md"), "a", encoding="utf-8") as fh:
            fh.write(f"\n## Dependency drift — dep-diff run {now} ({pin}→{head})\n\n")
            for item in queue_items:
                fh.write(item + "\n")
        print(f"\nAppended {len(queue_items)} item(s) to QUEUE.md "
              f"({len(changed_pkgs) + len(added_pkgs) + len(removed_pkgs) - len(queue_items)} "
              f"routine change(s) kept report-only)")

if __name__ == "__main__":
    main()
