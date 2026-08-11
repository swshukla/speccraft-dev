# Executable Checks — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `speccraft-check` engine that runs deterministic product checks (convention grep-bans + custom scripts) and reports violations — lenient (exit 0) by default, strict (exit nonzero) when opted in globally, per-run, or per-check.

**Architecture:** `check.py` (stdlib) reads ratified conventions with an `avoid_pattern` regex and greps their anchored paths in the product repo (Source A), and discovers+runs product executables under `kb/normative/checks/` (Source B). It prints a grouped report and exits nonzero iff any *strict-effective* violation exists. Reuses `from drift import load_config` and `from recall import frontmatter`. Not wired into pre-commit.

**Tech Stack:** Python 3.9+ (stdlib only), the existing `session-kit/evals/` bash test harness.

## Global Constraints

- **Python ≥ 3.9, stdlib only, no new deps.** File IO `encoding="utf-8"`.
- **Import stanza:** `sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))` then `from drift import load_config` and `from recall import frontmatter` (exactly as `drift.py`/`gate.py` reuse siblings).
- **`avoid_pattern` is read RAW (regex-safe), NOT via `frontmatter()`** — `frontmatter()` splits on `#` and coerces `[...]` to a list, which mangles regexes. Use a `_raw_field(path, "avoid_pattern")` helper that returns the value after the colon with only surrounding quotes stripped. All OTHER fields (`anchors`, `seam`, `avoid`, `status`, `strict`) come from `frontmatter()` (safe).
- **Strict-effective rule:** a violation fails the build iff `global_strict` (`--strict` flag OR `cfg.get("check_mode","lenient")=="strict"`) OR the individual check's `strict` (convention `strict: true`, or a script's `# strict: true` header). Exit nonzero iff ≥1 strict-effective violation; else exit 0 (lenient/clean).
- **CLI:** `python3 <forge>/check.py --config <kbroot>/kbforge.yaml [--strict]`. `kbroot=dirname(config)`, `repo=expanduser(cfg["repo"])`.
- **Scan hygiene:** walking the repo, skip dirs `{.git, .speccraft, node_modules, __pycache__, .venv, venv}`; only scan source extensions (`.py .ts .tsx .js .jsx .sql .yaml .yml .toml .sh .go .rb .java`); open files `errors="ignore"`.
- **Tests:** `session-kit/evals/test-check.sh`, styled like `test-freeze.sh`, ending `echo "check: $pass passed, $fail failed"` + `[ "$fail" -eq 0 ]`; wired into `self-test.sh` as a `check` section modeled on `freeze`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `check.py` | The engine: grep-bans (Source A), custom scripts (Source B), modes, report | **Create** |
| `session-kit/skills/speccraft-check/SKILL.md` + codex/opencode mirrors | Run checks, author a check, enable strict, CI snippet | **Create** |
| `session-kit/skills/speccraft-ratify/SKILL.md` | Note `avoid_pattern`/`strict:` makes a seam an executable grep-ban | **Modify** |
| `session-kit/hooks/kb-briefing.sh` | Lenient check-violation count line | **Modify** |
| `SPEC.md` | Document `speccraft-check` (2 sources, 2 modes, CI snippet) | **Modify** |
| `session-kit/evals/fixtures/…` | Example `CHK-01-alembic-metadata.sh` + a grep-ban CONV fixture | **Create** |
| `session-kit/evals/test-check.sh` + `self-test.sh` | The suite + wire-in | **Create/Modify** |

---

## Task 1: `check.py` — Source A (grep-bans) + modes + report

**Files:** Create `check.py`; Create `session-kit/evals/test-check.sh`.

**Interfaces:**
- Consumes: `load_config`, `frontmatter`; conventions under `kb/normative/conventions/`.
- Produces: `check.py --config <cfg> [--strict]` → grouped violation report; exit 0 lenient/clean, nonzero iff ≥1 strict-effective violation.

- [ ] **Step 1: Write the failing test**

Create `session-kit/evals/test-check.sh`:

```bash
#!/usr/bin/env bash
# Phase-4 executable-checks assertions.
set -euo pipefail
FORGE="$(cd "$(dirname "$0")/../.." && pwd)"   # .../speccraft/forge
TMP="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# fixture: a product repo + a .speccraft with one grep-ban convention
mkkb() { # $1=kbdir  $2=check_mode(optional)
  local kb="$1"; mkdir -p "$kb/kb/normative/conventions"
  printf 'repo: %s\n' "$REPO" > "$kb/kbforge.yaml"
  [ -n "${2:-}" ] && printf 'check_mode: %s\n' "$2" >> "$kb/kbforge.yaml"
}
addconv() { # $1=kb $2=id $3=pattern $4=anchors $5=strict(true/"")
  local kb="$1"
  { echo '---'; echo 'status: ratified'; echo "anchors: [$4]";
    echo "avoid_pattern: \"$3\""; echo 'seam: "effective_tier(user)"';
    echo 'avoid: "raw User.tier for gating"';
    [ "$5" = "true" ] && echo 'strict: true';
    echo '---'; echo "## $2 — one entitlement seam"; } > "$kb/kb/normative/conventions/$2.md"
}
REPO="$TMP/repo"; mkdir -p "$REPO/backend/worker"

echo "== grep-ban finds a violation (lenient exits 0 with report) =="
KB="$TMP/kb1"; mkkb "$KB"; addconv "$KB" CONV-11 '\bUser\.tier\b' 'backend/worker' ""
printf 'if User.tier == "pro":\n    pass\n' > "$REPO/backend/worker/push.py"
OUT=$(python3 "$FORGE/check.py" --config "$KB/kbforge.yaml"); RC=0 || RC=$?
printf '%s' "$OUT" | grep -q 'backend/worker/push.py:1' && ok "reports violation with file:line" || bad "reports violation"
printf '%s' "$OUT" | grep -q 'effective_tier' && ok "reports the seam fix" || bad "reports seam"
python3 "$FORGE/check.py" --config "$KB/kbforge.yaml" >/dev/null 2>&1; [ $? -eq 0 ] && ok "lenient default exits 0" || bad "lenient exits 0"

echo "== --strict exits nonzero on a violation =="
python3 "$FORGE/check.py" --config "$KB/kbforge.yaml" --strict >/dev/null 2>&1 && bad "--strict exits nonzero" || ok "--strict exits nonzero"

echo "== global check_mode: strict exits nonzero =="
KB2="$TMP/kb2"; mkkb "$KB2" strict; addconv "$KB2" CONV-11 '\bUser\.tier\b' 'backend/worker' ""
python3 "$FORGE/check.py" --config "$KB2/kbforge.yaml" >/dev/null 2>&1 && bad "global strict nonzero" || ok "global strict nonzero"

echo "== per-check strict: true fails even when global is lenient =="
KB3="$TMP/kb3"; mkkb "$KB3"; addconv "$KB3" CONV-11 '\bUser\.tier\b' 'backend/worker' true
OUT=$(python3 "$FORGE/check.py" --config "$KB3/kbforge.yaml" 2>&1); RC=0; python3 "$FORGE/check.py" --config "$KB3/kbforge.yaml" >/dev/null 2>&1 || RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '\[strict\]' && ok "per-check strict fails + tagged [strict]" || bad "per-check strict"

echo "== clean repo: no violations, exit 0 =="
KB4="$TMP/kb4"; mkkb "$KB4"; addconv "$KB4" CONV-11 '\bUser\.tier\b' 'backend/worker' ""
CLEAN="$TMP/clean"; mkdir -p "$CLEAN/backend/worker"; printf 'x = effective_tier(user)\n' > "$CLEAN/backend/worker/ok.py"
sed -i.bak "s#repo: .*#repo: $CLEAN#" "$KB4/kbforge.yaml"
python3 "$FORGE/check.py" --config "$KB4/kbforge.yaml" 2>&1 | grep -q '0 violation' && ok "clean repo 0 violations" || bad "clean repo"

echo "== convention without avoid_pattern is skipped =="
KB5="$TMP/kb5"; mkkb "$KB5"
{ echo '---'; echo 'status: ratified'; echo 'anchors: [backend]'; echo 'seam: "x()"'; echo '---'; echo '## CONV-9'; } > "$KB5/kb/normative/conventions/CONV-9.md"
python3 "$FORGE/check.py" --config "$KB5/kbforge.yaml" 2>&1 | grep -q '0 violation' && ok "no avoid_pattern → skipped" || bad "skipped"

echo "check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-check.sh`
Expected: FAIL — `check.py` does not exist.

- [ ] **Step 3: Write `check.py` (Source A + modes; stub Source B)**

```python
#!/usr/bin/env python3
"""speccraft-check — deterministic product checks. Lenient by default (report,
exit 0); strict (exit nonzero) via --strict, check_mode: strict, or per-check strict."""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drift import load_config
from recall import frontmatter

SKIP_DIRS = {".git", ".speccraft", "node_modules", "__pycache__", ".venv", "venv"}
SRC_EXT = (".py", ".ts", ".tsx", ".js", ".jsx", ".sql", ".yaml", ".yml",
           ".toml", ".sh", ".go", ".rb", ".java")


def _raw_field(path, field):
    """Read a frontmatter scalar RAW (regex-safe: no #-split, no []-coercion)."""
    with open(path, encoding="utf-8") as fh:
        if fh.readline().strip() != "---":
            return None
        for line in fh:
            if line.strip() == "---":
                break
            if line.startswith(field + ":"):
                return line.split(":", 1)[1].strip().strip('"').strip("'")
    return None


def grep_bans(kbroot):
    cdir = os.path.join(kbroot, "kb", "normative", "conventions")
    out = []
    if not os.path.isdir(cdir):
        return out
    for fn in sorted(os.listdir(cdir)):
        if not fn.endswith(".md"):
            continue
        path = os.path.join(cdir, fn)
        pat = _raw_field(path, "avoid_pattern")
        if not pat:
            continue
        meta = frontmatter(path)
        out.append({
            "id": fn[:-3],
            "pattern": pat,
            "anchors": [a for a in meta.get("anchors", []) if not a.startswith("topic:")],
            "seam": meta.get("seam", ""),
            "strict": str(meta.get("strict", "")).lower() == "true",
        })
    return out


def _scan_file(fp, rx, repo, ban, out):
    try:
        with open(fp, encoding="utf-8", errors="ignore") as fh:
            for i, line in enumerate(fh, 1):
                if rx.search(line):
                    out.append({"check": ban["id"], "file": os.path.relpath(fp, repo),
                                "line": i, "text": line.strip()[:120],
                                "seam": ban["seam"], "strict": ban["strict"]})
    except OSError:
        pass


def run_grep_bans(repo, bans):
    out = []
    for b in bans:
        try:
            rx = re.compile(b["pattern"])
        except re.error as e:
            out.append({"check": b["id"], "file": "(pattern)", "line": 0,
                        "text": f"invalid avoid_pattern: {e}", "seam": b["seam"],
                        "strict": b["strict"]})
            continue
        for anchor in (b["anchors"] or [""]):
            base = os.path.join(repo, anchor)
            if os.path.isfile(base):
                _scan_file(base, rx, repo, b, out)
            elif os.path.isdir(base):
                for root, dirs, files in os.walk(base):
                    dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
                    for f in files:
                        if f.endswith(SRC_EXT):
                            _scan_file(os.path.join(root, f), rx, repo, b, out)
    return out


def run_check_scripts(repo, kbroot):
    return []   # Source B — added in Task 2


def report(violations, global_strict):
    for v in violations:
        v["strict_eff"] = global_strict or v.get("strict", False)
    if not violations:
        print("speccraft-check: 0 violations")
        return 0
    groups = {}
    for v in violations:
        groups.setdefault(v["check"], []).append(v)
    for cid in sorted(groups):
        xs = groups[cid]
        print(f"\n## {cid} ({len(xs)} violation(s))")
        for v in xs:
            tag = "[strict]" if v["strict_eff"] else "[lenient]"
            loc = f"{v['file']}:{v['line']}" if v.get("line") else v["file"]
            print(f"  {tag} {loc}: {v['text']}")
            if v.get("seam"):
                print(f"         → USE: {v['seam']}")
    n_strict = sum(1 for v in violations if v["strict_eff"])
    print(f"\nspeccraft-check: {len(violations)} violation(s), {n_strict} strict.")
    return 1 if n_strict else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()
    cfg = load_config(args.config)
    kbroot = os.path.dirname(os.path.abspath(args.config))
    repo = os.path.expanduser(cfg.get("repo", "."))
    global_strict = args.strict or cfg.get("check_mode", "lenient").lower() == "strict"

    violations = run_grep_bans(repo, grep_bans(kbroot)) + run_check_scripts(repo, kbroot)
    return report(violations, global_strict)


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run to verify pass**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-check.sh`
Expected: PASS — `check: N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/check.py kb-forge/speccraft/forge/session-kit/evals/test-check.sh
git commit -m "feat(speccraft): check.py — convention grep-bans, lenient/strict modes"
```

---

## Task 2: `check.py` — Source B (custom check scripts)

**Files:** Modify `check.py`; Test `session-kit/evals/test-check.sh` (extend).

**Interfaces:**
- Consumes: executables under `kb/normative/checks/`.
- Produces: each script's nonzero exit → a violation (carrying its stdout + `# check-for:`/`# strict:` header), folded into the same report/mode logic.

- [ ] **Step 1: Extend the test** (append to `test-check.sh`, before the summary echo)

```bash
echo "== custom check script: nonzero → violation, exit0 → pass =="
KB6="$TMP/kb6"; mkdir -p "$KB6/kb/normative/checks"; printf 'repo: %s\n' "$REPO" > "$KB6/kbforge.yaml"
cat > "$KB6/kb/normative/checks/CHK-01-demo.sh" <<'EOF'
#!/usr/bin/env bash
# check-for: INV-1
# strict: true
echo "model Portfolio absent from target_metadata"
exit 1
EOF
chmod +x "$KB6/kb/normative/checks/CHK-01-demo.sh"
OUT=$(python3 "$FORGE/check.py" --config "$KB6/kbforge.yaml" 2>&1); RC=0; python3 "$FORGE/check.py" --config "$KB6/kbforge.yaml" >/dev/null 2>&1 || RC=$?
printf '%s' "$OUT" | grep -q 'Portfolio absent' && ok "script stdout surfaced" || bad "script stdout"
printf '%s' "$OUT" | grep -q 'CHK-01' && [ "$RC" -ne 0 ] && ok "script strict header → nonzero exit" || bad "script strict"
# a passing (exit 0) script produces no violation
cat > "$KB6/kb/normative/checks/CHK-02-ok.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$KB6/kb/normative/checks/CHK-02-ok.sh"
python3 "$FORGE/check.py" --config "$KB6/kbforge.yaml" 2>&1 | grep -q 'CHK-02' && bad "exit0 script should not report" || ok "exit0 script → no violation"
```

- [ ] **Step 2: Run → fails** (Source B is stubbed).

- [ ] **Step 3: Implement Source B** — replace the `run_check_scripts` stub:

```python
def _script_header(path):
    hdr = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if s.startswith("#!"):
                continue
            if s.startswith("#"):
                body = s[1:].strip()
                if ":" in body:
                    k, val = body.split(":", 1)
                    if k.strip() in ("check-for", "strict"):
                        hdr[k.strip()] = val.strip()
                continue
            if s == "" :
                continue
            break   # first non-comment, non-blank line ends the header
    return hdr


def run_check_scripts(repo, kbroot):
    import subprocess
    cdir = os.path.join(kbroot, "kb", "normative", "checks")
    out = []
    if not os.path.isdir(cdir):
        return out
    for fn in sorted(os.listdir(cdir)):
        path = os.path.join(cdir, fn)
        if not (os.path.isfile(path) and os.access(path, os.X_OK)):
            continue
        hdr = _script_header(path)
        strict = hdr.get("strict", "").lower() == "true"
        try:
            r = subprocess.run([path], cwd=repo, capture_output=True, text=True,
                               env={**os.environ, "SPECCRAFT_REPO": repo}, timeout=120)
        except Exception as e:
            out.append({"check": fn, "file": "(script)", "line": 0,
                        "text": f"check failed to run: {e}", "strict": strict})
            continue
        if r.returncode != 0:
            msg = (r.stdout.strip() or r.stderr.strip() or f"exit {r.returncode}")[:500]
            out.append({"check": fn, "file": "(script)", "line": 0, "text": msg,
                        "seam": hdr.get("check-for", ""), "strict": strict})
    return out
```
(Note: `seam` here is repurposed to render the `check-for: INV-…` link; the report's `→ USE:` line will show it. If you prefer a distinct field, add one and render it — keep the report readable either way.)

- [ ] **Step 4: Run → passes.** `bash kb-forge/speccraft/forge/session-kit/evals/test-check.sh`.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/check.py kb-forge/speccraft/forge/session-kit/evals/test-check.sh
git commit -m "feat(speccraft): check.py — custom check scripts (kb/normative/checks)"
```

---

## Task 3: docs — `speccraft-check` skill + mirrors + SPEC + ratify note + example fixtures

**Files:** Create `session-kit/skills/speccraft-check/SKILL.md` + `codex-prompts/speccraft-check.md` + `opencode-commands/speccraft-check.md`; Modify `session-kit/skills/speccraft-ratify/SKILL.md`, `SPEC.md`; Create an example `CHK-01` fixture + a grep-ban CONV fixture under `session-kit/evals/fixtures/`.

- [ ] **Step 1:** `speccraft-check/SKILL.md` — how to run `python3 <forge>/check.py --config .speccraft/kbforge.yaml [--strict]`; the two sources (a convention's `avoid_pattern`; a `kb/normative/checks/CHK-NN-<slug>.sh` script with `# check-for:`/`# strict:` header, exit 0/nonzero); the two modes and the three ways to enable strict (global `check_mode`, `--strict`, per-check `strict: true`); a CI snippet (a GitHub-Actions step running `check.py --strict`). Match existing SKILL style.

- [ ] **Step 2:** Mirror to `codex-prompts/speccraft-check.md` + `opencode-commands/speccraft-check.md`, harness-adapted like the other mirrors (compare a skill↔mirror pair). Note: `check.py` runs the same under any harness (it's a script, not a Claude hook), so no self-apply caveat needed — but keep the codex/opencode framing/args.

- [ ] **Step 3:** `speccraft-ratify/SKILL.md` — in the convention-accepted step, note that a seam convention MAY carry `avoid_pattern:` (a grep regex) and optionally `strict: true` to make it an executable grep-ban enforced by `speccraft-check` (Phase-4). Brief; consistent with the existing seam fields.

- [ ] **Step 4:** `SPEC.md` — document `speccraft-check`: the two sources, the two modes + strict-effective rule, and the CI snippet; note it is standalone (not in pre-commit).

- [ ] **Step 5:** Create example fixtures for the docs/mechanism: `session-kit/evals/fixtures/` — a grep-ban CONV (`CONV-11` with `avoid_pattern`) and an example custom check `CHK-01-alembic-metadata.sh` (a runnable illustration: greps the repo for models declared but absent from `target_metadata`, exits nonzero if any; header `# check-for: INV-1` `# strict: true`). Keep it a documented example, not wired into self-test's product-checks.

- [ ] **Step 6:** Verify + commit. `grep -l 'check.py\|speccraft-check' kb-forge/speccraft/forge/SPEC.md kb-forge/speccraft/forge/session-kit/skills/speccraft-check/SKILL.md` (both listed); each mirror mentions the two sources + modes. Docs must match the code (`--strict`, `check_mode`, `strict: true`, `# check-for:`/`# strict:`, `kb/normative/checks/`).
```bash
git add kb-forge/speccraft/forge/session-kit/skills/speccraft-check kb-forge/speccraft/forge/session-kit/codex-prompts/speccraft-check.md kb-forge/speccraft/forge/session-kit/opencode-commands/speccraft-check.md kb-forge/speccraft/forge/session-kit/skills/speccraft-ratify/SKILL.md kb-forge/speccraft/forge/SPEC.md kb-forge/speccraft/forge/session-kit/evals/fixtures
git commit -m "docs(speccraft): speccraft-check skill + mirrors + SPEC + example checks"
```

---

## Task 4: briefing count line + `self-test.sh` wire-in

**Files:** Modify `session-kit/hooks/kb-briefing.sh`; Modify `session-kit/evals/self-test.sh`.

- [ ] **Step 1:** `kb-briefing.sh` — add a lenient, non-blocking line when check violations exist: run `check.py` in lenient mode (guarded — `check.py` present, `kbforge.yaml` present, `2>/dev/null || true`) and show `✎ N check violations (lenient — run speccraft-check)`. Parse the count from the `speccraft-check: N violation(s)` summary. Never break the briefing (guard like the freeze line). If it would slow SessionStart materially (it walks the repo), gate it behind a config flag `briefing_checks: true` (default off) — document that choice in the report.

- [ ] **Step 2:** `self-test.sh` — add a `check` section modeled EXACTLY on the `freeze` section (runs `test-check.sh`, folds `check: N passed, N failed` counts, nonzero-exit guard). Use the file's real `$HERE`/`run_section`/`no` names.

- [ ] **Step 3:** Run the full suite:

Run: `bash kb-forge/speccraft/forge/session-kit/evals/self-test.sh 2>&1 | tail -1`
Expected: `self-test: N passed, 0 failed` (N = prior 199 + check assertions). Report N. (Slow ~4min.)

- [ ] **Step 4:** Confirm the fold is real, then commit:
```bash
git add kb-forge/speccraft/forge/session-kit/hooks/kb-briefing.sh kb-forge/speccraft/forge/session-kit/evals/self-test.sh
git commit -m "feat(speccraft): briefing check-violation count; wire check suite into self-test"
```

---

## Self-Review

**Spec coverage** (against `2026-08-11-executable-checks-design.md`):
- §4.1 engine `check.py` → Task 1 ✓
- §4.2 grep-bans (avoid_pattern, raw-read) → Task 1 ✓
- §4.3 custom scripts → Task 2 ✓
- §4.4 lenient/strict + strict-effective (global/--strict/per-check) → Task 1 (modes) + Task 2 (script strict) ✓
- §4.5 wiring (standalone, CI snippet, optional briefing line) → Task 3 (docs/CI) + Task 4 (briefing) ✓
- §4.6 steal-now instances (raw-tier CONV, Alembic example script) → Task 3 fixtures ✓
- §5 tests → Task 1 (grep-ban/modes) + Task 2 (scripts) + Task 4 (wire-in) ✓

**Placeholder scan:** the `avoid_pattern` raw-read (Task 1) and the `_script_header` parse (Task 2) are literal. Task 3 (docs) and the Task 4 briefing insertion are read-and-adapt with exact behavior. No vague-in-code placeholders.

**Type/name consistency:** the violation dict keys (`check, file, line, text, seam, strict`, then `strict_eff`) are consistent across `run_grep_bans`, `run_check_scripts`, and `report`. `check_mode`/`--strict`/`strict:`/`# strict:` are the three strict levers used consistently. `check: N passed` summary line matches between `test-check.sh` and the self-test parse.

---

## Execution Handoff

Plan complete. `check.py`'s code is literal (grep-bans, modes, report in Task 1; scripts in Task 2). Read-and-adapt spots: the docs/mirrors (Task 3) and the `kb-briefing.sh` insertion (Task 4), both with exact target behavior. The `avoid_pattern` regex-safe raw read is the one subtlety — flagged in Global Constraints and coded literally.
