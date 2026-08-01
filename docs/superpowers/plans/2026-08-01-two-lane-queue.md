# Two-Lane Convergent Queue — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `.speccraft/QUEUE.md` into a durable human divergence lane (`QUEUE.md`) and a mechanical `SIGNALS.md` rendered as a self-deduplicating, self-decaying projection of `pin→head` drift, and kill the self-citation loop that inflated the queue to ~600 lines.

**Architecture:** A new `signals.py` module owns `SIGNALS.md` via fenced, region-scoped read-modify-write (`drift`, `deps`, `advisories` regions). `drift.py` and `dep-diff.py` stop appending to `QUEUE.md` and instead *rewrite* their region each run (a projection — dedup and decay fall out for free); findings that drop out are appended to `QUEUE-ARCHIVE.md`. The keystone fix excludes the queue files from `drift.py`'s KB scan so it never re-ingests its own output. Human tools (`speccraft-diverge`, `speccraft-ratify`, `kb-audit.sh`) keep `QUEUE.md` for `## Open`/`## Ruled` only.

**Tech Stack:** Python 3.9+ (stdlib only — `os`, `re`, `argparse`, `datetime`), Bash integration tests via the existing `session-kit/evals/` harness, YAML KB config.

## Global Constraints

- **Python ≥ 3.9**, standard library only — **no new dependencies** (repo declares none; do not add pytest). Copy verbatim: `requires-python = ">=3.9"`.
- **All file IO uses `encoding="utf-8"`** — matches existing forge modules.
- **Tests are Bash**, following `session-kit/evals/self-test.sh` conventions (fixture KB + real CLI invocation + file-content assertions). No Python test framework.
- **Preserve the `--queue` CLI flag** and `--config`-derived `kbroot` (`kbroot = os.path.dirname(os.path.abspath(args.config))`) on `drift.py` and `dep-diff.py`.
- **The three region names are fixed:** `drift`, `deps`, `advisories`. Fence markers: `<!-- signals:<name> -->` … `<!-- /signals:<name> -->`.
- **Repo paths** (absolute): forge dir = `/Users/swapnil/superdev/kb-forge/speccraft/forge`. All module paths below are relative to that dir unless noted.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `signals.py` | Owns `SIGNALS.md`: fenced region read/write + header count + resolved→archive | **Create** |
| `drift.py` | (1) exclude queue files from scan; (2) project drift findings into the `drift` region; (3) archive resolved | **Modify** |
| `dep-diff.py` | Project dependency-version drift into the `deps` region | **Modify** |
| `deps0.py` | Write new advisories into the `advisories` region (additive within the region) | **Modify** |
| `decay.py` | Retire `QUEUE.md` section-age archiving (projection subsumes it); trim `QUEUE-ARCHIVE.md` by age | **Modify** |
| `session-kit/hooks/kb-briefing.sh` | Two scoped counts: divergences (`QUEUE.md`) + signals (`SIGNALS.md`) | **Modify** |
| `session-kit/evals/kb-audit.sh` | Route eval-audit findings to `QUEUE.md ## Open`, numbering scoped to that section | **Modify** |
| `session-kit/skills/speccraft-diverge/SKILL.md` | Prose: divergences go to `QUEUE.md ## Open` (unchanged target, clarified) | **Modify** |
| `session-kit/skills/speccraft-ratify/SKILL.md` | Prose: on pin advance, re-run `drift.py --queue` to re-project | **Modify** |
| `session-kit/evals/test-queue-split.sh` | New Phase-0 assertions (idempotency, lane isolation, no self-citation, resolution, region ownership) | **Create** |
| `session-kit/evals/self-test.sh` | Rewrite assertions coupled to the old single-file `## Staleness` format; invoke the new test script | **Modify** |
| `migrate_split_queue.py` | One-time: split an installed `QUEUE.md` into human `QUEUE.md` + fresh `SIGNALS.md` | **Create** |

---

## Task 1: `signals.py` — the region-scoped SIGNALS.md owner

**Files:**
- Create: `signals.py`
- Test: `session-kit/evals/test-queue-split.sh` (created here; extended by later tasks)

**Interfaces:**
- Consumes: nothing (stdlib only).
- Produces:
  - `read_region(kbroot: str, region: str) -> str` — the raw body between the region's fences (`""` if file/fence absent).
  - `read_lines(kbroot: str, region: str) -> list[str]` — only the `- [ ]` lines in that region.
  - `write_region(kbroot: str, region: str, body: str) -> None` — replaces the region's content with `body` (idempotent); creates `SIGNALS.md` + fences if absent; refreshes the top `# SIGNALS — N open mechanical signals` header.
  - `archive_resolved(kbroot: str, resolved_lines: list[str]) -> None` — appends lines to `QUEUE-ARCHIVE.md`.
  - Constants: `SIGNALS = "SIGNALS.md"`, `ARCHIVE = "QUEUE-ARCHIVE.md"`, `REGIONS = ("drift", "deps", "advisories")`.

- [ ] **Step 1: Write the failing test**

Create `session-kit/evals/test-queue-split.sh`:

```bash
#!/usr/bin/env bash
# Phase-0 two-lane queue assertions. Run standalone or from self-test.sh.
set -euo pipefail
FORGE="$(cd "$(dirname "$0")/../.." && pwd)"   # .../speccraft/forge
PYME() { python3 -c "import sys; sys.path.insert(0, '$FORGE/../..'); $1"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ok: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "== signals.py region round-trip =="
PYME "
from speccraft.forge import signals
kb = '$TMP'
signals.write_region(kb, 'drift', '## drift\n- [ ] a\n- [ ] b')
assert signals.read_lines(kb, 'drift') == ['- [ ] a', '- [ ] b'], signals.read_lines(kb,'drift')
# overwrite is idempotent + replaces, never appends
signals.write_region(kb, 'drift', '## drift\n- [ ] a')
assert signals.read_lines(kb, 'drift') == ['- [ ] a']
# a second region is untouched by writing the first
signals.write_region(kb, 'deps', '- [ ] dep1')
signals.write_region(kb, 'drift', '## drift\n- [ ] a')
assert signals.read_lines(kb, 'deps') == ['- [ ] dep1']
# header reflects total open count
import os
txt = open(os.path.join(kb, 'SIGNALS.md'), encoding='utf-8').read()
assert txt.splitlines()[0] == '# SIGNALS — 2 open mechanical signals', txt.splitlines()[0]
print('REGION_OK')
" | grep -q REGION_OK && ok "region round-trip" || bad "region round-trip"

echo "== archive_resolved appends =="
PYME "
from speccraft.forge import signals
import os
kb = '$TMP'
signals.archive_resolved(kb, ['- resolved 2026-08-01: kb/x cites y.py:1'])
signals.archive_resolved(kb, ['- resolved 2026-08-01: kb/x cites z.py:2'])
lines = open(os.path.join(kb,'QUEUE-ARCHIVE.md'), encoding='utf-8').read().splitlines()
assert lines == ['- resolved 2026-08-01: kb/x cites y.py:1', '- resolved 2026-08-01: kb/x cites z.py:2'], lines
print('ARCHIVE_OK')
" | grep -q ARCHIVE_OK && ok "archive appends" || bad "archive appends"

echo "signals.py: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: FAIL — `ModuleNotFoundError: No module named 'speccraft.forge.signals'`.

- [ ] **Step 3: Write minimal implementation**

Create `signals.py`:

```python
#!/usr/bin/env python3
"""SIGNALS.md — mechanical drift projection with fenced, region-scoped writes.

Regions (drift, deps, advisories) are each owned by one writer and replaced
whole on every run, so SIGNALS.md is a projection of current state: dedup and
decay require no bookkeeping. The top header is a live open-signal count.
"""
import os
import re

SIGNALS = "SIGNALS.md"
ARCHIVE = "QUEUE-ARCHIVE.md"
REGIONS = ("drift", "deps", "advisories")


def _fence(region):
    return f"<!-- signals:{region} -->", f"<!-- /signals:{region} -->"


def _skeleton():
    parts = ["# SIGNALS — 0 open mechanical signals\n\n"]
    for r in REGIONS:
        o, c = _fence(r)
        parts.append(f"{o}\n{c}\n\n")
    return "".join(parts)


def _path(kbroot):
    return os.path.join(kbroot, SIGNALS)


def read_region(kbroot, region):
    path = _path(kbroot)
    if not os.path.exists(path):
        return ""
    text = open(path, encoding="utf-8").read()
    o, c = _fence(region)
    m = re.search(re.escape(o) + r"\n?(.*?)\n?" + re.escape(c), text, re.S)
    return m.group(1) if m else ""


def read_lines(kbroot, region):
    return [ln for ln in read_region(kbroot, region).splitlines()
            if ln.startswith("- [ ]")]


def _refresh_header(text):
    n = len(re.findall(r"(?m)^- \[ \]", text))
    plural = "signal" if n == 1 else "signals"
    header = f"# SIGNALS — {n} open mechanical {plural}"
    lines = text.splitlines()
    if lines and lines[0].startswith("# SIGNALS —"):
        lines[0] = header
        return "\n".join(lines) + ("\n" if text.endswith("\n") else "")
    return header + "\n\n" + text


def write_region(kbroot, region, body):
    path = _path(kbroot)
    text = open(path, encoding="utf-8").read() if os.path.exists(path) else _skeleton()
    o, c = _fence(region)
    if o not in text:
        text = text.rstrip("\n") + f"\n\n{o}\n{c}\n"
    replacement = f"{o}\n{body}\n{c}" if body else f"{o}\n{c}"
    pat = re.compile(re.escape(o) + r"\n.*?\n?" + re.escape(c), re.S)
    text = pat.sub(lambda _m: replacement, text)
    text = _refresh_header(text)
    open(path, "w", encoding="utf-8").write(text)


def archive_resolved(kbroot, resolved_lines):
    if not resolved_lines:
        return
    with open(os.path.join(kbroot, ARCHIVE), "a", encoding="utf-8") as fh:
        for line in resolved_lines:
            fh.write(line + "\n")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: PASS — `signals.py: 2 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/signals.py kb-forge/speccraft/forge/session-kit/evals/test-queue-split.sh
git commit -m "feat(speccraft): signals.py — fenced region-scoped SIGNALS.md owner"
```

---

## Task 2: `drift.py` — kill self-scan + project into the drift region

**Files:**
- Modify: `drift.py` (walk at `:265-270`; writer at `:341-358`)
- Test: `session-kit/evals/test-queue-split.sh` (extend)

**Interfaces:**
- Consumes: `signals.read_lines`, `signals.write_region`, `signals.archive_resolved` (Task 1).
- Produces: after `drift.py --config <cfg> --queue`, all mechanical drift output lives in `SIGNALS.md`'s `drift` region; `QUEUE.md` is never written; resolved findings land in `QUEUE-ARCHIVE.md`.

- [ ] **Step 1: Write the failing test** (append to `test-queue-split.sh`, before the final summary echo)

This builds a hermetic fixture: a tiny "code" git repo + a KB whose config points at it, with one KB fact citing a code line. It runs `drift.py --queue` twice and asserts the projection is idempotent, isolated, and self-citation-free.

```bash
echo "== drift.py projection (idempotency / lane isolation / no self-citation) =="
CODE="$TMP/code"; KB="$TMP/kb"
mkdir -p "$CODE" "$KB/kb/normative" "$KB/kb/derived"
( cd "$CODE" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'a\nb\nc\nd\n' > svc.py && git add . && git commit -qm init )
PIN="$( cd "$CODE" && git rev-parse --short HEAD )"
# a KB fact citing svc.py line 2
printf '# facts\n- svc does X (`svc.py:2`)\n' > "$KB/kb/normative/00.md"
printf 'source_commit: %s\n' "$PIN" > "$KB/kb/derived/inventory.md"
printf 'repo: %s\n' "$CODE" > "$KB/kbforge.yaml"
# change svc.py so line 2's neighborhood shifts -> a drift finding
( cd "$CODE" && printf 'a\nCHANGED\nb\nc\nd\n' > svc.py && git commit -qam change )

run_drift() { python3 "$FORGE/drift.py" --config "$KB/kbforge.yaml" --queue >/dev/null 2>&1 || true; }
run_drift
FIRST="$(cat "$KB/SIGNALS.md")"
run_drift
SECOND="$(cat "$KB/SIGNALS.md")"

[ "$FIRST" = "$SECOND" ] && ok "idempotent (byte-identical on rerun)" || bad "idempotent"
[ ! -s "$KB/QUEUE.md" ] || ! grep -q -- '- \[ \]' "$KB/QUEUE.md" 2>/dev/null \
  && ok "lane isolation (no mechanical lines in QUEUE.md)" || bad "lane isolation"
! grep -Eq 'cites .*(QUEUE|SIGNALS|QUEUE-ARCHIVE)\.md' "$KB/SIGNALS.md" \
  && ! grep -q 'SIGNALS.md' "$KB/SIGNALS.md" \
  && ok "no self-citation" || bad "no self-citation"
grep -q 'signals:drift' "$KB/SIGNALS.md" && ok "drift region present" || bad "drift region present"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: FAIL on "idempotent" and/or "lane isolation" — current `drift.py` appends to `QUEUE.md` and re-scans it, so `SIGNALS.md` is absent and reruns differ.

- [ ] **Step 3a: Exclude the queue files from the KB scan**

In `drift.py`, the walk currently is (`:265-270`):

```python
    findings = []   # (kb_file, cited_path, cited_range, severity)
    for root, dirs, files in os.walk(kbroot):
        dirs[:] = [d for d in dirs if d not in {".git", "derived"}]
        for f in files:
            if not f.endswith(".md"):
                continue
            kbf = os.path.relpath(os.path.join(root, f), kbroot)
```

Add the queue-file skip immediately after the `.md` check:

```python
        for f in files:
            if not f.endswith(".md"):
                continue
            if f in {"QUEUE.md", "SIGNALS.md", "QUEUE-ARCHIVE.md"}:
                continue          # never re-ingest our own queue output
            kbf = os.path.relpath(os.path.join(root, f), kbroot)
```

- [ ] **Step 3b: Replace the QUEUE.md writer with a drift-region projection**

Add near the top of `drift.py` with the other imports:

```python
from speccraft.forge import signals
```

Replace the current writer block (`:341-358`, the `if args.queue and (findings or adds or scope_q):` … `with open(os.path.join(kbroot, "QUEUE.md"), "a")` section) with:

```python
    if args.queue:
        now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        lines = []
        for kbf, p, r, sev in hard:
            lines.append(f"- [ ] re-verify `{kbf}` — cites `{p}:{r}` [{sev}]")
        for kbf, p, r, sev in soft:
            lines.append(f"- [ ] spot-check `{kbf}` — cites `{p}:{r}` [file changed elsewhere]")
        for aspect in sorted(adds):
            lines.append(f"- [ ] additive drift [{aspect}]: {len(adds[aspect])} "
                         f"new site(s) — {ASPECT_TARGET[aspect]}")
        for kbf, a, hits in scope_q:
            # PRESERVE the existing anchor-scope wording: take the exact f-string
            # the old writer used for this line and append it to `lines` (drop the
            # trailing "\n") instead of fh.write(...).
            lines.append(_anchor_scope_line(kbf, a, hits))   # see note below
        body = f"## drift (pin {pin} → head {head}, {now})\n" + "\n".join(lines)
        prev = set(signals.read_lines(kbroot, "drift"))
        resolved = [f"- resolved {now}: {ln[6:]}" for ln in sorted(prev - set(lines))]
        signals.archive_resolved(kbroot, resolved)
        signals.write_region(kbroot, "drift", body)
```

**Note on `_anchor_scope_line`:** do not invent wording. The old writer already
renders the anchor-scope line with a specific f-string (the `- [ ] anchor scope
drift: ...` block near `:353-357`). Lift that exact f-string body into a tiny local
helper `def _anchor_scope_line(kbf, a, hits): return f"..."` (same text, no trailing
`\n`) and call it as above, so the rendered string is byte-for-byte the prior one.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: PASS — idempotent, lane isolation, no self-citation, drift region present.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/drift.py kb-forge/speccraft/forge/session-kit/evals/test-queue-split.sh
git commit -m "feat(speccraft): drift.py projects into SIGNALS.md; exclude queue files from scan"
```

---

## Task 3: `dep-diff.py` — project into the deps region

**Files:**
- Modify: `dep-diff.py` (writer at `:167-175`)
- Test: `session-kit/evals/test-queue-split.sh` (extend)

**Interfaces:**
- Consumes: `signals.write_region` (Task 1).
- Produces: dependency-version drift lives in `SIGNALS.md`'s `deps` region; writing it does not disturb the `drift` region.

- [ ] **Step 1: Write the failing test** (append to `test-queue-split.sh`)

```bash
echo "== dep-diff writes deps region without touching drift =="
DRIFT_BEFORE="$(python3 -c "import sys;sys.path.insert(0,'$FORGE/../..');from speccraft.forge import signals;print(signals.read_region('$KB','drift'))")"
# minimal dep-diff invocation against the same fixture KB/repo:
python3 "$FORGE/dep-diff.py" --config "$KB/kbforge.yaml" --queue >/dev/null 2>&1 || true
DRIFT_AFTER="$(python3 -c "import sys;sys.path.insert(0,'$FORGE/../..');from speccraft.forge import signals;print(signals.read_region('$KB','drift'))")"
[ "$DRIFT_BEFORE" = "$DRIFT_AFTER" ] && ok "dep-diff leaves drift region intact" || bad "dep-diff region ownership"
! grep -q -- '- \[ \]' "$KB/QUEUE.md" 2>/dev/null && ok "dep-diff writes no QUEUE.md lines" || bad "dep-diff lane isolation"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: FAIL — current `dep-diff.py` appends its `- [ ] dep-diff:` lines to `QUEUE.md`.

- [ ] **Step 3: Replace the writer**

Add import at top of `dep-diff.py`:

```python
from speccraft.forge import signals
```

Replace the QUEUE.md append block (`:167-175`, the `with open(os.path.join(kbroot, "QUEUE.md"), "a") as fh:` section that writes `## Dependency drift — dep-diff run ...` + `- [ ] dep-diff: ...` lines) with a region projection that collects the same `- [ ] dep-diff: ...` lines into a list and writes them once:

```python
    if args.queue:
        now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        lines = [f"- [ ] dep-diff: {d}" for d in dep_findings]   # same text as before, sans header
        body = f"## dependency drift ({pin}→{head}, {now})\n" + "\n".join(lines) if lines else ""
        signals.write_region(kbroot, "deps", body)
```

Use whatever the module's existing finding variable is named for `dep_findings` (the list currently iterated in the `fh.write` loop); keep each line's text identical to the current `- [ ] dep-diff: ...` string.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: PASS — deps region isolated, no QUEUE.md lines.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/dep-diff.py kb-forge/speccraft/forge/session-kit/evals/test-queue-split.sh
git commit -m "feat(speccraft): dep-diff.py projects into SIGNALS.md deps region"
```

---

## Task 4: `deps0.py` — advisories into the advisories region

**Files:**
- Modify: `deps0.py` (advisory queue-append at `:263-272`)
- Test: `session-kit/evals/test-queue-split.sh` (extend)

**Interfaces:**
- Consumes: `signals.read_lines`, `signals.write_region` (Task 1).
- Produces: new CVE advisories accumulate in `SIGNALS.md`'s `advisories` region (additive within the region — advisories are time-based, not a `pin→head` projection), preserving `deps0`'s existing baseline dedup.

- [ ] **Step 1: Write the failing test** (append to `test-queue-split.sh`)

```bash
echo "== deps0 advisories go to advisories region, additive =="
PYME "
from speccraft.forge import signals
kb='$KB'
# simulate two advisory scans appending distinct CVEs
signals.write_region(kb, 'advisories', '\n'.join(signals.read_lines(kb,'advisories') + ['- [ ] advisory: CVE-2024-1 in jose']))
signals.write_region(kb, 'advisories', '\n'.join(signals.read_lines(kb,'advisories') + ['- [ ] advisory: CVE-2024-2 in urllib3']))
got = signals.read_lines(kb, 'advisories')
assert got == ['- [ ] advisory: CVE-2024-1 in jose', '- [ ] advisory: CVE-2024-2 in urllib3'], got
print('ADV_OK')
" | grep -q ADV_OK && ok "advisories additive in region" || bad "advisories additive"
```

*(This test proves the region supports additive accumulation via the helper. Step 3 wires `deps0.py`'s real advisory path to it.)*

- [ ] **Step 2: Run test to verify it fails / passes-helper**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: PASS for the helper-level assertion (Task 1 already supports it). If it FAILS, fix `signals.py` before proceeding.

- [ ] **Step 3: Wire `deps0.py`'s advisory writer to the region**

Add import at top of `deps0.py`:

```python
from speccraft.forge import signals
```

Replace the advisory `QUEUE.md` append (`:263-272`, where `new_items` — advisory IDs not in the saved baseline — are appended to `QUEUE.md`) with an additive region write that keeps existing advisory lines and adds the new ones:

```python
    if args.queue_advisories and new_items:
        existing = signals.read_lines(kbroot, "advisories")
        new_lines = [f"- [ ] advisory: {a}" for a in new_items]   # keep current advisory text
        body = "## advisories\n" + "\n".join(existing + new_lines)
        signals.write_region(kbroot, "advisories", body)
```

Keep the existing per-line advisory text (`{a}` = whatever the current code formats for each advisory) so the wording is unchanged; only the destination moves from `QUEUE.md` to the `advisories` region. Leave the baseline-save logic untouched.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/deps0.py kb-forge/speccraft/forge/session-kit/evals/test-queue-split.sh
git commit -m "feat(speccraft): deps0 advisories write to SIGNALS.md advisories region"
```

---

## Task 5: `decay.py` — retire QUEUE.md archiving, trim the archive

**Files:**
- Modify: `decay.py` (`MECH_HEADER` at `:25-27`; archive logic at `:47-71`)
- Test: `session-kit/evals/test-queue-split.sh` (extend)

**Interfaces:**
- Consumes: `queue_archive_days` from KB config (existing; default 30).
- Produces: `decay.py` no longer touches `QUEUE.md` (projection self-cleans drift/deps regions); it trims `QUEUE-ARCHIVE.md` entries older than `queue_archive_days`.

**Context:** Under projection, a fixed finding vanishes from `SIGNALS.md` on the next run and its record is already in `QUEUE-ARCHIVE.md` (Task 2). So `decay.py`'s section-age archiving of `QUEUE.md` is dead — worse, its `MECH_HEADER` regex is coupled to the retired `## Staleness — drift run` header. `decay.py`'s remaining useful job is bounding archive growth.

- [ ] **Step 1: Write the failing test** (append to `test-queue-split.sh`)

```bash
echo "== decay trims old archive entries, leaves QUEUE.md alone =="
AKB="$TMP/akb"; mkdir -p "$AKB/kb/derived"
printf 'queue_archive_days: 30\nrepo: %s\n' "$CODE" > "$AKB/kbforge.yaml"
printf 'source_commit: %s\n' "$PIN" > "$AKB/kb/derived/inventory.md"
printf '## Open\n1. keep me (a human divergence)\n' > "$AKB/QUEUE.md"
# archive with a dated line older than 30 days and one recent
printf -- '- resolved 2000-01-01: old thing\n- resolved %s: new thing\n' "$(date +%Y-%m-%d)" > "$AKB/QUEUE-ARCHIVE.md"
python3 "$FORGE/decay.py" --config "$AKB/kbforge.yaml" >/dev/null 2>&1 || true
grep -q 'keep me' "$AKB/QUEUE.md" && ok "decay leaves QUEUE.md divergences" || bad "decay touched QUEUE.md"
! grep -q '2000-01-01' "$AKB/QUEUE-ARCHIVE.md" && ok "decay trimmed old archive entry" || bad "decay trim old"
grep -q 'new thing' "$AKB/QUEUE-ARCHIVE.md" && ok "decay kept recent archive entry" || bad "decay kept recent"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: FAIL — current `decay.py` scans `QUEUE.md` for `## Staleness` headers and does not trim `QUEUE-ARCHIVE.md` by per-line date.

- [ ] **Step 3: Rewrite `decay.py`'s body**

Replace the `MECH_HEADER`-based `QUEUE.md` archiving with archive-trimming. Keep the config-loading and `queue_archive_days` reading intact; replace the section-walk/archive logic:

```python
import datetime as _dt
import os
import re

ARCHIVE = "QUEUE-ARCHIVE.md"
_DATED = re.compile(r"^- resolved (\d{4}-\d{2}-\d{2}):")

def main():
    # ... keep existing arg/config parse; obtain kbroot and queue_archive_days ...
    cutoff = _dt.date.today() - _dt.timedelta(days=int(queue_archive_days))
    path = os.path.join(kbroot, ARCHIVE)
    if not os.path.exists(path):
        return
    kept = []
    for ln in open(path, encoding="utf-8").read().splitlines():
        m = _DATED.match(ln)
        if m and _dt.date.fromisoformat(m.group(1)) < cutoff:
            continue          # drop entries older than the window
        kept.append(ln)
    open(path, "w", encoding="utf-8").write("\n".join(kept) + ("\n" if kept else ""))
```

Delete the `MECH_HEADER` constant and the old `QUEUE.md` section-walk entirely.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: PASS — QUEUE.md untouched, old archive entry gone, recent kept.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/decay.py kb-forge/speccraft/forge/session-kit/evals/test-queue-split.sh
git commit -m "refactor(speccraft): decay.py trims QUEUE-ARCHIVE.md; retire QUEUE.md section archiving"
```

---

## Task 6: `kb-briefing.sh` — two scoped counts

**Files:**
- Modify: `session-kit/hooks/kb-briefing.sh` (the `OPEN=$(grep -cE '^[0-9]+\.' ...)` line, ~`:24`)
- Test: `session-kit/evals/test-queue-split.sh` (extend)

**Interfaces:**
- Consumes: `QUEUE.md` (`## Open` numbered items), `SIGNALS.md` (`- [ ]` lines).
- Produces: a briefing line `N open divergences | M drift signals`.

- [ ] **Step 1: Write the failing test** (append to `test-queue-split.sh`)

```bash
echo "== briefing reports two scoped counts =="
BKB="$TMP/bkb"; mkdir -p "$BKB/kb/normative" "$BKB/kb/derived"
printf '## Open\n1. one divergence\n2. two divergence\n\n## Ruled\n- x\n' > "$BKB/QUEUE.md"
printf '# SIGNALS — 3 open mechanical signals\n<!-- signals:drift -->\n- [ ] a\n- [ ] b\n- [ ] c\n<!-- /signals:drift -->\n' > "$BKB/SIGNALS.md"
printf 'source_commit: abc\n' > "$BKB/kb/derived/inventory.md"
printf 'repo: %s\n' "$CODE" > "$BKB/kbforge.yaml"
OUT="$(KB="$BKB" bash "$FORGE/session-kit/hooks/kb-briefing.sh" 2>/dev/null || bash "$FORGE/session-kit/hooks/kb-briefing.sh" "$BKB" 2>/dev/null || true)"
echo "$OUT" | grep -q '2 open divergences' && ok "counts divergences (2)" || bad "divergence count"
echo "$OUT" | grep -q '3 drift signals' && ok "counts signals (3)" || bad "signal count"
```

*(The briefing hook takes the KB path per its existing convention — the map shows it reads `$KB/...`. Use whichever of `$2`/`$KB` the current script uses; the test tries both.)*

- [ ] **Step 2: Run test to verify it fails**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: FAIL — current script prints a single file-wide `^[0-9]+\.` count and no signals count.

- [ ] **Step 3: Update the count logic**

In `kb-briefing.sh`, replace the single divergence count line:

```bash
OPEN=$(grep -cE '^[0-9]+\.' "$KB/QUEUE.md" 2>/dev/null || echo 0)
```

with two scoped counts (count `## Open` items only, and signals separately):

```bash
# divergences: numbered items under ## Open in QUEUE.md, not file-wide
DIV=$(awk '/^## Open/{o=1;next} /^## /{o=0} o && /^[0-9]+\./{c++} END{print c+0}' "$KB/QUEUE.md" 2>/dev/null)
SIG=$(grep -cE '^- \[ \]' "$KB/SIGNALS.md" 2>/dev/null || echo 0)
```

Then update the briefing output line that referenced `$OPEN` to read:

```bash
echo "${DIV} open divergences | ${SIG} drift signals"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: PASS — `2 open divergences`, `3 drift signals`.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/session-kit/hooks/kb-briefing.sh kb-forge/speccraft/forge/session-kit/evals/test-queue-split.sh
git commit -m "feat(speccraft): kb-briefing reports scoped divergence + signal counts"
```

---

## Task 7: `kb-audit.sh` — eval-audit findings to QUEUE.md ## Open

**Files:**
- Modify: `session-kit/evals/kb-audit.sh` (append at `:109-113`)
- Test: `session-kit/evals/test-queue-split.sh` (extend)

**Interfaces:**
- Consumes: `QUEUE.md ## Open` section.
- Produces: eval-audit findings are inserted at the end of the `## Open` section with numbering scoped to that section (not a file-wide `grep -c`), never past arbitrary end-of-file.

- [ ] **Step 1: Write the failing test** (append to `test-queue-split.sh`)

```bash
echo "== kb-audit numbers within ## Open, not file-wide =="
QKB="$TMP/qkb"; mkdir -p "$QKB/kb/derived"
printf '## Open\n1. existing divergence\n\n## Ruled\n- past ruling with 9. fake number\n' > "$QKB/QUEUE.md"
printf 'source_commit: abc\n' > "$QKB/kb/derived/inventory.md"
printf 'repo: %s\n' "$CODE" > "$QKB/kbforge.yaml"
# simulate kb-audit appending one finding (call the script's append path or its helper)
KB="$QKB" bash "$FORGE/session-kit/evals/kb-audit.sh" --append-test "audited: sample finding" 2>/dev/null || true
# the new item must be numbered 2 (within ## Open), not 3 (file-wide count of 1.+9.)
grep -qE '^2\. .*sample finding' "$QKB/QUEUE.md" && ok "scoped numbering (2)" || bad "scoped numbering"
awk '/^## Open/{o=1;next}/^## /{o=0}o&&/sample finding/{f=1}END{exit !f}' "$QKB/QUEUE.md" && ok "inserted inside ## Open" || bad "inserted inside ## Open"
```

*(If `kb-audit.sh` has no test hook, add a minimal `--append-test "<text>"` branch that runs only the numbering+insert logic against `$KB/QUEUE.md`, so this behavior is unit-testable without a full eval run.)*

- [ ] **Step 2: Run test to verify it fails**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: FAIL — current `N=$(grep -cE '^[0-9]+\.' "$KB/QUEUE.md")` counts the `9.` in `## Ruled` too and appends at end-of-file.

- [ ] **Step 3: Scope the numbering + insertion**

In `kb-audit.sh`, replace the file-wide count (`N=$(grep -cE '^[0-9]+\.' "$KB/QUEUE.md")`) and end-of-file append with an `awk` that counts numbered items *within* `## Open` and inserts the new item at the end of that section:

```bash
# next number = count of "N." lines within the ## Open section, +1
N=$(awk '/^## Open/{o=1;next}/^## /{o=0}o&&/^[0-9]+\./{c++}END{print c+1}' "$KB/QUEUE.md")
# insert "$N. $TEXT" at the end of the ## Open section (before the next "## " or EOF)
awk -v n="$N" -v t="$TEXT" '
  /^## Open/{o=1; print; next}
  o && /^## /{print n". "t; print ""; o=0}
  {print}
  END{ if(o) print n". "t }
' "$KB/QUEUE.md" > "$KB/QUEUE.md.tmp" && mv "$KB/QUEUE.md.tmp" "$KB/QUEUE.md"
```

Where `$TEXT` is the existing audit-line content the script already builds. Add the small `--append-test` branch referenced in the test if none exists.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: PASS — numbered `2.`, inside `## Open`.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/session-kit/evals/kb-audit.sh kb-forge/speccraft/forge/session-kit/evals/test-queue-split.sh
git commit -m "fix(speccraft): kb-audit numbers within ## Open, inserts in-section"
```

---

## Task 8: SKILL.md prose — repoint diverge & ratify

**Files:**
- Modify: `session-kit/skills/speccraft-diverge/SKILL.md`
- Modify: `session-kit/skills/speccraft-ratify/SKILL.md`

**Interfaces:**
- Consumes: nothing executable — these are agent-followed prose instructions.
- Produces: the diverge/ratify workflows reference the two-lane layout; ratify re-projects `SIGNALS.md` after advancing the pin.

- [ ] **Step 1: Update `speccraft-diverge/SKILL.md`**

Find the instruction that says to append the divergence "under `## Open` (next number)". Add an explicit clarifying sentence:

```markdown
Divergences are recorded ONLY in `QUEUE.md` under `## Open` (the human lane).
Never write to `SIGNALS.md` — that file is a machine-owned projection of drift,
rewritten on every drift run, and any hand-edit will be overwritten.
```

- [ ] **Step 2: Update `speccraft-ratify/SKILL.md`**

Find step 4 (moving a resolved `## Open` item into `## Ruled — <date>`). Append:

```markdown
After advancing the `source_commit` pin in `kb/derived/inventory.md`, re-run the
drift projection so `SIGNALS.md` reflects the new pin:

    python3 <forge>/drift.py --config <kbroot>/kbforge.yaml --queue

This is the existing drift command — no new mechanism. Findings resolved by the
new pin drop out of `SIGNALS.md` automatically and are recorded in
`QUEUE-ARCHIVE.md`.
```

- [ ] **Step 3: Verify (doc-only, no automated test)**

Run: `grep -l 'SIGNALS.md' kb-forge/speccraft/forge/session-kit/skills/speccraft-*/SKILL.md`
Expected: both `speccraft-diverge` and `speccraft-ratify` SKILL.md listed.

- [ ] **Step 4: Commit**

```bash
git add kb-forge/speccraft/forge/session-kit/skills/speccraft-diverge/SKILL.md kb-forge/speccraft/forge/session-kit/skills/speccraft-ratify/SKILL.md
git commit -m "docs(speccraft): diverge/ratify skills reference two-lane queue + re-projection"
```

---

## Task 9: `self-test.sh` — rewrite old assertions, wire in the new suite

**Files:**
- Modify: `session-kit/evals/self-test.sh` (assertions coupled to old format; the synthetic seed at `:239-254`; the `decay` round-trip)
- Test: the suite itself

**Interfaces:**
- Consumes: `test-queue-split.sh` (Tasks 1–7).
- Produces: a green `self-test.sh` that no longer asserts the retired `## Staleness — drift run` single-file format and that runs the two-lane suite.

- [ ] **Step 1: Read the current assertions and identify the coupled ones**

Run: `grep -nE 'Staleness — drift run|dep-diff:|archived .*mechanical|## Adjudication|MECH_HEADER' kb-forge/speccraft/forge/session-kit/evals/self-test.sh`
Expected: the lines to rewrite (per the machinery map: `:134-135, 163-164, 187-194, 219, 239-254, 301`).

- [ ] **Step 2: Run the suite to see what breaks**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/self-test.sh`
Expected: FAIL on the assertions that grep for `## Staleness — drift run` / `dep-diff:` in `QUEUE.md` and the `decay` archive round-trip (behavior moved to `SIGNALS.md` / `QUEUE-ARCHIVE.md`).

- [ ] **Step 3: Rewrite the coupled assertions**

For each failing assertion, repoint it from `QUEUE.md` to the new location:
- Drift lines: assert they appear in `SIGNALS.md`'s `drift` region, not `QUEUE.md`.
- `dep-diff:` lines: assert they appear in `SIGNALS.md`'s `deps` region.
- The synthetic seed (`:239-254`) that hand-writes `## Staleness — drift run (a→b)` into `QUEUE.md`: change it to seed `SIGNALS.md` fences (or delete it in favor of the fixture in `test-queue-split.sh`).
- The `decay` round-trip: assert `decay.py` trims `QUEUE-ARCHIVE.md` (Task 5) instead of moving `QUEUE.md` sections.

Then add, near the end of `self-test.sh`, an invocation of the new suite:

```bash
echo "== two-lane queue suite =="
bash "$(dirname "$0")/test-queue-split.sh"
```

- [ ] **Step 4: Run the full suite to verify green**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/self-test.sh`
Expected: PASS — all assertions, including the appended two-lane suite.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/session-kit/evals/self-test.sh
git commit -m "test(speccraft): repoint self-test assertions to two-lane queue; run split suite"
```

---

## Task 10: `migrate_split_queue.py` — one-time split of an installed QUEUE.md

**Files:**
- Create: `migrate_split_queue.py`
- Test: `session-kit/evals/test-queue-split.sh` (extend)

**Interfaces:**
- Consumes: an installed KB dir containing a legacy `QUEUE.md`.
- Produces: a new `QUEUE.md` with only `## Open` + `## Ruled` preserved verbatim; every `## Staleness — drift run` / `## Dependency drift` section dropped. (SIGNALS.md is then regenerated by running `drift.py --queue`.)

- [ ] **Step 1: Write the failing test** (append to `test-queue-split.sh`)

```bash
echo "== migration keeps human lane, drops mechanical sections =="
MKB="$TMP/mkb"; mkdir -p "$MKB"
cat > "$MKB/QUEUE.md" <<'EOF'
## Open

1. real divergence (INV-5)

## Ruled — 2026-07-19

- a ruling

## Staleness — drift run 2026-07-25 (a→b)

- [ ] spot-check `QUEUE.md` — cites `x.py:1` [file changed elsewhere]

## Dependency drift — dep-diff run 2026-07-25 (a→b)

- [ ] dep-diff: bumped foo
EOF
python3 "$FORGE/migrate_split_queue.py" "$MKB/QUEUE.md"
grep -q 'real divergence' "$MKB/QUEUE.md" && ok "migration keeps ## Open" || bad "migration keeps ## Open"
grep -q 'a ruling' "$MKB/QUEUE.md" && ok "migration keeps ## Ruled" || bad "migration keeps ## Ruled"
! grep -q 'Staleness — drift run' "$MKB/QUEUE.md" && ok "migration drops staleness" || bad "migration drops staleness"
! grep -q 'Dependency drift' "$MKB/QUEUE.md" && ok "migration drops dep drift" || bad "migration drops dep drift"
! grep -q 'cites `QUEUE.md`' "$MKB/QUEUE.md" && ok "migration drops self-citation garbage" || bad "migration drops self-citation"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: FAIL — `migrate_split_queue.py` does not exist.

- [ ] **Step 3: Write the migration script**

Create `migrate_split_queue.py`:

```python
#!/usr/bin/env python3
"""One-time: keep only the human lane (## Open + ## Ruled) in an installed
QUEUE.md, dropping every mechanical section. Run drift.py --queue afterwards to
regenerate SIGNALS.md from the current pin."""
import sys

KEEP_PREFIXES = ("## Open", "## Ruled")
DROP_PREFIXES = ("## Staleness", "## Dependency drift")


def split(text):
    out, keep = [], True
    for line in text.splitlines():
        if line.startswith("## "):
            if line.startswith(DROP_PREFIXES):
                keep = False
            elif line.startswith(KEEP_PREFIXES) or True:
                # keep any non-mechanical section (Open, Ruled, preamble headers)
                keep = not line.startswith(DROP_PREFIXES)
        if keep:
            out.append(line)
    # collapse trailing blank lines
    while out and out[-1].strip() == "":
        out.pop()
    return "\n".join(out) + "\n"


def main():
    path = sys.argv[1]
    text = open(path, encoding="utf-8").read()
    open(path, "w", encoding="utf-8").write(split(text))
    print(f"migrated {path}: kept human lane, dropped mechanical sections")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash session-kit/evals/test-queue-split.sh`
Expected: PASS — human lane kept, mechanical sections + self-citation garbage dropped.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/migrate_split_queue.py kb-forge/speccraft/forge/session-kit/evals/test-queue-split.sh
git commit -m "feat(speccraft): migrate_split_queue.py — one-time human/mechanical lane split"
```

- [ ] **Step 6: Apply migration to the case-study KB (manual, verified)**

```bash
cp /Users/swapnil/stocktickerapp/.speccraft/QUEUE.md /tmp/QUEUE.md.bak   # safety copy
python3 kb-forge/speccraft/forge/migrate_split_queue.py /Users/swapnil/stocktickerapp/.speccraft/QUEUE.md
python3 kb-forge/speccraft/forge/drift.py --config /Users/swapnil/stocktickerapp/.speccraft/kbforge.yaml --queue
wc -l /Users/swapnil/stocktickerapp/.speccraft/QUEUE.md /Users/swapnil/stocktickerapp/.speccraft/SIGNALS.md
```

Expected: `QUEUE.md` collapses from ~600 lines to the ~16 `## Open` items + `## Ruled`; `SIGNALS.md` holds a small, deduped drift set. The `.bak` and git history preserve the original.

---

## Self-Review

**Spec coverage** (against `2026-08-01-two-lane-queue-design.md`):
- §3.1 keystone scan exclusion → Task 2 Step 3a ✓
- §3.2 two files, ownership → Tasks 2 (drift), 3 (deps), 4 (advisories) write SIGNALS.md; QUEUE.md human-only enforced by Tasks 7/8 ✓
- §3.3 projection + fenced regions + header meter → Task 1 (helper), Task 2 (drift projection) ✓
- §3.4 resolved → archive → Task 2 Step 3b (`archive_resolved`) ✓
- §3.5 consumer updates (briefing/kb-audit/decay/skills) → Tasks 5, 6, 7, 8 ✓
- §3.6 migration → Task 10 ✓
- §4 tests (idempotency, lane isolation, no self-citation, resolution, region ownership, briefing counts) → Task 2 (first three + region), Task 3 (region ownership), Task 6 (briefing counts), Task 9 (wires suite into self-test) ✓

**Placeholder scan:** anchor-scope line (Task 2) explicitly instructs lifting the *existing* f-string rather than inventing text; `dep_findings`/advisory `{a}` variable names flagged as "use the module's existing variable" because those exact names weren't in the read window — the engineer resolves them from the open file. No `TBD`/`handle edge cases`/`add validation` placeholders.

**Type consistency:** `read_region`/`read_lines`/`write_region`/`archive_resolved` signatures are identical across Tasks 1–4, 6. Region names `drift`/`deps`/`advisories` consistent throughout. `queue_archive_days` (Task 5) matches the existing config key from the machinery map.

---

## Execution Handoff

Plan complete. Note two spots where the engineer must resolve a name from the open file (both flagged inline, neither ambiguous in context): the anchor-scope f-string in `drift.py` (Task 2) and the finding-list variable in `dep-diff.py` (Task 3) / advisory format in `deps0.py` (Task 4). Everything else is literal.
