#!/usr/bin/env python3
"""One-time: add a `Raised` (YYYY-MM-DD) column to an installed FINDINGS.md and
backfill each row's date from the first commit that introduced its BUG id
(fallback: the pin commit date; final fallback: today). Idempotent."""
import argparse
import os
import re
import subprocess
import sys
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drift import load_config

BUG = re.compile(r"BUG-\d+")


def _git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args],
                          capture_output=True, text=True).stdout.strip()


def _raised_for(repo, findings_rel, bug_id, fallback):
    out = _git(repo, "log", "-S", bug_id, "--reverse", "--format=%ad",
               "--date=short", "--", findings_rel)
    first = out.splitlines()[0] if out else ""
    return first or fallback


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    args = ap.parse_args()
    cfg = load_config(args.config)
    kbroot = os.path.dirname(os.path.abspath(args.config))
    path = os.path.join(kbroot, "findings", "FINDINGS.md")
    if not os.path.exists(path):
        print("no FINDINGS.md — nothing to migrate")
        return 0
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    # locate the header row; bail if Raised already present
    hdr_i = next((i for i, ln in enumerate(lines)
                  if ln.startswith("| ID ") and "Sev" in ln), None)
    if hdr_i is None:
        print("no findings table header found")
        return 0
    if "Raised" in lines[hdr_i]:
        print("Raised column already present — no-op")
        return 0

    repo = _git(kbroot, "rev-parse", "--show-toplevel") or os.path.expanduser(cfg.get("repo", "."))
    findings_rel = os.path.relpath(path, repo)
    # pin-date fallback
    pin = ""
    inv = os.path.join(kbroot, "kb", "derived", "inventory.md")
    if os.path.exists(inv):
        for ln in open(inv, encoding="utf-8"):
            if ln.startswith("source_commit:"):
                pin = ln.split(":", 1)[1].strip()
    pin_date = _git(repo, "show", "-s", "--format=%ad", "--date=short", pin) if pin else ""
    fallback = pin_date or date.today().isoformat()

    def insert_after_sev(cells, value):
        # cells are the between-pipe fields; Sev is index 1 (ID=0, Sev=1)
        return cells[:2] + [value] + cells[2:]

    out = []
    for i, ln in enumerate(lines):
        if not ln.startswith("|"):
            out.append(ln)
            continue
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        if i == hdr_i:
            out.append("| " + " | ".join(insert_after_sev(cells, "Raised")) + " |")
        elif set("".join(cells)) <= set("-: "):          # separator row
            out.append("| " + " | ".join(insert_after_sev(cells, "------")) + " |")
        else:
            m = BUG.search(cells[0]) if cells else None
            raised = _raised_for(repo, findings_rel, m.group(0), fallback) if m else fallback
            out.append("| " + " | ".join(insert_after_sev(cells, raised)) + " |")

    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    print(f"migrated {path}: added Raised column")
    return 0


if __name__ == "__main__":
    sys.exit(main())
