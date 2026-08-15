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
        return []                       # no findings file = no debt (clear)
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    header = None
    highs = []
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if header is None:
            header = [c.lower() for c in cells]
            continue
        if set("".join(cells)) <= set("-: "):       # separator row
            continue
        if len(cells) != len(header):               # misaligned data row = corrupt
            raise ValueError(
                f"FINDINGS.md row has {len(cells)} cells, expected {len(header)}")
        row = dict(zip(header, cells))
        if (row.get("sev", "").lower() == "high"
                and row.get("status", "").lower() in ("proposed", "confirmed")):
            highs.append(row)
    return highs


def _age_days(raised):
    try:
        return (date.today() - date.fromisoformat(raised)).days
    except (ValueError, TypeError):
        return None


def verdict(kbroot, ceiling, max_age):
    try:
        highs = open_high(kbroot)
    except ValueError as e:
        return {"blocked": True, "count": -1, "oldest": None, "ids": [],
                "reasons": [f"FINDINGS.md unparseable ({e}) — failing closed"]}
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


def banner(v, unreviewed):
    debt = v["count"] if v["count"] >= 0 else "?"
    if unreviewed == 0 and not v["blocked"] and v["count"] == 0:
        return "✓ KB caught up — 0 open HIGH findings"
    parts = []
    if unreviewed:
        parts.append(f"{unreviewed} commit(s) unreviewed")
    if v["count"]:
        o = v["oldest"]
        parts.append(f"{debt} open HIGH" + (f" (oldest {o[1]}, {o[0]}d)" if o else ""))
    tail = " — ratify BLOCKED" if v["blocked"] else " — ratify to catch up"
    icon = "⛔" if v["blocked"] else "⚠"
    return f"{icon} KB behind: " + " · ".join(parts) + tail


def _inv(kbroot):
    """Return (source_commit, ratified_through) from inventory.md ('' if absent)."""
    path = os.path.join(kbroot, INVENTORY)
    src = rat = ""
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("source_commit:"):
                    src = line.split(":", 1)[1].strip()
                elif line.startswith("ratified_through:"):
                    rat = line.split(":", 1)[1].strip()
    return src, rat


def _unreviewed(repo, ratified, source):
    if not ratified or not source or ratified == source:
        return 0
    try:
        out = subprocess.run(["git", "-C", repo, "rev-list", "--count",
                              f"{ratified}..{source}"], capture_output=True,
                             text=True, encoding="utf-8", errors="replace",
                             check=True).stdout.strip()
        return int(out or "0")
    except Exception:
        return 0


def waive(kbroot, reason, repo):
    _src, new = _inv(kbroot)                       # advancing ratified_through
    old = "unknown"
    try:
        prev = subprocess.run(["git", "-C", repo, "show",
                               "HEAD:.speccraft/kb/derived/inventory.md"],
                              capture_output=True, text=True, encoding="utf-8",
                              errors="replace", check=True).stdout
        for line in prev.splitlines():
            if line.startswith("ratified_through:"):
                old = line.split(":", 1)[1].strip()
    except Exception:
        pass
    try:
        ids = ", ".join(r.get("id", "?") for r in open_high(kbroot)) or "(none)"
    except ValueError:
        ids = "(unparseable)"
    line = f'- {date.today().isoformat()}  ratified_through {old}->{new}  deferred: {ids}  — reason: "{reason}"\n'
    wpath = os.path.join(kbroot, WAIVERS)
    os.makedirs(os.path.dirname(wpath), exist_ok=True)          # I1
    new_file = not os.path.exists(wpath)
    with open(wpath, "a", encoding="utf-8") as fh:
        if new_file:
            fh.write("# Debt waivers — append-only. Each line authorizes one "
                     "ratified_through advance past open HIGH debt.\n\n")
        fh.write(line)
    try:
        subprocess.run(["git", "-C", repo, "add", "--",
                        ".speccraft/ledger/DEBT-WAIVERS.md"], check=False)  # I2
    except Exception:
        pass
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

    src, rat = _inv(kbroot)
    repo = os.path.expanduser(cfg.get("repo", "."))
    if args.waive is not None:
        new = waive(kbroot, args.waive, repo)
        print(f"waived: ratified_through {new} — open HIGH debt logged to ledger/DEBT-WAIVERS.md")
        return 0

    v = verdict(kbroot, ceiling, max_age)
    if args.banner:
        print(banner(v, _unreviewed(repo, rat, src)))
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
