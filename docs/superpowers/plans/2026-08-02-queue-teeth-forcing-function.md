# Queue Teeth — HIGH-Debt Forcing Function — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refuse advancing the KB pin while open HIGH-severity findings exceed a count ceiling or age limit, escapable only via a logged waiver — with a SessionStart debt banner.

**Architecture:** A new stdlib `gate.py` parses `FINDINGS.md`, computes open-HIGH count + oldest age, and exposes three modes: `--check` (exit 0/1), `--banner` (print one line), `--waive "reason"` (append an audit line to `ledger/DEBT-WAIVERS.md`). The gate is enforced at the git layer by the existing `session-kit/pre-commit` hook (in its `KB_RATIFY` branch, when a commit changes `source_commit:`), honored via the waiver; surfaced at every SessionStart by `kb-briefing.sh`; and described for the human flow in the `ratify`/`diverge` skills. A `Raised` date column on findings (git-history backfill) enables the age dimension.

**Tech Stack:** Python 3.9+ (stdlib only), POSIX sh/bash hooks, the existing `session-kit/evals/` bash test harness.

## Global Constraints

- **Python ≥ 3.9, stdlib only — no new dependencies (no pytest, no PyYAML).** All file IO uses `encoding="utf-8"`.
- **Config parsing:** reuse the existing flat `load_config` — `gate.py` does `from drift import load_config` (exactly as `decay.py` does at `decay.py:24`). New keys read with the guarded idiom: `int(cfg.get("high_debt_ceiling", "3") or "3")` and `int(cfg.get("high_debt_max_age_days", "14") or "14")`. **Defaults: ceiling 3, max-age 14 days.**
- **Import stanza (copy verbatim into `gate.py`, adjusting nothing):**
  ```python
  sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
  from drift import load_config
  ```
  (Only the first hop is needed — `gate.py` does not import the `speccraft.forge` package.)
- **Invocation convention:** scripts run as `python3 <forge>/gate.py --config <kbroot>/kbforge.yaml [...]`, where `<forge>` = `kb-forge/speccraft/forge` and `kbroot = os.path.dirname(os.path.abspath(args.config))`.
- **The git commit chokepoint is `session-kit/pre-commit`** (POSIX sh, no extension) — NOT `kb-guard.sh` (which is the earlier PreToolUse layer). Advancing the pin already requires `KB_RATIFY=1` (inventory.md is under the hard-blocked `kb/derived/` path), so the gate goes inside `pre-commit`'s existing `KB_RATIFY` branch.
- **FINDINGS.md schema (after this phase):** `| ID | Sev | Raised | Finding | Evidence (@pin) | Source | Status |`. **Open HIGH finding** = `Sev=High` AND `Status ∈ {proposed, confirmed}`. `gate.py` parses the table by **header name** (not column position), so it is robust to column order.
- **Waiver line format (single-sourced, ASCII `->` for grep-safety):**
  `- <YYYY-MM-DD>  pin <old>-><new>  deferred: BUG-003, BUG-004  — reason: "<reason>"`
  Location: `.speccraft/ledger/DEBT-WAIVERS.md` (append-only).
- **Test suite:** a new `session-kit/evals/test-queue-teeth.sh`, styled exactly like `test-queue-split.sh` (`set -euo pipefail`, own `pass`/`fail`, `ok()`/`bad()`), ending with `echo "queue-teeth: $pass passed, $fail failed"` then `[ "$fail" -eq 0 ]`. Wired into `self-test.sh` as a new `queueteeth` section modeled on the `queuesplit` section (`self-test.sh:388-400`).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `gate.py` | Parse FINDINGS.md; `--check`/`--banner`/`--waive`; the single source of debt policy | **Create** |
| `migrate_findings_raised.py` | One-time backfill of the `Raised` column from git history | **Create** |
| `session-kit/evals/test-queue-teeth.sh` | The bash suite for the above | **Create** |
| `session-kit/pre-commit` | In the `KB_RATIFY` branch: gate on `source_commit` change, honor waiver | **Modify** |
| `session-kit/hooks/kb-briefing.sh` | HIGH-debt banner as the first briefing line | **Modify** |
| `session-kit/skills/speccraft-diverge/SKILL.md` | Stamp `Raised` when appending a finding | **Modify** |
| `session-kit/skills/speccraft-ratify/SKILL.md` | Run gate before pin advance; preserve `Raised`; `--accept-debt` → `gate.py --waive` | **Modify** |
| `session-kit/evals/self-test.sh` | Wire in the `queueteeth` section | **Modify** |
| `SPEC.md` | Document the two new `kbforge.yaml` keys + the `Raised` column | **Modify** |

---

## Task 1: `gate.py` — the HIGH-debt policy (check / banner / waive)

**Files:**
- Create: `gate.py`
- Create: `session-kit/evals/test-queue-teeth.sh`

**Interfaces:**
- Consumes: `load_config` (from `drift.py`); reads `FINDINGS.md`, `kb/derived/inventory.md`.
- Produces (CLI, all take `--config <cfg>`):
  - default `--check` → exit `0` clear / `1` blocked (reasons to stderr)
  - `--banner` → prints one status line, exit `0`
  - `--waive "REASON"` → appends a waiver line to `ledger/DEBT-WAIVERS.md`, prints confirmation, exit `0`
- Produces (functions, for reuse/testing): `verdict(kbroot, ceiling, max_age) -> dict` with keys `blocked, count, oldest, ids, reasons`; `banner(v) -> str`.

- [ ] **Step 1: Write the failing test**

Create `session-kit/evals/test-queue-teeth.sh`:

```bash
#!/usr/bin/env bash
# Phase-1 HIGH-debt forcing-function assertions. Standalone or via self-test.sh.
set -euo pipefail
FORGE="$(cd "$(dirname "$0")/../.." && pwd)"   # .../speccraft/forge
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# --- fixture builder: a .speccraft with FINDINGS.md + kbforge.yaml + inventory ---
mkkb() {  # $1=dir  $2=ceiling  $3=max_age
  local kb="$1"; mkdir -p "$kb/findings" "$kb/kb/derived" "$kb/ledger"
  printf 'repo: %s\nhigh_debt_ceiling: %s\nhigh_debt_max_age_days: %s\n' "$TMP" "$2" "$3" > "$kb/kbforge.yaml"
  printf 'source_commit: abc1234\n' > "$kb/kb/derived/inventory.md"
  {
    echo '| ID | Sev | Raised | Finding | Evidence (@pin) | Source | Status |'
    echo '|----|-----|--------|---------|-----------------|--------|--------|'
  } > "$kb/findings/FINDINGS.md"
}
addrow() { # $1=kb $2=id $3=sev $4=raised $5=status
  echo "| $2 | $3 | $4 | some finding | ev | src | $5 |" >> "$1/findings/FINDINGS.md"
}
TODAY="$(date +%F)"
OLD="$(python3 -c "import datetime;print((datetime.date.today()-datetime.timedelta(days=30)).isoformat())")"

echo "== gate: clear when within ceiling and young =="
KB="$TMP/clear"; mkkb "$KB" 3 14
addrow "$KB" BUG-001 High "$TODAY" proposed
python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" && ok "clear exits 0" || bad "clear exits 0"

echo "== gate: count block =="
KB="$TMP/cnt"; mkkb "$KB" 1 14
addrow "$KB" BUG-001 High "$TODAY" proposed
addrow "$KB" BUG-002 High "$TODAY" confirmed
python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" 2>/dev/null && bad "count block exits 1" || ok "count block exits 1"

echo "== gate: age block =="
KB="$TMP/age"; mkkb "$KB" 5 14
addrow "$KB" BUG-001 High "$OLD" proposed
python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" 2>/dev/null && bad "age block exits 1" || ok "age block exits 1"

echo "== gate: Med/Low never block, fixed/dismissed excluded =="
KB="$TMP/ml"; mkkb "$KB" 0 14
addrow "$KB" BUG-001 Med "$OLD" proposed
addrow "$KB" BUG-002 Low "$OLD" confirmed
addrow "$KB" BUG-003 High "$OLD" fixed
addrow "$KB" BUG-004 High "$OLD" dismissed
python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" && ok "non-open-HIGH never blocks" || bad "non-open-HIGH never blocks"

echo "== banner lines =="
KB="$TMP/ban"; mkkb "$KB" 1 14
addrow "$KB" BUG-001 High "$OLD" proposed
addrow "$KB" BUG-002 High "$TODAY" proposed
python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" --banner | grep -q 'BLOCKED' && ok "banner shows BLOCKED" || bad "banner shows BLOCKED"
KB="$TMP/ban2"; mkkb "$KB" 3 14
python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" --banner | grep -q '0 open HIGH' && ok "banner shows none" || bad "banner shows none"

echo "== waive appends a well-formed line =="
KB="$TMP/wv"; mkkb "$KB" 0 14
addrow "$KB" BUG-001 High "$OLD" proposed
printf 'source_commit: def5678\n' > "$KB/kb/derived/inventory.md"
python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" --waive "shipping launch" >/dev/null
grep -qE '^- [0-9]{4}-[0-9]{2}-[0-9]{2}  pin .*->def5678  deferred: BUG-001  — reason: "shipping launch"' "$KB/ledger/DEBT-WAIVERS.md" \
  && ok "waiver line well-formed" || bad "waiver line well-formed"

echo "queue-teeth: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-queue-teeth.sh`
Expected: FAIL — `gate.py` does not exist yet (`python3 ... gate.py` errors).

- [ ] **Step 3: Write `gate.py`**

Create `gate.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-queue-teeth.sh`
Expected: PASS — `queue-teeth: 8 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/gate.py kb-forge/speccraft/forge/session-kit/evals/test-queue-teeth.sh
git commit -m "feat(speccraft): gate.py — HIGH-debt forcing function (check/banner/waive)"
```

---

## Task 2: `migrate_findings_raised.py` — backfill the `Raised` column

**Files:**
- Create: `migrate_findings_raised.py`
- Test: `session-kit/evals/test-queue-teeth.sh` (extend)

**Interfaces:**
- Consumes: `load_config`; an installed `FINDINGS.md`; the target repo's git history.
- Produces: rewrites `FINDINGS.md` in place — inserts a `Raised` header column after `Sev`, and stamps each existing data row with the date of the first commit that introduced its `BUG-NNN` id (fallback: the pin commit's date; final fallback: today). Idempotent (no-op if `Raised` already present).

- [ ] **Step 1: Write the failing test** (append to `test-queue-teeth.sh`, before the summary echo)

```bash
echo "== migrate: backfills Raised from git history, idempotent =="
MKB="$TMP/mig/.speccraft"; mkdir -p "$MKB/findings" "$MKB/kb/derived"
( cd "$TMP/mig" && git init -q && git config user.email t@t && git config user.name t )
printf 'source_commit: HEAD\n' > "$MKB/kb/derived/inventory.md"
printf 'repo: %s\n' "$TMP/mig" > "$MKB/kbforge.yaml"
# legacy FINDINGS.md with NO Raised column
{ echo '| ID | Sev | Finding | Evidence (@pin) | Source | Status |';
  echo '|----|-----|---------|-----------------|--------|--------|';
  echo '| BUG-001 | High | legacy row | ev | src | proposed |'; } > "$MKB/findings/FINDINGS.md"
( cd "$TMP/mig" && git add -A && GIT_AUTHOR_DATE='2026-07-01T00:00:00' GIT_COMMITTER_DATE='2026-07-01T00:00:00' git commit -qm "add finding BUG-001" )
python3 "$FORGE/migrate_findings_raised.py" --config "$MKB/kbforge.yaml"
head -1 "$MKB/findings/FINDINGS.md" | grep -q 'Raised' && ok "header gains Raised column" || bad "header gains Raised column"
grep -qE '\| BUG-001 \| High \| 2026-07-01 \|' "$MKB/findings/FINDINGS.md" && ok "row stamped from git history" || bad "row stamped from git history"
# idempotent: second run doesn't double-add
BEFORE="$(cat "$MKB/findings/FINDINGS.md")"
python3 "$FORGE/migrate_findings_raised.py" --config "$MKB/kbforge.yaml"
[ "$BEFORE" = "$(cat "$MKB/findings/FINDINGS.md")" ] && ok "migration idempotent" || bad "migration idempotent"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-queue-teeth.sh`
Expected: FAIL — `migrate_findings_raised.py` does not exist.

- [ ] **Step 3: Write `migrate_findings_raised.py`**

Create `migrate_findings_raised.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-queue-teeth.sh`
Expected: PASS — includes the 3 new migration assertions.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/migrate_findings_raised.py kb-forge/speccraft/forge/session-kit/evals/test-queue-teeth.sh
git commit -m "feat(speccraft): migrate_findings_raised.py — backfill Raised column from git history"
```

---

## Task 3: `session-kit/pre-commit` — enforce the gate on pin advance

**Files:**
- Modify: `session-kit/pre-commit` (inside the `KB_RATIFY` branch)
- Test: `session-kit/evals/test-queue-teeth.sh` (extend)

**Interfaces:**
- Consumes: `gate.py --check`, a staged `DEBT-WAIVERS.md` naming the new pin.
- Produces: a `KB_RATIFY=1` commit that advances `source_commit` is refused when the gate blocks, unless a staged waiver line names the new pin.

**Context:** Read `session-kit/pre-commit`. Its `KB_RATIFY` branch currently only logs telemetry then `exit 0`. Find how it locates sibling forge scripts (it already invokes `recall.py` — reuse the SAME path variable it uses for that, call it `$FORGE` below) and how it references the KB dir (`$KB`).

- [ ] **Step 1: Write the failing test** (append to `test-queue-teeth.sh`)

```bash
echo "== pre-commit: blocks pin advance under debt, waiver unblocks =="
G="$TMP/repo"; SP="$G/.speccraft"
mkdir -p "$SP/findings" "$SP/kb/derived" "$SP/ledger"
( cd "$G" && git init -q && git config user.email t@t && git config user.name t )
printf 'repo: %s\nhigh_debt_ceiling: 0\nhigh_debt_max_age_days: 14\n' "$G" > "$SP/kbforge.yaml"
printf 'source_commit: aaaaaaa\n' > "$SP/kb/derived/inventory.md"
{ echo '| ID | Sev | Raised | Finding | Evidence (@pin) | Source | Status |';
  echo '|----|-----|--------|---------|-----------------|--------|--------|';
  echo "| BUG-001 | High | $(date +%F) | x | ev | src | proposed |"; } > "$SP/findings/FINDINGS.md"
cp "$FORGE/session-kit/pre-commit" "$G/.git/hooks/pre-commit"; chmod +x "$G/.git/hooks/pre-commit"
( cd "$G" && git add -A && KB_RATIFY=1 git commit -qm "seed" )   # seed commit (no source_commit change vs empty is fine)
# advance the pin -> should be BLOCKED (1 open HIGH > ceiling 0)
printf 'source_commit: bbbbbbb\n' > "$SP/kb/derived/inventory.md"
if ( cd "$G" && git add -A && KB_RATIFY=1 git commit -qm "advance pin" ) 2>/dev/null; then
  bad "pre-commit blocks pin advance under debt"
else
  ok "pre-commit blocks pin advance under debt"
fi
# now waive and retry -> allowed
python3 "$FORGE/gate.py" --config "$SP/kbforge.yaml" --waive "test waiver" >/dev/null
if ( cd "$G" && git add -A && KB_RATIFY=1 git commit -qm "advance pin (waived)" ) 2>/dev/null; then
  ok "waiver unblocks pin advance"
else
  bad "waiver unblocks pin advance"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-queue-teeth.sh`
Expected: FAIL on "pre-commit blocks pin advance under debt" — the unmodified hook lets the advance through.

- [ ] **Step 3: Add the gate to `pre-commit`'s `KB_RATIFY` branch**

Inside the existing `if [ -n "$KB_RATIFY" ]; then … fi` block, AFTER its telemetry logging and BEFORE its `exit 0`, insert (using the hook's existing `$FORGE` and `$KB` variables — match their real names in the file):

```sh
  # --- HIGH-debt gate: refuse advancing the pin while HIGH debt is over ceiling/age ---
  if git diff --cached -- "$KB/kb/derived/inventory.md" | grep -q '^+source_commit:'; then
    NEWPIN=$(git diff --cached -- "$KB/kb/derived/inventory.md" \
             | sed -nE 's/^\+source_commit:[[:space:]]*([^[:space:]]+).*/\1/p' | head -1)
    if ! python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" >/dev/null 2>&1; then
      if git diff --cached -- "$KB/ledger/DEBT-WAIVERS.md" | grep -qE "^\+.*->[[:space:]]*${NEWPIN}([[:space:]]|\$)"; then
        :   # a staged waiver names this new pin — authorized deferral
      else
        echo "pre-commit: HIGH-debt gate blocks advancing the pin to ${NEWPIN}." >&2
        python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" >&2 || true
        echo "  Fix the HIGH findings, or record a waiver:" >&2
        echo "  python3 $FORGE/gate.py --config $KB/kbforge.yaml --waive \"reason\"" >&2
        exit 1
      fi
    fi
  fi
```

If the hook's forge-path variable is not named `$FORGE`, substitute the actual variable it uses to call `recall.py`. If it derives the KB dir differently than `$KB`, match that.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-queue-teeth.sh`
Expected: PASS — blocks under debt, waiver unblocks.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/session-kit/pre-commit kb-forge/speccraft/forge/session-kit/evals/test-queue-teeth.sh
git commit -m "feat(speccraft): pre-commit refuses pin advance past HIGH debt (waiver-escapable)"
```

---

## Task 4: `kb-briefing.sh` — HIGH-debt banner

**Files:**
- Modify: `session-kit/hooks/kb-briefing.sh`
- Test: `session-kit/evals/test-queue-teeth.sh` (extend)

**Interfaces:**
- Consumes: `gate.py --banner`.
- Produces: the briefing's FIRST line is the HIGH-debt banner.

**Context:** `kb-briefing.sh` sets `KB="$ROOT/.speccraft"` (line 5) and prints an ordered block of `echo`s starting at line 43 (`=== KB BRIEFING ===`). It must locate `gate.py`; reuse whatever mechanism the hook already uses to reference forge scripts (or derive it as `$(dirname "$0")/..` = the forge dir). Guard so a missing `gate.py`/findings never breaks the SessionStart hook.

- [ ] **Step 1: Write the failing test** (append to `test-queue-teeth.sh`)

```bash
echo "== briefing: leads with HIGH-debt banner =="
BKB="$TMP/brief"; mkdir -p "$BKB/.speccraft/findings" "$BKB/.speccraft/kb/derived"
( cd "$BKB" && git init -q && git config user.email t@t && git config user.name t )
SP="$BKB/.speccraft"
printf 'repo: %s\nhigh_debt_ceiling: 0\nhigh_debt_max_age_days: 14\n' "$BKB" > "$SP/kbforge.yaml"
printf 'source_commit: %s\n' "$(cd "$BKB" && printf init > f && git add -A && git commit -qm i && git rev-parse --short HEAD)" > "$SP/kb/derived/inventory.md"
printf '# invariants\n' > /dev/null
mkdir -p "$SP/kb/normative"; printf '# INV\n' > "$SP/kb/normative/01-invariants.md"
{ echo '| ID | Sev | Raised | Finding | Evidence (@pin) | Source | Status |';
  echo '|----|-----|--------|---------|-----------------|--------|--------|';
  echo "| BUG-001 | High | $(date +%F) | x | ev | src | proposed |"; } > "$SP/findings/FINDINGS.md"
OUT="$(cd "$BKB" && bash "$FORGE/session-kit/hooks/kb-briefing.sh" 2>/dev/null)"
printf '%s\n' "$OUT" | head -1 | grep -q 'HIGH' && ok "briefing first line is HIGH-debt banner" || bad "briefing first line is HIGH-debt banner"
printf '%s\n' "$OUT" | grep -q 'BLOCKED' && ok "banner shows BLOCKED state" || bad "banner shows BLOCKED state"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-queue-teeth.sh`
Expected: FAIL — no HIGH-debt line in the briefing yet.

- [ ] **Step 3: Add the banner**

In `kb-briefing.sh`, before the first `echo "=== KB BRIEFING ===" ` (line ~43), compute and print the banner as the first output line. Resolve the forge dir (e.g. `FORGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"`) and guard it:

```sh
if [ -f "$KB/kbforge.yaml" ] && [ -f "$FORGE_DIR/gate.py" ]; then
  python3 "$FORGE_DIR/gate.py" --config "$KB/kbforge.yaml" --banner 2>/dev/null || true
fi
```

Place this line ABOVE the `=== KB BRIEFING ===` header echo so it leads the briefing. (If the hook already computes a forge-dir variable for another call, reuse it instead of `FORGE_DIR`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-queue-teeth.sh`
Expected: PASS — first line contains HIGH + BLOCKED.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/session-kit/hooks/kb-briefing.sh kb-forge/speccraft/forge/session-kit/evals/test-queue-teeth.sh
git commit -m "feat(speccraft): kb-briefing leads with HIGH-debt banner"
```

---

## Task 5: SKILL.md prose — diverge stamps `Raised`, ratify gates + waives

**Files:**
- Modify: `session-kit/skills/speccraft-diverge/SKILL.md`
- Modify: `session-kit/skills/speccraft-ratify/SKILL.md`

**Interfaces:**
- Consumes: the `Raised` column, `gate.py --check`/`--waive`.
- Produces: agent-followed procedures consistent with the code in Tasks 1–4.

- [ ] **Step 1: Update `speccraft-diverge/SKILL.md`**

Find the instruction to append a `proposed` `BUG-NNN` row to `FINDINGS.md`. Update it to the new 7-column schema and the stamp rule:

```markdown
Append the finding using the current schema — note the `Raised` column:

| ID | Sev | Raised | Finding | Evidence (@pin) | Source | Status |

Set `Raised` to today's date (`YYYY-MM-DD`) when you first append the row, and
NEVER change it afterwards — it is the "raised" date the HIGH-debt age gate reads.
Bump the `<!-- Next id: BUG-NNN … -->` marker as before.
```

- [ ] **Step 2: Update `speccraft-ratify/SKILL.md`**

(a) In the status-flip step, add: "Preserve the existing `Raised` value unchanged when flipping `Status` (proposed → confirmed/dismissed); only `Status` changes."

(b) In step 4 (advancing the `source_commit` pin), add BEFORE the advance:

```markdown
Before advancing the pin, run the HIGH-debt gate:

    python3 <forge>/gate.py --config <kbroot>/kbforge.yaml

If it exits 0, advance the pin as usual. If it BLOCKS (open HIGH findings over
the ceiling or aged past the limit), either fix those HIGH findings first, or —
if you are deliberately deferring — record a logged waiver, which authorizes this
one pin advance:

    python3 <forge>/gate.py --config <kbroot>/kbforge.yaml --waive "why you're deferring"

The waiver is appended to `ledger/DEBT-WAIVERS.md` (committed in this same
`KB_RATIFY=1` commit) and names the new pin + the deferred BUG ids — the audit
trail. The pre-commit hook enforces this: a pin advance under HIGH debt without a
matching waiver is refused.
```

- [ ] **Step 3: Verify (doc-only)**

Run: `grep -l 'Raised' kb-forge/speccraft/forge/session-kit/skills/speccraft-diverge/SKILL.md && grep -l 'gate.py' kb-forge/speccraft/forge/session-kit/skills/speccraft-ratify/SKILL.md`
Expected: both files listed. Eyeball that the `--waive` command and schema match Task 1/2 exactly.

- [ ] **Step 4: Commit**

```bash
git add kb-forge/speccraft/forge/session-kit/skills/speccraft-diverge/SKILL.md kb-forge/speccraft/forge/session-kit/skills/speccraft-ratify/SKILL.md
git commit -m "docs(speccraft): diverge stamps Raised; ratify runs HIGH-debt gate + waiver flow"
```

---

## Task 6: Wire into `self-test.sh` + document config keys

**Files:**
- Modify: `session-kit/evals/self-test.sh`
- Modify: `SPEC.md`

**Interfaces:**
- Consumes: `test-queue-teeth.sh`.
- Produces: `self-test.sh` runs the teeth suite and folds its counts; `SPEC.md` documents the two new `kbforge.yaml` keys and the `Raised` column.

- [ ] **Step 1: Add the `queueteeth` section to `self-test.sh`**

Modeled on the `queuesplit` section (`self-test.sh:388-400`), add:

```bash
if run_section queueteeth; then
  echo "== HIGH-debt forcing-function suite =="
  TOUT=$(bash "$HERE/test-queue-teeth.sh" 2>&1); TRC=$?
  printf '%s\n' "$TOUT"
  TP=$(printf '%s' "$TOUT" | grep -Eo '[0-9]+ passed' | tail -1 | grep -Eo '[0-9]+')
  TF=$(printf '%s' "$TOUT" | grep -Eo '[0-9]+ failed' | tail -1 | grep -Eo '[0-9]+')
  PASS=$((PASS + ${TP:-0})); FAIL=$((FAIL + ${TF:-0}))
  if [ "$TRC" -ne 0 ] && [ "${TF:-0}" -eq 0 ]; then
    no "queueteeth: test-queue-teeth.sh exited nonzero ($TRC)"
  fi
fi
```

Use the same `$HERE` / `run_section` / `no` names the file already defines.

- [ ] **Step 2: Run the full suite**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/self-test.sh`
Expected: PASS — prior total (148) plus the queue-teeth assertions, `0 failed`.

- [ ] **Step 3: Document the config keys + column in `SPEC.md`**

Find where `SPEC.md` describes `kbforge.yaml` (~line 31). Add:

```markdown
- `high_debt_ceiling` (default 3) — max open HIGH findings before a pin advance is
  refused. Set 0 for zero-tolerance.
- `high_debt_max_age_days` (default 14) — any open HIGH finding older than this
  (by its `Raised` date) refuses a pin advance.
```

And where it describes `FINDINGS.md`, note the `Raised` column (ISO date, stamped on
append, never changed) and that open HIGH findings gate pin advance (see `gate.py`).

- [ ] **Step 4: Verify**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/self-test.sh 2>&1 | tail -1`
Expected: `self-test: <N> passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/session-kit/evals/self-test.sh kb-forge/speccraft/forge/SPEC.md
git commit -m "test(speccraft): wire HIGH-debt suite into self-test; document config keys"
```

---

## Self-Review

**Spec coverage** (against `2026-08-02-queue-teeth-forcing-function-design.md`):
- §4.1 `Raised` column + backfill → Task 2 (migration), Task 5 (diverge stamp / ratify preserve) ✓
- §4.2 `gate.py` count+age, config defaults → Task 1 ✓
- §4.3 enforcement (ratify prose + pre-commit backstop) → Task 5 (prose) + Task 3 (pre-commit) ✓ — **correction:** the hard backstop lives in `session-kit/pre-commit`, not `kb-guard.sh` (the spec named the wrong file; `kb-guard.sh` is the PreToolUse layer). Task 3 uses the correct file.
- §4.4 logged override (`--waive` → `DEBT-WAIVERS.md`) → Task 1 (writer) + Task 3 (honored) + Task 5 (documented) ✓
- §4.5 debt banner → Task 4 ✓
- §5 tests → Task 1 (count/age/clear/med-low/status/banner/waive), Task 2 (backfill), Task 3 (pre-commit block+waiver), Task 4 (banner) ✓
- §6 files: `gate.py`, `migrate_findings_raised.py`, diverge/ratify SKILL, `kb-guard.sh`→corrected to `pre-commit`, `kb-briefing.sh`, FINDINGS schema (via SKILL prose + migration), `kbforge.yaml` keys (via `SPEC.md` docs + `gate.py` defaults), test suite, self-test wire-in ✓

**Placeholder scan:** the pre-commit/briefing forge-path variable is intentionally deferred to "match the hook's existing variable" because the exact name must be read from the file — flagged, not vague-in-code. No `TBD`/`add validation` placeholders. All code steps carry full code.

**Type consistency:** `verdict()` dict keys (`blocked, count, oldest, ids, reasons`) are used consistently in `banner()` and the CLI. Waiver format (`pin <old>-><new>`, ASCII `->`) is identical in `gate.py:waive` (Task 1) and the `pre-commit` grep (Task 3). `Raised` column position (after `Sev`) is identical in the migration (Task 2), the fixtures (Task 1), and the SKILL schema (Task 5).

---

## Execution Handoff

Plan complete. One deferred lookup (both flagged inline): the forge-path and KB-dir variable names inside `session-kit/pre-commit` and `kb-briefing.sh` — the implementer reads the actual variable each hook already uses (they invoke `recall.py`/reference `$KB` today) and matches it. Everything else is literal.

---

# REVISION (2026-08-09) — Split the anchor (`ratified_through`)

**Why:** the final whole-branch review found gating `source_commit` is defeated by the ship
loop (it re-pins every commit via `KB_SHIPLOOP`, bypassing `pre-commit` before the gate). See
the revised spec §0. Fix-forward on branch `worktree-queue-teeth` (current tip `7c1bbec`):
Tasks 1–2 (gate.py debt-compute, `Raised` migration) stand; the tasks below re-point the gate
from the mechanical pin to a new **trust boundary** and fold in the I1/I2/M1 escape-hatch fixes.

**Revised Global Constraints (additions):**
- Two anchors in `kb/derived/inventory.md`: `source_commit:` (mechanical, ship-loop, ungated)
  and `ratified_through:` (trust boundary, advanced only by gated `ratify`; init = `source_commit`).
- The gate guards advancing **`ratified_through`**, never `source_commit`.
- Waiver line format changes anchor name: `- <date>  ratified_through <old>-><new>  deferred: BUG-…  — reason: "…"`.
- All fixes preserve the bash test harness; each R-task updates `test-queue-teeth.sh` and ends green.

## Task R1: `seed0.py` — preserve `ratified_through` (+ init)

**Files:** Modify `seed0.py`; Test `session-kit/evals/test-queue-teeth.sh`.

**Context:** `seed0.py` rewrites derived-KB frontmatter (incl. `inventory.md`'s `source_commit:`)
on every ship-loop run. It must NOT clobber `ratified_through`. OPEN `seed0.py`, find where it
writes the `source_commit:` frontmatter (the `header()`/inventory writer, ~lines 56-62), and:
1. Before rewriting, READ the existing `ratified_through:` value from the current `inventory.md`
   (if present).
2. When writing the derived frontmatter, emit `ratified_through:` too — **preserving** the read
   value unchanged. If it was absent (legacy/first seed), initialize it to the NEW `source_commit`.
3. Only `inventory.md` needs the `ratified_through` field (it's the pin file); other derived files
   are unaffected.

- [ ] **Step 1: Failing test** (append to `test-queue-teeth.sh`, before the summary echo)

```bash
echo "== seed0 preserves ratified_through, inits if absent =="
SK="$TMP/seed/.speccraft"; mkdir -p "$SK/kb/derived"
( cd "$TMP/seed" && git init -q && git config user.email t@t && git config user.name t \
  && mkdir -p src && printf 'a\n' > src/f.py && git add -A && git commit -qm c1 )
printf 'repo: %s\n' "$TMP/seed" > "$SK/kbforge.yaml"
# inventory with an EXISTING ratified_through that must survive re-seed
printf 'source_commit: aaaaaaa\nratified_through: aaaaaaa\n' > "$SK/kb/derived/inventory.md"
( cd "$TMP/seed" && printf 'b\n' >> src/f.py && git add -A && git commit -qm c2 )
python3 "$FORGE/seed0.py" --config "$SK/kbforge.yaml" >/dev/null 2>&1 || true
grep -q '^ratified_through: aaaaaaa' "$SK/kb/derived/inventory.md" && ok "seed0 preserves ratified_through" || bad "seed0 preserves ratified_through"
grep -q '^source_commit:' "$SK/kb/derived/inventory.md" && ! grep -q '^source_commit: aaaaaaa' "$SK/kb/derived/inventory.md" && ok "seed0 advanced source_commit" || bad "seed0 advanced source_commit"
# init case: no ratified_through present -> set to new source_commit
printf 'source_commit: aaaaaaa\n' > "$SK/kb/derived/inventory.md"
python3 "$FORGE/seed0.py" --config "$SK/kbforge.yaml" >/dev/null 2>&1 || true
NEWSC=$(grep '^source_commit:' "$SK/kb/derived/inventory.md" | awk '{print $2}')
grep -q "^ratified_through: $NEWSC" "$SK/kb/derived/inventory.md" && ok "seed0 inits ratified_through=source_commit" || bad "seed0 inits ratified_through"
```

- [ ] **Step 2:** run → FAIL (seed0 doesn't write `ratified_through`).
- [ ] **Step 3:** make the seed0 edit per Context above (read the file; adapt to its real writer).
- [ ] **Step 4:** run → PASS.
- [ ] **Step 5:** commit `feat(speccraft): seed0 preserves ratified_through trust boundary`.

## Task R2: `gate.py` — two anchors, status banner, waive→`ratified_through`, I1/I2/M1

**Files:** Modify `gate.py`; Test `test-queue-teeth.sh`.

**Interfaces:** `verdict()` debt fields unchanged. Add anchor reads + status. `--banner` = two-anchor
KB status. `--waive` targets `ratified_through`, `makedirs` ledger, `git add`s the waiver. `--check`
fails **closed** on a corrupt FINDINGS.md.

Apply these concrete edits to the existing `gate.py`:

(a) Add an anchor reader and a status computer:
```python
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
                             text=True, check=True).stdout.strip()
        return int(out or "0")
    except Exception:
        return 0
```

(b) Make `open_high` fail **closed** on a corrupt FINDINGS.md (M1) — if the file exists but no
table header is found, signal corruption:
```python
def open_high(kbroot):
    path = os.path.join(kbroot, FINDINGS)
    if not os.path.exists(path):
        return []                      # no findings file = no debt (safe)
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    rows = list(_table_rows(text))
    if "| ID " in text and not any("sev" in r for r in rows):
        raise ValueError("FINDINGS.md table unparseable")   # fail closed
    return [r for r in rows
            if r.get("sev", "").lower() == "high"
            and r.get("status", "").lower() in ("proposed", "confirmed")]
```
and in `verdict()`, wrap the `open_high` call so corruption → blocked:
```python
def verdict(kbroot, ceiling, max_age):
    try:
        highs = open_high(kbroot)
    except ValueError as e:
        return {"blocked": True, "count": -1, "oldest": None, "ids": [],
                "reasons": [f"FINDINGS.md unparseable ({e}) — failing closed"]}
    # ... rest unchanged ...
```

(c) `--banner` — two-anchor status. Replace `banner(v)` with a version taking the anchors:
```python
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
```

(d) `--waive` — target `ratified_through`, makedirs (I1), git add (I2):
```python
def waive(kbroot, reason, repo):
    _src, new = _inv(kbroot)                       # advancing ratified_through
    old = "unknown"
    try:
        prev = subprocess.run(["git", "-C", repo, "show",
                               "HEAD:.speccraft/kb/derived/inventory.md"],
                              capture_output=True, text=True, check=True).stdout
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
```

(e) `main()` — wire the anchor read + new banner signature:
```python
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
    # --check unchanged (exit 1 if v["blocked"])
```

- [ ] **Step 1: Update tests** — existing gate.py assertions in `test-queue-teeth.sh` that grep the
  banner for `BLOCKED`/`0 open HIGH` still hold, but add: a fixture with `ratified_through != source_commit`
  → banner shows `unreviewed`; a corrupt FINDINGS.md (`| ID ...` header, junk body) → `--check` exits 1
  (fail closed); the `--waive` assertion updates to grep `ratified_through .*->` (not `pin`), and asserts
  `DEBT-WAIVERS.md` is `git`-staged after `--waive` in a git-repo fixture.
- [ ] **Step 2–4:** run (fails on new assertions), apply edits (a)–(e), run → PASS.
- [ ] **Step 5:** commit `feat(speccraft): gate.py two-anchor status; waive targets ratified_through; I1/I2/M1`.

## Task R3: `session-kit/pre-commit` — gate `ratified_through` (not `source_commit`)

**Files:** Modify `session-kit/pre-commit`; Test `test-queue-teeth.sh`.

Change the gate trigger inside the `KB_RATIFY` branch from `source_commit` to `ratified_through`:
```sh
  if git diff --cached -- "$KB/kb/derived/inventory.md" | grep -q '^+ratified_through:'; then
    NEWRT=$(git diff --cached -- "$KB/kb/derived/inventory.md" \
            | sed -nE 's/^\+ratified_through:[[:space:]]*([^[:space:]]+).*/\1/p' | head -1)
    if ! python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" >/dev/null 2>&1; then
      if git diff --cached -- "$KB/ledger/DEBT-WAIVERS.md" | grep -qE "^\+.*->[[:space:]]*${NEWRT}([[:space:]]|\$)"; then
        :   # staged waiver names this ratified_through — authorized
      else
        echo "pre-commit: HIGH-debt gate blocks advancing ratified_through to ${NEWRT}." >&2
        python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" >&2 || true
        echo "  Fix the HIGH findings, or: python3 $FORGE/gate.py --config $KB/kbforge.yaml --waive \"reason\"" >&2
        exit 1
      fi
    fi
  fi
```

- [ ] **Step 1: Tests** — update the existing pre-commit test: (a) the blocked/waiver flow now advances
  `ratified_through` (not `source_commit`) under `KB_RATIFY=1` — blocked without waiver, allowed with;
  (b) NEW: a `KB_SHIPLOOP=1` commit that advances **`source_commit`** under HIGH debt SUCCEEDS (mechanical
  pin never gated). Seed with `KB_SHIPLOOP=1` as before.
- [ ] **Step 2–4:** run (fails), edit, run → PASS.
- [ ] **Step 5:** commit `feat(speccraft): pre-commit gates ratified_through, not the mechanical pin`.

## Task R4: `kb-briefing.sh` — two-anchor status banner

**Files:** Modify `kb-briefing.sh`; Test `test-queue-teeth.sh`.

The banner already calls `python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" --banner` — after R2 that
emits the two-anchor status. Verify the call is unchanged and correct; if the briefing computed anything
banner-related itself, remove that (gate.py owns the status now). No logic beyond the existing guarded call
should be needed.

- [ ] **Step 1: Tests** — update the briefing test: green state (`ratified_through==source_commit`, no HIGH)
  → first line `KB caught up`; behind state (unreviewed gap and/or HIGH debt) → first line `KB behind`.
- [ ] **Step 2–4:** run, adjust the guarded call if needed, run → PASS.
- [ ] **Step 5:** commit `feat(speccraft): kb-briefing shows two-anchor KB status`.

## Task R5: `speccraft-ratify/SKILL.md` — advance `ratified_through`

**Files:** Modify `speccraft-ratify/SKILL.md` (prose only).

Replace the "advance `source_commit`" instruction (added in the first pass) with advancing
`ratified_through`:
```markdown
After adjudicating the findings, advance the trust boundary: set `ratified_through:` in
`kb/derived/inventory.md` to the current `source_commit:` value ("the KB is reviewed and
clean through here"). Do NOT touch `source_commit` — the ship loop owns it.

Before advancing, run the HIGH-debt gate:

    python3 <forge>/gate.py --config <kbroot>/kbforge.yaml

If it exits 0, advance `ratified_through` and commit (`KB_RATIFY=1`). If it BLOCKS, either fix
the HIGH findings first, or record a waiver (which git-adds itself and authorizes this one advance):

    python3 <forge>/gate.py --config <kbroot>/kbforge.yaml --waive "why you're deferring"

The pre-commit hook enforces this: advancing `ratified_through` under HIGH debt without a
matching waiver is refused.
```
(Leave the `Raised`-preserve instruction from the first pass intact. `diverge`'s `Raised` stamp is unchanged.)

- [ ] **Step 1:** make the prose edit; verify `grep -q ratified_through` on the ratify SKILL.
- [ ] **Step 2:** commit `docs(speccraft): ratify advances ratified_through trust boundary`.

## Task R6: full-suite green + SPEC.md anchor note

**Files:** `session-kit/evals/self-test.sh` (verify), `SPEC.md` (document the two anchors).

- [ ] **Step 1:** run `bash kb-forge/speccraft/forge/session-kit/evals/self-test.sh` — must be all-green,
  including the revised queue-teeth suite. Report the final `self-test: N passed, 0 failed` line.
- [ ] **Step 2:** in `SPEC.md`, where `inventory.md`/the pin is described, document both anchors:
  `source_commit` (mechanical, ship-loop) and `ratified_through` (trust boundary, advanced by gated ratify).
- [ ] **Step 3:** commit `test(speccraft): full suite green post-split; document two anchors`.

## Revision self-review
- Spec §4.1 two anchors → R1 (seed0 write/preserve) + R2 (gate reads) + SKILL init note ✓
- §4.3 gate compute (unchanged) + M1 fail-closed → R2 ✓
- §4.4 enforcement re-point (ratify prose + pre-commit) → R5 + R3 ✓
- §4.5 two-anchor status banner → R2 (`banner`) + R4 (briefing) ✓
- §4.6 waiver→ratified_through + I1 makedirs + I2 git-add → R2 ✓
- §5 tests (ratified gate, ship-loop-not-gated, seed0-preserve, status, fail-closed, tracked waiver) → R1–R4 ✓
- Deferred (safe): T1(b) waiver git-show success-path assertion, T3 blocks-vs-broken — carry as minors.
Placeholder scan: R1/R3/R4 flag "adapt to the file's real writer/vars" (seed0 writer, hook vars) — a read,
not a vague-in-code placeholder. gate.py edits (a)–(e) are literal.
