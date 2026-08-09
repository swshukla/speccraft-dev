#!/usr/bin/env python3
"""HIGH-debt forcing function.

Reads FINDINGS.md and refuses to advance the pin while open HIGH findings exceed
the count ceiling or age limit. Single source of debt policy; used by the
pre-commit hook (enforcement), kb-briefing.sh (banner), and the ratify flow.
"""
import argparse
import os
import subprocess
import sys
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drift import load_config

FINDINGS = os.path.join("findings", "FINDINGS.md")
INVENTORY = os.path.join("kb", "derived", "inventory.md")
WAIVERS = os.path.join("ledger", "DEBT-WAIVERS.md")


def _table_rows(text):
    """Yield findings-table rows as dicts keyed by lowercased header cell."""
    header = None
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if header is None:
            header = [c.lower() for c in cells]
            continue
        if set("".join(cells)) <= set("-: "):   # separator row
            continue
        yield dict(zip(header, cells))


def open_high(kbroot):
    path = os.path.join(kbroot, FINDINGS)
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    return [r for r in _table_rows(text)
            if r.get("sev", "").lower() == "high"
            and r.get("status", "").lower() in ("proposed", "confirmed")]


def _age_days(raised):
    try:
        return (date.today() - date.fromisoformat(raised)).days
    except (ValueError, TypeError):
        return None


def verdict(kbroot, ceiling, max_age):
    highs = open_high(kbroot)
    count = len(highs)
    dated = [(_age_days(r.get("raised", "")), r.get("id", "?")) for r in highs]
    dated = [(a, i) for a, i in dated if a is not None]
    oldest = max(dated) if dated else None
    reasons = []
    if count > ceiling:
        reasons.append(f"{count} open HIGH findings > ceiling {ceiling}")
    if oldest and oldest[0] > max_age:
        reasons.append(f"{oldest[1]} open {oldest[0]}d > max-age {max_age}d")
    return {"blocked": bool(reasons), "count": count, "oldest": oldest,
            "ids": [r.get("id", "?") for r in highs], "reasons": reasons}


def banner(v):
    if v["count"] == 0:
        return "✓ 0 open HIGH findings"
    o = v["oldest"]
    agestr = f", oldest {o[1]}, {o[0]}d" if o else ""
    if v["blocked"]:
        return (f"⛔ {v['count']} open HIGH findings{agestr} — pin advance "
                f"BLOCKED ({'; '.join(v['reasons'])})")
    return f"✓ {v['count']} open HIGH finding(s){agestr} — within ceiling"


def _source_commit(path):
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("source_commit:"):
                return line.split(":", 1)[1].strip()
    return ""


def waive(kbroot, reason, repo):
    new = _source_commit(os.path.join(kbroot, INVENTORY))
    old = "unknown"
    try:
        prev = subprocess.run(
            ["git", "-C", repo, "show", "HEAD:.speccraft/kb/derived/inventory.md"],
            capture_output=True, text=True, check=True).stdout
        for line in prev.splitlines():
            if line.startswith("source_commit:"):
                old = line.split(":", 1)[1].strip()
    except Exception:
        pass
    ids = ", ".join(r.get("id", "?") for r in open_high(kbroot)) or "(none)"
    line = f'- {date.today().isoformat()}  pin {old}->{new}  deferred: {ids}  — reason: "{reason}"\n'
    wpath = os.path.join(kbroot, WAIVERS)
    new_file = not os.path.exists(wpath)
    with open(wpath, "a", encoding="utf-8") as fh:
        if new_file:
            fh.write("# Debt waivers — append-only. Each line authorizes one "
                     "pin advance past open HIGH debt.\n\n")
        fh.write(line)
    return new


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--banner", action="store_true")
    g.add_argument("--waive", metavar="REASON")
    args = ap.parse_args()

    cfg = load_config(args.config)
    kbroot = os.path.dirname(os.path.abspath(args.config))
    ceiling = int(cfg.get("high_debt_ceiling", "3") or "3")
    max_age = int(cfg.get("high_debt_max_age_days", "14") or "14")

    if args.waive is not None:
        new = waive(kbroot, args.waive, os.path.expanduser(cfg.get("repo", ".")))
        print(f"waived: pin {new} — open HIGH debt logged to ledger/DEBT-WAIVERS.md")
        return 0

    v = verdict(kbroot, ceiling, max_age)
    if args.banner:
        print(banner(v))
        return 0
    if v["blocked"]:
        sys.stderr.write("HIGH-debt gate BLOCKED pin advance:\n")
        for r in v["reasons"]:
            sys.stderr.write(f"  - {r}\n")
        sys.stderr.write(f"  open HIGH: {', '.join(v['ids'])}\n")
        sys.stderr.write('  fix them, or record a waiver: '
                         'gate.py --config <cfg> --waive "reason"\n')
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
