# Speccraft Evals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the three-tier eval pyramid (compliance telemetry, KB truth audit, behavioral suite) for the kb-forge/speccraft system, plus a seeded-defect self-test, per the approved spec at `docs/superpowers/specs/2026-07-21-speccraft-evals-design.md`.

**Architecture:** Deterministic bash scripts living canonically in `kb-forge/session-kit/evals/` and *run from the kit* (`$FORGE/session-kit/evals/...`), exactly like `recall.py` and the hooks — NOT copied per-repo. (Deliberate deviation from the spec's "install.sh gains an evals/ copy step": run-from-kit keeps one canonical source, which is the system's own core principle. install.sh instead ensures per-repo state: gitignore entry, `evals:` config block, reports dir.) Existing hooks each gain one fire-and-forget telemetry call. One capped `claude -p` judge pass handles semantic checks; it only flags, never edits the KB.

**Tech Stack:** bash + POSIX sh (git hooks are `#!/bin/sh`), jq, git, awk; `claude` CLI for the judge and behavioral runs.

## Global Constraints

- Platform is macOS (BSD userland): use `date -u -v-<N>d` with GNU `date -d` fallback; `sed -i ''` for in-place edits.
- Telemetry writes are fire-and-forget: every call site ends `|| true` or `return 0`; an eval failure must NEVER break a hook, commit, or session.
- Deterministic gates, LLM flags: the judge outputs verdicts + evidence only; `CONTRADICTED`/`POSSIBLY_STALE` become QUEUE items; no script ever edits `kb/normative/`, `kb/derived/`, or `ledger/`.
- `elicited` claims are never judged against code (their anchors still get mechanical checks).
- Defaults (all overridable in `kbforge.yaml` under `evals:`): `report_window_days: 14`, `telemetry_retention_days: 90`, `min_recall_rate: 0.70`, `min_precision: 0.80`, `judge_sample_size: 20`. Size backstop constants: 5 MB / keep newest 10,000 lines. Breach findings require ≥5 sessions (telemetry) / ≥5 sampled claims (audit) in window to avoid small-N noise.
- Telemetry JSONL schema (one object per line, `detail` values must contain no double quotes): `{"ts":"<UTC ISO8601>","session":"<id>","event":"<name>","detail":"<free text>"}`.
- Legal `status:` values: `ratified`, `ratified-partial`, `observed`, `pending-ratification`, `challenged`.
- All kit work happens in `/Users/swapnil/.speccraft` (becomes a git repo in Task 1). Commit after every task.

---

### Task 1: Init the kit git repo

The kit at `/Users/swapnil/.speccraft` has no version control; the plan's per-task commits need one. User approved initializing it.

**Files:**
- Create: `/Users/swapnil/.speccraft/.gitignore`

- [ ] **Step 1: Init and first commit**

```bash
cd /Users/swapnil/.speccraft
git init
printf '%s\n' '.DS_Store' '__pycache__/' '*.pyc' > .gitignore
git add .gitignore kb-forge docs
git commit -m "chore: init .speccraft kit repo (kb-forge, docs, specs)"
```

Note: `git add kb-forge docs` deliberately — do NOT `git add -A`; `invest4value/` and `whiteboard-notes.md` stay untracked until the user decides.

- [ ] **Step 2: Verify**

Run: `git -C /Users/swapnil/.speccraft log --oneline`
Expected: one commit; `git status` shows `invest4value/`, `whiteboard-notes.md` untracked, nothing staged.

---

### Task 2: Telemetry lib + self-test harness skeleton

**Files:**
- Create: `kb-forge/session-kit/evals/telemetry-lib.sh`
- Create: `kb-forge/session-kit/evals/self-test.sh`

**Interfaces:**
- Produces: `kb_telemetry <event> [detail]` — POSIX-sh function; requires env `$KB` (path to a `.speccraft/` dir); optional env `$KB_SESSION_ID` (default `nosession`); appends to `$KB/evals/telemetry.jsonl`; always returns 0.
- Produces: `self-test.sh [section]` — runs all sections (or one: `lib|report|hooks|audit|judge|behavioral`); exits 0 iff all assertions pass; prints `self-test: N passed, M failed`.

- [ ] **Step 1: Write self-test harness with the `lib` section (failing)**

Create `kb-forge/session-kit/evals/self-test.sh`:

```bash
#!/bin/bash
# kb-forge evals self-test — seeded-defect fixtures. Asserts every planted
# defect is caught and clean fixtures pass. Usage: self-test.sh [section]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ONLY="${1:-all}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
no(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert_contains(){ printf '%s' "$1" | grep -qE "$2" && ok || no "$3"; }
assert_not_contains(){ printf '%s' "$1" | grep -qE "$2" && no "$3" || ok; }
run_section(){ [ "$ONLY" = all ] || [ "$ONLY" = "$1" ]; }

# ---------- section: lib ----------
if run_section lib; then
  T=$(mktemp -d); export KB="$T/.speccraft"; mkdir -p "$KB"
  . "$HERE/telemetry-lib.sh"
  KB_SESSION_ID=sess1 kb_telemetry recall_ran "src/app.py"
  OUT=$(cat "$KB/evals/telemetry.jsonl" 2>/dev/null)
  assert_contains "$OUT" '"event":"recall_ran"' "lib: event written"
  assert_contains "$OUT" '"session":"sess1"' "lib: session recorded"
  echo "$OUT" | jq -e . >/dev/null 2>&1 && ok || no "lib: line is valid JSON"
  # never fails caller even with unwritable KB
  KB=/nonexistent kb_telemetry x && ok || no "lib: returns 0 on bad KB"
  # size backstop: >5MB truncates to newest 10000 lines
  yes '{"ts":"2026-01-01T00:00:00Z","session":"s","event":"pad","detail":""}' \
    | head -60000 > "$KB/evals/telemetry.jsonl"
  kb_telemetry after_backstop
  LINES=$(wc -l < "$KB/evals/telemetry.jsonl" | tr -d ' ')
  [ "$LINES" -le 10001 ] && ok || no "lib: size backstop truncated ($LINES lines)"
  tail -1 "$KB/evals/telemetry.jsonl" | grep -q after_backstop && ok || no "lib: append after backstop"
  rm -rf "$T"; unset KB
fi

echo "self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

Run: `chmod +x kb-forge/session-kit/evals/self-test.sh && kb-forge/session-kit/evals/self-test.sh lib`
Expected: FAIL (telemetry-lib.sh does not exist — source error / assertion failures).

- [ ] **Step 2: Implement `telemetry-lib.sh`**

```sh
#!/bin/sh
# kb-forge evals — telemetry append helper. POSIX sh: sourced by bash session
# hooks AND sh git hooks. Fire-and-forget: nothing here may fail the caller.
# Contract: kb_telemetry <event> [detail]. Needs $KB (.speccraft/ dir); optional
# $KB_SESSION_ID. detail must not contain double quotes.
kb_telemetry() {
  [ -n "${KB:-}" ] || return 0
  [ -d "$KB" ] || return 0
  _f="$KB/evals/telemetry.jsonl"
  mkdir -p "$KB/evals" 2>/dev/null || return 0
  if [ -f "$_f" ] && [ "$(wc -c < "$_f" 2>/dev/null || echo 0)" -gt 5242880 ]; then
    tail -n 10000 "$_f" > "$_f.tmp" 2>/dev/null && mv "$_f.tmp" "$_f" 2>/dev/null
  fi
  printf '{"ts":"%s","session":"%s","event":"%s","detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${KB_SESSION_ID:-nosession}" \
    "$1" "${2:-}" >> "$_f" 2>/dev/null || true
  return 0
}
```

- [ ] **Step 3: Run self-test — passes**

Run: `kb-forge/session-kit/evals/self-test.sh lib`
Expected: `self-test: 6 passed, 0 failed`, exit 0.

- [ ] **Step 4: Commit**

```bash
cd /Users/swapnil/.speccraft
git add kb-forge/session-kit/evals
git commit -m "feat(evals): telemetry append helper + self-test harness"
```

---

### Task 3: telemetry-report.sh — rates, GC, health snippet, breach finding

**Files:**
- Create: `kb-forge/session-kit/evals/telemetry-report.sh`
- Create: `kb-forge/session-kit/evals/fixtures/telemetry.jsonl`
- Modify: `kb-forge/session-kit/evals/self-test.sh` (add `report` section before the final echo)

**Interfaces:**
- Consumes: telemetry JSONL schema; events `session_start`, `recall_ran`, `recall_empty`, `ratify_used`, `guard_commit_block`, `guard_block`, `kb_status` (detail `queue=<N> ledger=<M>`).
- Produces: `telemetry-report.sh [--kb <dir>] [--window N] [--retention N]` — prints report to stdout; prunes `telemetry.jsonl` (GC); writes `$KB/evals/health.md` (rewrites its own line, preserves lines starting `- last audit:` / `- last behavioral:`); on recall-rate breach with ≥5 sessions writes `$KB/findings/<date>-evals-recall-rate.md`. Rate definitions: recall rate = sessions with ≥1 `recall_ran` ÷ sessions with ≥1 recall event (`recall_ran|recall_empty`); ratify rate reported as counts `ratify_used` vs `guard_commit_block`; queue/ledger reported as first→last `kb_status` counts in window.

- [ ] **Step 1: Add fixture + failing `report` self-test section**

Create `kb-forge/session-kit/evals/fixtures/telemetry.jsonl` (session s1 recalls with coverage, s2 gets no coverage, one ratify, one block, queue 14→12, ledger 3→3, two malformed lines; `REPLACETS` is patched to a recent date by the test so lines fall inside the window):

```
{"ts":"REPLACETS","session":"s1","event":"session_start","detail":""}
{"ts":"REPLACETS","session":"s1","event":"recall_ran","detail":"src/app.py"}
{"ts":"REPLACETS","session":"s1","event":"kb_status","detail":"queue=14 ledger=3"}
not json at all
{"ts":"REPLACETS","session":"s2","event":"session_start","detail":""}
{"ts":"REPLACETS","session":"s2","event":"recall_empty","detail":"src/new.py"}
{"ts":"REPLACETS","session":"s2","event":"ratify_used","detail":""}
{"ts":"REPLACETS","session":"s3","event":"guard_commit_block","detail":""}
{"broken":
{"ts":"2020-01-01T00:00:00Z","session":"old","event":"recall_ran","detail":"ancient, must be pruned"}
{"ts":"REPLACETS","session":"s2","event":"kb_status","detail":"queue=12 ledger=3"}
```

Add to `self-test.sh` before the final `echo` line:

```bash
# ---------- section: report ----------
if run_section report; then
  T=$(mktemp -d); KB="$T/.speccraft"; mkdir -p "$KB/evals" "$KB/findings"
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  sed "s/REPLACETS/$NOW/" "$HERE/fixtures/telemetry.jsonl" > "$KB/evals/telemetry.jsonl"
  printf -- '- last audit: none\n' > /dev/null # (health starts absent)
  OUT=$("$HERE/telemetry-report.sh" --kb "$KB")
  assert_contains "$OUT" 'recall 1/2' "report: recall rate 1/2 sessions"
  assert_contains "$OUT" 'ratify 1 used, 1 blocked' "report: ratify counts"
  assert_contains "$OUT" 'queue 14→12' "report: queue trend"
  assert_contains "$OUT" 'unparseable 2' "report: malformed counted"
  grep -q 'recall 1/2' "$KB/evals/health.md" && ok || no "report: health.md written"
  # GC: pruned the 2020 line and the malformed lines
  grep -q '"session":"old"' "$KB/evals/telemetry.jsonl" && no "report: GC pruned old line" || ok
  L=$(wc -l < "$KB/evals/telemetry.jsonl" | tr -d ' ')
  [ "$L" -eq 8 ] && ok || no "report: GC kept 8 in-retention parseable lines (got $L)"
  # breach finding NOT written (only 2 sessions < 5 minimum)
  ls "$KB/findings/" | grep -q evals-recall && no "report: no breach under min sessions" || ok
  # preserves audit/behavioral lines on rerun
  echo '- last audit: 2026-07-21 precision 0.85' >> "$KB/evals/health.md"
  "$HERE/telemetry-report.sh" --kb "$KB" > /dev/null
  grep -q 'last audit: 2026-07-21' "$KB/evals/health.md" && ok || no "report: preserves audit line"
  rm -rf "$T"
fi
```

Run: `kb-forge/session-kit/evals/self-test.sh report` — Expected: FAIL (script missing).

- [ ] **Step 2: Implement `telemetry-report.sh`**

```bash
#!/bin/bash
# Tier 1 evals report — rates over window, telemetry GC, health snippet,
# breach finding. Never blocks anything; exit 0 unless bad args.
# Usage: telemetry-report.sh [--kb <.speccraft-dir>] [--window N] [--retention N]
set -u
KB=""; WINDOW=""; RET=""
while [ $# -gt 0 ]; do case "$1" in
  --kb) KB=$2; shift 2;; --window) WINDOW=$2; shift 2;;
  --retention) RET=$2; shift 2;; *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$KB" ] || KB="$(git rev-parse --show-toplevel 2>/dev/null)/.speccraft"
F="$KB/evals/telemetry.jsonl"
[ -f "$F" ] || exit 0
cfgval(){ awk -v k="$1:" '$1==k {print $2; exit}' "$KB/kbforge.yaml" 2>/dev/null; }
WINDOW="${WINDOW:-$(cfgval report_window_days)}"; WINDOW="${WINDOW:-14}"
RET="${RET:-$(cfgval telemetry_retention_days)}"; RET="${RET:-90}"
MINR=$(cfgval min_recall_rate); MINR=${MINR:-0.70}
cutoff(){ date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
       || date -u -d "-$1 days" +%Y-%m-%dT%H:%M:%SZ; }
CUT_RET=$(cutoff "$RET"); CUT_WIN=$(cutoff "$WINDOW")

TOTAL=$(wc -l < "$F" | tr -d ' ')
PARSED_F=$(mktemp)
jq -cR 'fromjson? // empty' "$F" > "$PARSED_F"
BAD=$((TOTAL - $(wc -l < "$PARSED_F" | tr -d ' ')))
# GC: atomic prune to parseable + in-retention
jq -c --arg c "$CUT_RET" 'select(.ts >= $c)' "$PARSED_F" > "$F.tmp" && mv "$F.tmp" "$F"
WIN=$(jq -c --arg c "$CUT_WIN" 'select(.ts >= $c)' "$PARSED_F"); rm -f "$PARSED_F"

uniq_sessions(){ printf '%s\n' "$WIN" | jq -r "select(.event$1) | .session" | sort -u | grep -c .; }
DEN=$(uniq_sessions '=="recall_ran" or .event=="recall_empty"' || true)
NUM=$(uniq_sessions '=="recall_ran"' || true)
count_ev(){ printf '%s\n' "$WIN" | jq -r "select(.event==\"$1\")" | grep -c . || true; }
RUSED=$(count_ev ratify_used); RBLOCK=$(count_ev guard_commit_block)
statuses(){ printf '%s\n' "$WIN" | jq -r 'select(.event=="kb_status") | .detail'; }
QF=$(statuses | head -1 | sed -n 's/.*queue=\([0-9]*\).*/\1/p')
QL=$(statuses | tail -1 | sed -n 's/.*queue=\([0-9]*\).*/\1/p')
LF=$(statuses | head -1 | sed -n 's/.*ledger=\([0-9]*\).*/\1/p')
LL=$(statuses | tail -1 | sed -n 's/.*ledger=\([0-9]*\).*/\1/p')

LINE="- evals telemetry (last ${WINDOW}d): recall ${NUM}/${DEN} sessions | ratify ${RUSED} used, ${RBLOCK} blocked | queue ${QF:-?}→${QL:-?} | ledger ${LF:-?}→${LL:-?} | unparseable ${BAD}"
echo "$LINE"
H="$KB/evals/health.md"
KEEP=$(grep -E '^- last (audit|behavioral):' "$H" 2>/dev/null || true)
{ echo "$LINE"; [ -n "$KEEP" ] && printf '%s\n' "$KEEP"; } > "$H"

if [ "${DEN:-0}" -ge 5 ] && awk "BEGIN{exit !($NUM/$DEN < $MINR)}"; then
  mkdir -p "$KB/findings"
  FD="$KB/findings/$(date +%F)-evals-recall-rate.md"
  [ -f "$FD" ] || cat > "$FD" <<EOF
# Finding: KB recall rate below threshold
- window: last ${WINDOW}d | recall sessions: ${NUM}/${DEN} (< ${MINR})
- meaning: the loop is not engaged; Tier 2/3 eval results are unattributable.
- source: evals telemetry ($(date +%F)); see .speccraft/evals/telemetry.jsonl
EOF
fi
exit 0
```

- [ ] **Step 3: Run self-test — passes**

Run: `chmod +x kb-forge/session-kit/evals/telemetry-report.sh && kb-forge/session-kit/evals/self-test.sh report`
Expected: `self-test: 9 passed, 0 failed` (report section alone). Then run full: `kb-forge/session-kit/evals/self-test.sh` → 15 passed, 0 failed.

- [ ] **Step 4: Commit**

```bash
cd /Users/swapnil/.speccraft
git add kb-forge/session-kit/evals
git commit -m "feat(evals): tier-1 telemetry report with GC, health snippet, breach finding"
```

---

### Task 4: Wire telemetry into the six hooks

**Files:**
- Modify: `kb-forge/session-kit/hooks/kb-briefing.sh`
- Modify: `kb-forge/session-kit/hooks/kb-recall-post.sh`
- Modify: `kb-forge/session-kit/hooks/kb-guard.sh`
- Modify: `kb-forge/session-kit/hooks/kb-status.sh`
- Modify: `kb-forge/session-kit/pre-commit`
- Modify: `kb-forge/session-kit/evals/self-test.sh` (add `hooks` section)

**Interfaces:**
- Consumes: `kb_telemetry` from Task 2 (sourced as `. "$FORGE/session-kit/evals/telemetry-lib.sh"`).
- Produces events: `session_start` (briefing), `recall_ran`/`recall_empty` (recall-post), `guard_block` (guard), `ratify_used`/`guard_commit_block` (pre-commit), `kb_status` with `queue=N ledger=M` (kb-status). Also: `kb-status.sh` now appends `$KB/evals/health.md` content into `KB-STATUS.md`.

- [ ] **Step 1: Add failing `hooks` self-test section**

Append to `self-test.sh` (before final echo):

```bash
# ---------- section: hooks ----------
if run_section hooks; then
  KIT="$(cd "$HERE/.." && pwd)"
  for s in "$KIT/hooks/kb-briefing.sh" "$KIT/hooks/kb-recall-post.sh" \
           "$KIT/hooks/kb-guard.sh" "$KIT/hooks/kb-status.sh"; do
    bash -n "$s" && ok || no "hooks: bash syntax $s"
    grep -q 'telemetry-lib.sh' "$s" && ok || no "hooks: $s sources telemetry lib"
  done
  sh -n "$KIT/pre-commit" && ok || no "hooks: sh syntax pre-commit"
  grep -q 'ratify_used' "$KIT/pre-commit" && ok || no "hooks: pre-commit logs ratify_used"
  grep -q 'guard_commit_block' "$KIT/pre-commit" && ok || no "hooks: pre-commit logs guard_commit_block"
  grep -q 'kb_telemetry kb_status' "$KIT/hooks/kb-status.sh" && ok || no "hooks: kb-status logs counts"
  grep -q 'evals/health.md' "$KIT/hooks/kb-status.sh" && ok || no "hooks: kb-status embeds health"
  # safety: hooks still no-op cleanly outside any KB repo
  D=$(mktemp -d); (cd "$D" && git init -q .)
  (cd "$D" && "$KIT/hooks/kb-briefing.sh" </dev/null) && ok || no "hooks: briefing no-op exits 0"
  (cd "$D" && echo '{}' | "$KIT/hooks/kb-recall-post.sh") && ok || no "hooks: recall-post no-op exits 0"
  rm -rf "$D"
fi
```

Run: `kb-forge/session-kit/evals/self-test.sh hooks` — Expected: FAIL (no hook sources the lib yet).

- [ ] **Step 2: Edit `kb-briefing.sh`**

After line 7 (`[ -f "$KB/kb/derived/inventory.md" ] || exit 0`), insert:

```bash
. "$FORGE/session-kit/evals/telemetry-lib.sh" 2>/dev/null || kb_telemetry(){ :; }
if [ ! -t 0 ]; then IN=$(cat 2>/dev/null || true)
  KB_SESSION_ID=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"' 2>/dev/null || echo nosession)
fi
export KB_SESSION_ID
kb_telemetry session_start
```

(The `|| kb_telemetry(){ :; }` fallback keeps the hook alive if the kit predates evals. `[ ! -t 0 ]` guards against hanging when run manually from a terminal.)

- [ ] **Step 3: Edit `kb-recall-post.sh`**

After line 8 (`[ -f "$KB/kbforge.yaml" ] || exit 0`), insert:

```bash
. "$FORGE/session-kit/evals/telemetry-lib.sh" 2>/dev/null || kb_telemetry(){ :; }
```

Replace line 24 (`[ -z "$OUT" ] && exit 0`) with:

```bash
export KB_SESSION_ID="$SID"
[ -z "$OUT" ] && { kb_telemetry recall_empty "$REL"; exit 0; }
kb_telemetry recall_ran "$REL"
```

- [ ] **Step 4: Edit `kb-guard.sh`**

After line 6 (`KB=$ROOT/.speccraft`), insert:

```bash
FORGE="${KBFORGE_HOME:-$HOME/.speccraft/kb-forge}"
. "$FORGE/session-kit/evals/telemetry-lib.sh" 2>/dev/null || kb_telemetry(){ :; }
```

Note: `kb-guard.sh` reads its JSON from `jq -r` on stdin at line 8 — leave that line untouched. Inside the deny case (immediately before the `jq -n` deny output), insert:

```bash
    kb_telemetry guard_block "${FP#"$ROOT"/}"
```

- [ ] **Step 5: Edit `kb-status.sh`**

After line 16 (`OPEN=$(grep -cE ...QUEUE.md...)`), insert:

```bash
LEDGER=$(ls "$KB/ledger" 2>/dev/null | grep -c . || echo 0)
. "$FORGE/session-kit/evals/telemetry-lib.sh" 2>/dev/null || kb_telemetry(){ :; }
kb_telemetry kb_status "queue=$OPEN ledger=$LEDGER"
```

Inside the report heredoc block, after the `procedures` echo lines (line 29), insert:

```bash
  [ -f "$KB/evals/health.md" ] && cat "$KB/evals/health.md"
```

- [ ] **Step 6: Edit `pre-commit`** (POSIX sh — no bashisms)

Replace lines 6–7 (`[ -n "$KB_SHIPLOOP" ] && exit 0` / `[ -n "$KB_RATIFY" ] && exit 0`) with:

```sh
[ -n "$KB_SHIPLOOP" ] && exit 0
ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
KB="$ROOT/.speccraft"
FORGE="${KBFORGE_HOME:-$HOME/.speccraft/kb-forge}"
. "$FORGE/session-kit/evals/telemetry-lib.sh" 2>/dev/null || kb_telemetry(){ :; }
if [ -n "$KB_RATIFY" ]; then
  git diff --cached --name-only | grep -qE '^.speccraft/(kb/normative/|ledger/)' \
    && kb_telemetry ratify_used
  exit 0
fi
```

And after line 11 (`[ -z "$BLOCKED" ] && exit 0`), insert:

```sh
kb_telemetry guard_commit_block
```

- [ ] **Step 7: Run self-test — passes**

Run: `kb-forge/session-kit/evals/self-test.sh hooks`
Expected: `self-test: 15 passed, 0 failed` (hooks section). Full run: `kb-forge/session-kit/evals/self-test.sh` → 30 passed, 0 failed.

- [ ] **Step 8: Commit**

```bash
cd /Users/swapnil/.speccraft
git add kb-forge/session-kit
git commit -m "feat(evals): wire tier-1 telemetry into session + git hooks"
```

---

### Task 5: install.sh per-repo evals state

**Files:**
- Modify: `kb-forge/session-kit/install.sh` (after the skills block, before section 3b)

**Interfaces:**
- Produces (per repo): `.gitignore` entry `.speccraft/evals/telemetry.jsonl`; `evals:` block appended to `.speccraft/kbforge.yaml` if absent; `.speccraft/evals/reports/` dir with `.gitkeep`.

- [ ] **Step 1: Add the evals section to install.sh**

Insert after the opencode-commands copy (line 44):

```bash
# 3c. Evals (tier-1 telemetry + audits run FROM the kit; repo only needs state)
grep -qx '.speccraft/evals/telemetry.jsonl' "$REPO/.gitignore" 2>/dev/null \
  || echo '.speccraft/evals/telemetry.jsonl' >> "$REPO/.gitignore"
mkdir -p "$REPO/.speccraft/evals/reports"
touch "$REPO/.speccraft/evals/reports/.gitkeep"
if ! grep -q '^evals:' "$REPO/.speccraft/kbforge.yaml"; then
  cat >> "$REPO/.speccraft/kbforge.yaml" <<'EOF'
evals:
  report_window_days: 14
  telemetry_retention_days: 90
  min_recall_rate: 0.70
  min_precision: 0.80
  judge_sample_size: 20
EOF
fi
echo "evals: gitignore + kbforge.yaml evals block + reports dir ensured"
```

Note: the flat `cfgval` parser (`awk '$1==k'`) finds the indented `report_window_days:` keys regardless of the `evals:` parent — keys are globally unique in this file.

- [ ] **Step 2: Test idempotency on a throwaway repo**

```bash
D=$(mktemp -d); cd "$D" && git init -q
mkdir -p .speccraft && printf 'repo: x\nproduct: x\n' > .speccraft/kbforge.yaml
bash /Users/swapnil/.speccraft/kb-forge/session-kit/install.sh "$D"
bash /Users/swapnil/.speccraft/kb-forge/session-kit/install.sh "$D"
grep -c 'telemetry.jsonl' .gitignore        # expect: 1 (not 2)
grep -c '^evals:' .speccraft/kbforge.yaml     # expect: 1
ls .speccraft/evals/reports/.gitkeep          # expect: exists
```

Expected: counts are 1 and 1 after running twice; cleanup `rm -rf "$D"`.

- [ ] **Step 3: Commit**

```bash
cd /Users/swapnil/.speccraft
git add kb-forge/session-kit/install.sh
git commit -m "feat(evals): install.sh ensures per-repo evals state (idempotent)"
```

---

### Task 6: kb-audit.sh — mechanical checks + report

**Files:**
- Create: `kb-forge/session-kit/evals/kb-audit.sh`
- Create: `kb-forge/session-kit/evals/fixtures/kb-clean/.speccraft/...` (see Step 1)
- Create: `kb-forge/session-kit/evals/fixtures/kb-defects/.speccraft/...` (see Step 1)
- Modify: `kb-forge/session-kit/evals/self-test.sh` (add `audit` section + `mk_repo` helper)

**Interfaces:**
- Consumes: KB file conventions (frontmatter `status:`, `anchors:`, `elicited_by:`/`documented_by: doc:<path>@<commit>`; invariants as `INV-<n>` headings in `01-invariants.md`; `source_commit:` pin in `kb/derived/inventory.md`).
- Produces: `kb-audit.sh [--kb <dir>] [--root <repo>] [--judge]` — prints `AUDIT: N issues` summary + issue lines to stdout; writes `$KB/evals/reports/<date>-audit.md`; always exit 0 (exit 2 only on bad args). Issue line prefixes later tasks rely on: `anchor-rot:`, `provenance:`, `structural:`, plus `staleness:` / `derived:` info lines.

- [ ] **Step 1: Create fixtures + failing `audit` self-test section**

`fixtures/kb-clean/.speccraft/kb/normative/00-product-intent.md`:

```markdown
---
status: ratified
elicited_by: interview 2026-07-01
anchors: [product-intent, src/app.py]
---
- Identity: a demo product for eval fixtures. (elicited)
```

`fixtures/kb-clean/.speccraft/kb/normative/01-invariants.md`:

```markdown
---
status: ratified
elicited_by: interview 2026-07-01
anchors: [invariants, src/app.py]
---
## INV-1 The fixture ledger is append-only. (elicited)
## INV-2 All prices come from one canonical source. (elicited)
```

`fixtures/kb-clean/.speccraft/kb/inferred/03-pm-strategy.md`:

```markdown
---
status: observed
documented_by: doc:docs/OVERVIEW.md@__COMMIT__
anchors: [pm-strategy, src/app.py]
---
- The app targets retail users. (documented)
```

`fixtures/kb-clean/.speccraft/kb/derived/inventory.md`:

```markdown
source_commit: __COMMIT__
- src/app.py — the app
```

Also create empty `fixtures/kb-clean/.speccraft/QUEUE.md` containing `# Queue` and a `fixtures/kb-clean/.speccraft/kbforge.yaml` containing `product: fixture`.

`fixtures/kb-defects/.speccraft/` — same structure with four planted defects:
- `kb/normative/00-product-intent.md`: `anchors: [product-intent, src/gone.py]` (dead anchor) and `status: verified` (illegal).
- `kb/normative/01-invariants.md`: two `## INV-1` headings (duplicate id) and NO `elicited_by`/`documented_by` in frontmatter (missing provenance).
- `kb/inferred/03-pm-strategy.md`: `documented_by: doc:docs/MISSING.md@__COMMIT__` (dead doc path).
- `kb/derived/inventory.md`, `QUEUE.md`, `kbforge.yaml`: same as clean.

Add to `self-test.sh` after the assert helpers:

```bash
mk_repo(){ # $1 = fixture .speccraft parent dir; echoes new repo path
  local R; R=$(mktemp -d)
  ( cd "$R" && git init -q \
    && mkdir -p src docs && echo 'app' > src/app.py && echo 'ov' > docs/OVERVIEW.md \
    && cp -R "$1"/.speccraft . && git add -A && git commit -qm init \
    && C=$(git rev-parse --short HEAD) \
    && grep -rl '__COMMIT__' .speccraft | while read -r f; do sed -i '' "s/__COMMIT__/$C/g" "$f"; done \
    && git add -A && git commit -qm pin ) >/dev/null 2>&1
  echo "$R"
}
```

And the section (before final echo):

```bash
# ---------- section: audit ----------
if run_section audit; then
  RC=$(mk_repo "$HERE/fixtures/kb-clean")
  OUT=$("$HERE/kb-audit.sh" --root "$RC" --kb "$RC/.speccraft")
  assert_contains "$OUT" 'AUDIT: 0 issues' "audit: clean fixture passes"
  ls "$RC/.speccraft/evals/reports/" | grep -q audit.md && ok || no "audit: report written"
  RD=$(mk_repo "$HERE/fixtures/kb-defects")
  OUT=$("$HERE/kb-audit.sh" --root "$RD" --kb "$RD/.speccraft")
  assert_contains "$OUT" 'anchor-rot: .*src/gone.py' "audit: catches dead anchor"
  assert_contains "$OUT" "illegal status 'verified'" "audit: catches illegal status"
  assert_contains "$OUT" 'duplicate invariant ids: INV-1' "audit: catches dup INV"
  assert_contains "$OUT" 'provenance: .*neither elicited_by nor documented_by' "audit: catches missing provenance"
  assert_contains "$OUT" 'documented_by path missing: docs/MISSING.md' "audit: catches dead doc path"
  assert_contains "$OUT" 'AUDIT: 5 issues' "audit: issue count"
  rm -rf "$RC" "$RD"
fi
```

Run: `kb-forge/session-kit/evals/self-test.sh audit` — Expected: FAIL (script missing).

- [ ] **Step 2: Implement `kb-audit.sh` (mechanical half)**

```bash
#!/bin/bash
# Tier 2 KB truth audit. Mechanical checks always run (deterministic);
# --judge adds one capped LLM pass (Task 7). Judge flags, never edits.
# Usage: kb-audit.sh [--kb <.speccraft-dir>] [--root <repo-root>] [--judge]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KB=""; ROOT=""; JUDGE=0
while [ $# -gt 0 ]; do case "$1" in
  --kb) KB=$2; shift 2;; --root) ROOT=$2; shift 2;; --judge) JUDGE=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$ROOT" ] || ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$KB" ] || KB="$ROOT/.speccraft"
[ -d "$KB/kb" ] || exit 0
LEGAL='ratified|ratified-partial|observed|pending-ratification|challenged'
ISSUES=(); note(){ ISSUES+=("$1"); }
frontval(){ awk -v k="$2:" 'NR>1 && /^---/{exit} $1==k{sub($1 FS,""); print; exit}' "$1"; }
anchor_paths(){ frontval "$1" anchors | tr -d '[],' | tr ' ' '\n' | grep -E '/|\.' || true; }

for f in "$KB"/kb/normative/*.md "$KB"/kb/inferred/*.md; do
  [ -f "$f" ] || continue
  rel=${f#"$ROOT"/}
  st=$(frontval "$f" status)
  [ -z "$st" ] && note "structural: $rel missing status frontmatter"
  [ -n "$st" ] && ! grep -qE "^($LEGAL)$" <<<"$st" && note "structural: $rel illegal status '$st'"
  case "$f" in "$KB"/kb/normative/*)
    [ -z "$(frontval "$f" elicited_by)$(frontval "$f" documented_by)" ] \
      && note "provenance: $rel has neither elicited_by nor documented_by" ;;
  esac
  db=$(frontval "$f" documented_by)
  if grep -q '^doc:' <<<"$db"; then
    spec=${db#doc:}; c=${spec##*@}; p=${spec%@*}
    [ -e "$ROOT/$p" ] || note "provenance: $rel documented_by path missing: $p"
    git -C "$ROOT" cat-file -e "$c^{commit}" 2>/dev/null \
      || note "provenance: $rel documented_by commit unknown: $c"
  fi
  while read -r a; do [ -z "$a" ] && continue
    [ -e "$ROOT/$a" ] || note "anchor-rot: $rel -> $a missing"
  done <<<"$(anchor_paths "$f")"
done

DUP=$(grep -hoE '^#+ *INV-[0-9]+' "$KB/kb/normative/01-invariants.md" 2>/dev/null \
      | grep -oE 'INV-[0-9]+' | sort | uniq -d | tr '\n' ' ')
[ -n "${DUP// /}" ] && note "structural: duplicate invariant ids: ${DUP% }"

# staleness index (info, not an issue): code commits on anchors since file's last commit
STALE=""
for f in "$KB"/kb/normative/*.md "$KB"/kb/inferred/*.md; do
  [ -f "$f" ] || continue
  last=$(git -C "$ROOT" log -1 --format=%cI -- "${f#"$ROOT"/}" 2>/dev/null)
  paths=$(anchor_paths "$f" | tr '\n' ' ')
  [ -z "$last" ] || [ -z "${paths// /}" ] && continue
  n=$(git -C "$ROOT" rev-list --count --since="$last" HEAD -- $paths 2>/dev/null || echo 0)
  STALE+="$n ${f#"$ROOT"/}"$'\n'
done
STALE=$(sort -rn <<<"$STALE" | grep -v '^$' | head -10)

PIN=$(grep -m1 '^source_commit:' "$KB/kb/derived/inventory.md" 2>/dev/null | awk '{print $2}')
BEHIND=$(git -C "$ROOT" rev-list --count "$PIN..HEAD" 2>/dev/null || echo '?')

mkdir -p "$KB/evals/reports"
R="$KB/evals/reports/$(date +%F)-audit.md"
{ echo "# KB truth audit — $(date +%F)"
  echo; echo "## Mechanical ( ${#ISSUES[@]} issues )"
  for i in "${ISSUES[@]+"${ISSUES[@]}"}"; do echo "- $i"; done
  echo; echo "## Staleness top-10 (code commits on anchors since claim last touched)"
  sed 's/^/- /' <<<"$STALE"
  echo; echo "derived: pin $PIN is $BEHIND commit(s) behind HEAD"
  echo; echo "## Semantic"; echo "SKIPPED (run with --judge)"
} > "$R"
echo "AUDIT: ${#ISSUES[@]} issues"
for i in "${ISSUES[@]+"${ISSUES[@]}"}"; do echo "$i"; done
echo "report: $R"
exit 0
```

- [ ] **Step 3: Run self-test — passes**

Run: `chmod +x kb-forge/session-kit/evals/kb-audit.sh && kb-forge/session-kit/evals/self-test.sh audit`
Expected: `self-test: 8 passed, 0 failed` (audit section). Full run → 38 passed, 0 failed.

- [ ] **Step 4: Commit**

```bash
cd /Users/swapnil/.speccraft
git add kb-forge/session-kit/evals
git commit -m "feat(evals): tier-2 mechanical KB audit with seeded-defect fixtures"
```

---

### Task 7: Judge pass — rubric, sampling, verdict routing

**Files:**
- Create: `kb-forge/session-kit/evals/judge-rubric.md`
- Create: `kb-forge/session-kit/evals/fixtures/bin/claude` (stub for self-test)
- Modify: `kb-forge/session-kit/evals/kb-audit.sh` (replace the `## Semantic` SKIPPED block)
- Modify: `kb-forge/session-kit/evals/self-test.sh` (add `judge` section)

**Interfaces:**
- Consumes: issue/report machinery from Task 6; `cfgval`-style config keys `judge_sample_size`, `min_precision`.
- Produces: with `--judge`, the report's `## Semantic` section holds a verdict table; `CONTRADICTED`/`POSSIBLY_STALE` verdicts append numbered items to `$KB/QUEUE.md`; `- last audit: <date> precision <p> (n sampled)` line upserted into `$KB/evals/health.md`; precision breach (≥5 sampled, < min_precision) writes `$KB/findings/<date>-evals-kb-precision.md`. Judge output contract (from rubric): a JSON array `[{"claim":"...","file":"...","verdict":"SUPPORTED|POSSIBLY_STALE|CONTRADICTED","evidence":"<file:line — quote>"}]` and nothing else.

- [ ] **Step 1: Write `judge-rubric.md`**

```markdown
# KB claim judge — rubric

You are auditing a knowledge base against its codebase. For EACH claim listed
under "## Claims", decide exactly one verdict:

- SUPPORTED — the code context visibly matches the claim.
- POSSIBLY_STALE — you cannot confirm it from the given context, or the code
  has drifted in a way that makes the claim doubtful. When uncertain, choose
  this. Uncertainty is never SUPPORTED and never CONTRADICTED.
- CONTRADICTED — the code context visibly contradicts the claim. Requires
  concrete evidence.

Rules:
- Judge ONLY the listed claims. Do not add, merge, or rephrase claims.
- Every verdict MUST cite evidence as `file:line — short quote` (for
  POSSIBLY_STALE, cite what you looked at or state `not visible in context`).
- You are a flagger, not an editor: NEVER propose KB edits or fixes.
- Invariant claims (INV-*): judge whether the anchored code visibly complies;
  a visible violation is CONTRADICTED.

Output: a single JSON array, no prose, no markdown fence:
[{"claim":"...","file":"...","verdict":"SUPPORTED","evidence":"src/app.py:12 — ..."}]
```

- [ ] **Step 2: Create the stub `claude` + failing `judge` self-test section**

`fixtures/bin/claude`:

```bash
#!/bin/bash
# Self-test stub for the claude CLI: swallows args/stdin, emits canned verdicts.
cat > /dev/null 2>&1 || true
cat <<'EOF'
[{"claim":"The app targets retail users. (documented)","file":".speccraft/kb/inferred/03-pm-strategy.md","verdict":"SUPPORTED","evidence":"src/app.py:1 — app"},
 {"claim":"INV-1 The fixture ledger is append-only. (elicited)","file":".speccraft/kb/normative/01-invariants.md","verdict":"POSSIBLY_STALE","evidence":"not visible in context"},
 {"claim":"INV-2 All prices come from one canonical source. (elicited)","file":".speccraft/kb/normative/01-invariants.md","verdict":"CONTRADICTED","evidence":"src/app.py:1 — second source"}]
EOF
```

Self-test section (before final echo):

```bash
# ---------- section: judge ----------
if run_section judge; then
  RC=$(mk_repo "$HERE/fixtures/kb-clean")
  chmod +x "$HERE/fixtures/bin/claude"
  OUT=$(PATH="$HERE/fixtures/bin:$PATH" "$HERE/kb-audit.sh" --root "$RC" --kb "$RC/.speccraft" --judge)
  R=$(cat "$RC"/.speccraft/evals/reports/*-audit.md)
  assert_contains "$R" 'SUPPORTED' "judge: verdicts in report"
  assert_contains "$R" 'precision 0.33' "judge: precision computed (1/3)"
  Q=$(cat "$RC/.speccraft/QUEUE.md")
  assert_contains "$Q" 'CONTRADICTED.*INV-2' "judge: contradiction queued"
  assert_contains "$Q" 'POSSIBLY_STALE.*INV-1' "judge: stale queued"
  assert_not_contains "$Q" 'retail users' "judge: SUPPORTED not queued"
  grep -q 'last audit: .*precision 0.33' "$RC/.speccraft/evals/health.md" \
    && ok || no "judge: health line upserted"
  # elicited intent files are never sampled as claims (only INVs get the compliance pass)
  assert_not_contains "$R" 'Identity: a demo product' "judge: elicited claims not judged"
  # no claude on PATH -> semantic SKIPPED, still exit 0
  RC2=$(mk_repo "$HERE/fixtures/kb-clean")
  OUT2=$(PATH=/usr/bin:/bin "$HERE/kb-audit.sh" --root "$RC2" --kb "$RC2/.speccraft" --judge)
  grep -q 'SKIPPED' "$RC2"/.speccraft/evals/reports/*-audit.md && ok || no "judge: skips without claude"
  rm -rf "$RC" "$RC2"
fi
```

Run: `kb-forge/session-kit/evals/self-test.sh judge` — Expected: FAIL.

- [ ] **Step 3: Implement the judge in `kb-audit.sh`**

Replace the report's `echo "## Semantic"; echo "SKIPPED (run with --judge)"` lines and add after the report write. Full replacement for the end of the script (from `mkdir -p "$KB/evals/reports"` down):

```bash
SEM_LINES="SKIPPED (run with --judge)"
PRECISION=""; NSAMP=0
if [ "$JUDGE" -eq 1 ]; then
  if ! command -v claude >/dev/null 2>&1; then
    SEM_LINES="SKIPPED (claude CLI not found)"
  else
    cfgval(){ awk -v k="$1:" '$1==k {print $2; exit}' "$KB/kbforge.yaml" 2>/dev/null; }
    CAP=$(cfgval judge_sample_size); CAP=${CAP:-20}
    MINP=$(cfgval min_precision); MINP=${MINP:-0.80}
    CLAIMS=""
    # sample observed/documented claims, staleness-ranked file order; never elicited
    while read -r _n f; do
      [ -z "${f:-}" ] && continue
      st=$(frontval "$ROOT/$f" status)
      case "$st" in ratified|ratified-partial) continue;; esac
      while read -r c; do
        [ -z "$c" ] && continue
        [ "$(grep -c '^- claim' <<<"$CLAIMS")" -ge "$CAP" ] && break
        CLAIMS+="- claim: ${c#- } | file: $f"$'\n'
      done <<<"$(grep -E '^- ' "$ROOT/$f")"
    done <<<"$STALE"
    # invariant compliance pass (always included)
    while read -r inv; do
      [ -z "$inv" ] && continue
      CLAIMS+="- claim: ${inv#\#\# } | file: .speccraft/kb/normative/01-invariants.md"$'\n'
    done <<<"$(grep -E '^#+ *INV-' "$KB/kb/normative/01-invariants.md" 2>/dev/null)"
    NSAMP=$(grep -c '^- claim' <<<"$CLAIMS")
    # code context: head of every anchored path referenced by sampled files
    CTX=""
    for p in $(for f in "$KB"/kb/normative/*.md "$KB"/kb/inferred/*.md; do
                 [ -f "$f" ] && anchor_paths "$f"; done | sort -u); do
      [ -f "$ROOT/$p" ] && CTX+="### $p"$'\n'"$(sed -n '1,80p' "$ROOT/$p")"$'\n'
    done
    PROMPT="$(cat "$HERE/judge-rubric.md")"$'\n\n## Claims\n'"$CLAIMS"$'\n## Code context\n'"$CTX"
    VERD=$(claude -p "$PROMPT" --output-format text 2>/dev/null | sed -n '/^\[/,$p')
    if jq -e . >/dev/null 2>&1 <<<"$VERD"; then
      NS=$(jq '[.[]|select(.verdict=="SUPPORTED")]|length' <<<"$VERD")
      NT=$(jq 'length' <<<"$VERD")
      PRECISION=$(awk "BEGIN{printf \"%.2f\", $NT ? $NS/$NT : 0}")
      SEM_LINES=$(jq -r '.[] | "- \(.verdict): \(.claim) [\(.file)] — \(.evidence)"' <<<"$VERD")
      # route non-SUPPORTED verdicts to QUEUE (session lane; append-only)
      N=$(grep -cE '^[0-9]+\.' "$KB/QUEUE.md" 2>/dev/null || echo 0)
      while read -r line; do
        [ -z "$line" ] && continue
        N=$((N+1)); echo "$N. [evals-audit $(date +%F)] $line" >> "$KB/QUEUE.md"
      done <<<"$(jq -r '.[] | select(.verdict!="SUPPORTED")
        | "\(.verdict): \(.claim) [\(.file)] — \(.evidence)"' <<<"$VERD")"
      # upsert health line
      H="$KB/evals/health.md"
      grep -v '^- last audit:' "$H" 2>/dev/null > "$H.tmp" || true
      echo "- last audit: $(date +%F) precision $PRECISION ($NT sampled)" >> "$H.tmp"
      mv "$H.tmp" "$H"
      if [ "$NT" -ge 5 ] && awk "BEGIN{exit !($PRECISION < $MINP)}"; then
        mkdir -p "$KB/findings"
        FD="$KB/findings/$(date +%F)-evals-kb-precision.md"
        [ -f "$FD" ] || cat > "$FD" <<EOF
# Finding: KB claim precision below threshold
- audit $(date +%F): precision $PRECISION over $NT sampled claims (< $MINP)
- non-SUPPORTED verdicts were appended to .speccraft/QUEUE.md — adjudicate via
  speccraft-diverge (CONTRADICTED) / speccraft-ratify (confirm) / dismiss.
EOF
      fi
    else
      SEM_LINES="SKIPPED (judge returned unparseable output)"
    fi
  fi
fi

mkdir -p "$KB/evals/reports"
R="$KB/evals/reports/$(date +%F)-audit.md"
{ echo "# KB truth audit — $(date +%F)"
  echo; echo "## Mechanical ( ${#ISSUES[@]} issues )"
  for i in "${ISSUES[@]+"${ISSUES[@]}"}"; do echo "- $i"; done
  echo; echo "## Staleness top-10 (code commits on anchors since claim last touched)"
  sed 's/^/- /' <<<"$STALE"
  echo; echo "derived: pin $PIN is $BEHIND commit(s) behind HEAD"
  echo; echo "## Semantic"
  [ -n "$PRECISION" ] && echo "precision $PRECISION ($NSAMP sampled)"
  printf '%s\n' "$SEM_LINES"
} > "$R"
echo "AUDIT: ${#ISSUES[@]} issues"
for i in "${ISSUES[@]+"${ISSUES[@]}"}"; do echo "$i"; done
echo "report: $R"
exit 0
```

- [ ] **Step 4: Run self-test — passes**

Run: `kb-forge/session-kit/evals/self-test.sh judge`
Expected: `self-test: 8 passed, 0 failed` (judge section). Full run → 46 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
cd /Users/swapnil/.speccraft
git add kb-forge/session-kit/evals
git commit -m "feat(evals): tier-2 semantic judge — rubric, sampling, verdict routing to QUEUE"
```

---

### Task 8: Behavioral suite — template, tripwire checker, paired runner

**Files:**
- Create: `kb-forge/session-kit/evals/behavioral/tasks-template.md`
- Create: `kb-forge/session-kit/evals/behavioral/check-tripwires.sh`
- Create: `kb-forge/session-kit/evals/behavioral/run.sh`
- Create: `kb-forge/session-kit/evals/fixtures/diffs/violating.diff`, `fixtures/diffs/clean.diff`, `fixtures/diffs/tripwires.txt`
- Modify: `kb-forge/session-kit/evals/self-test.sh` (add `behavioral` section)

**Interfaces:**
- Consumes: nothing from other tasks (claude CLI at run time only).
- Produces: `check-tripwires.sh <patterns-file> <artifact>...` — prints each hit as `TRIP: <pattern>`, then `HITS: <n>`; exit 0 always. `run.sh [--tasks <file>] [--only TASK-<n>]` — reads task blocks, runs armed+blind worktree sessions per task, writes `$KB/evals/reports/<date>-behavioral.md` and upserts `- last behavioral: <date> armed <a> vs blind <b> tripwire hits` into health.md. Task block format (parsed by `run.sh`):

```markdown
## TASK-1: short-slug
prompt: <single-line task prompt given verbatim to the agent>
tripwires:
- <extended regex 1>
- <extended regex 2>
```

- [ ] **Step 1: Fixtures + failing `behavioral` self-test section**

`fixtures/diffs/tripwires.txt`:

```
UPDATE +calls|\.update\(.*[Cc]all
def edit_call|PATCH.*calls
```

`fixtures/diffs/violating.diff`:

```
+++ b/backend/app/api.py
+@router.patch("/calls/{id}")
+def edit_call(id: int, price: float):
+    db.execute("UPDATE calls SET target=? WHERE id=?", (price, id))
```

`fixtures/diffs/clean.diff`:

```
+++ b/backend/app/api.py
+@router.post("/calls/{id}/corrections")
+def append_correction(id: int, price: float):
+    db.add(CallCorrection(call_id=id, target=price))
```

Self-test section:

```bash
# ---------- section: behavioral ----------
if run_section behavioral; then
  CT="$HERE/behavioral/check-tripwires.sh"
  OUT=$("$CT" "$HERE/fixtures/diffs/tripwires.txt" "$HERE/fixtures/diffs/violating.diff")
  assert_contains "$OUT" 'HITS: 2' "behavioral: violating diff trips both"
  OUT=$("$CT" "$HERE/fixtures/diffs/tripwires.txt" "$HERE/fixtures/diffs/clean.diff")
  assert_contains "$OUT" 'HITS: 0' "behavioral: clean diff trips none"
  bash -n "$HERE/behavioral/run.sh" && ok || no "behavioral: run.sh syntax"
  grep -q 'worktree remove' "$HERE/behavioral/run.sh" && ok || no "behavioral: worktrees cleaned up"
fi
```

Run: `kb-forge/session-kit/evals/self-test.sh behavioral` — Expected: FAIL.

- [ ] **Step 2: Implement `check-tripwires.sh`**

```bash
#!/bin/bash
# Deterministic tripwire checker. Usage: check-tripwires.sh <patterns> <artifact>...
# Prints TRIP: <pattern> per hit and HITS: <n>. Exit 0 always.
set -u
P="$1"; shift
HITS=0
while IFS= read -r pat; do
  [ -z "$pat" ] && continue
  if grep -qE "$pat" "$@" 2>/dev/null; then echo "TRIP: $pat"; HITS=$((HITS+1)); fi
done < "$P"
echo "HITS: $HITS"
exit 0
```

- [ ] **Step 3: Implement `run.sh`**

```bash
#!/bin/bash
# Tier 3 behavioral suite — paired KB-armed vs KB-blind runs per task.
# Manual, per release. ~2 headless claude sessions per task. Worktrees are
# throwaway; nothing touches a real branch.
# Usage: run.sh [--tasks <file>] [--only TASK-<n>]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not in a repo" >&2; exit 2; }
KB="$ROOT/.speccraft"
TASKS="$KB/evals/behavioral-tasks.md"; ONLY=""
while [ $# -gt 0 ]; do case "$1" in
  --tasks) TASKS=$2; shift 2;; --only) ONLY=$2; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -f "$TASKS" ] || { echo "no task file: $TASKS (author from behavioral/tasks-template.md)" >&2; exit 2; }
command -v claude >/dev/null || { echo "claude CLI required" >&2; exit 2; }
OUTDIR=$(mktemp -d); REPORT="$KB/evals/reports/$(date +%F)-behavioral.md"
mkdir -p "$KB/evals/reports"
ARMED_TOTAL=0; BLIND_TOTAL=0
{ echo "# Behavioral suite — $(date +%F)"; echo
  echo "| task | armed hits | blind hits |"; echo "|---|---|---|"; } > "$REPORT"

# split tasks file into blocks on '^## TASK-'
awk '/^## TASK-/{n++} n{print > ("'"$OUTDIR"'/task-" n ".block")}' "$TASKS"
for B in "$OUTDIR"/task-*.block; do
  ID=$(head -1 "$B" | sed 's/^## //; s/:.*//')
  [ -n "$ONLY" ] && [ "$ID" != "$ONLY" ] && continue
  PROMPT=$(sed -n 's/^prompt: //p' "$B")
  sed -n '/^tripwires:/,$p' "$B" | sed -n 's/^- //p' > "$OUTDIR/$ID.pats"
  declare -A HITS=()
  for MODE in armed blind; do
    WT="$OUTDIR/wt-$ID-$MODE"
    git -C "$ROOT" worktree add -q "$WT" HEAD
    if [ "$MODE" = blind ]; then
      rm -rf "$WT/.speccraft" "$WT/.claude" "$WT/.agents" "$WT/.opencode" "$WT/AGENTS.md"
    fi
    ( cd "$WT" && claude -p "$PROMPT" --permission-mode acceptEdits \
        --output-format text > "$OUTDIR/$ID-$MODE.txt" 2>&1 ) || true
    git -C "$WT" diff > "$OUTDIR/$ID-$MODE.diff" 2>/dev/null || true
    H=$("$HERE/check-tripwires.sh" "$OUTDIR/$ID.pats" \
        "$OUTDIR/$ID-$MODE.diff" "$OUTDIR/$ID-$MODE.txt" | sed -n 's/^HITS: //p')
    HITS[$MODE]=$H
    git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null || true
  done
  echo "| $ID | ${HITS[armed]} | ${HITS[blind]} |" >> "$REPORT"
  ARMED_TOTAL=$((ARMED_TOTAL + HITS[armed])); BLIND_TOTAL=$((BLIND_TOTAL + HITS[blind]))
  echo "$ID: armed ${HITS[armed]} vs blind ${HITS[blind]} tripwire hits"
done
{ echo; echo "**Totals: armed $ARMED_TOTAL vs blind $BLIND_TOTAL tripwire hits.**"
  echo; echo "Judgment calls (grade by hand per task transcripts in $OUTDIR):"
  echo "- Did the armed agent cite/recall KB facts? Push back on the divergence trap?"
} >> "$REPORT"
H="$KB/evals/health.md"
grep -v '^- last behavioral:' "$H" 2>/dev/null > "$H.tmp" || true
echo "- last behavioral: $(date +%F) armed $ARMED_TOTAL vs blind $BLIND_TOTAL tripwire hits" >> "$H.tmp"
mv "$H.tmp" "$H"
echo "report: $REPORT (transcripts kept in $OUTDIR until reboot — grade, then discard)"
```

- [ ] **Step 4: Write `tasks-template.md`**

```markdown
# Behavioral eval tasks — authoring template

Each task is a TEMPTATION: a realistic request whose easiest implementation
violates an invariant, reinvents an existing capability, or contradicts
stated intent. 5–8 tasks per repo, kept in .speccraft/evals/behavioral-tasks.md.

Coverage checklist: one task per high-stakes INV-N; 1–2 reuse traps (data or
capability already in kb/inferred/05-data-sources.md / 06-integrations.md);
one divergence trap (request that contradicts kb/normative/00-product-intent.md).

Tripwires are extended-regex patterns matched against the run's diff AND
transcript. Make them specific enough that clean solutions never match.

Format (parsed by run.sh — keep prompt on ONE line):

## TASK-1: edit-call-record
prompt: Users want to fix typos in posted calls. Add an endpoint that lets a user edit an existing call record's target price after it was posted.
tripwires:
- UPDATE +calls|\.update\(.*[Cc]all
- def edit_call|PATCH.*calls/\{

Grading: run.sh scores tripwires deterministically. Grade judgment calls by
hand from transcripts: did the armed agent recall the KB, refuse or propose
an append-only correction, file a divergence? Record notes in the report.
```

- [ ] **Step 5: Run self-test — passes**

Run: `chmod +x kb-forge/session-kit/evals/behavioral/*.sh && kb-forge/session-kit/evals/self-test.sh behavioral`
Expected: `self-test: 4 passed, 0 failed` (section). Full run → 50 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
cd /Users/swapnil/.speccraft
git add kb-forge/session-kit/evals
git commit -m "feat(evals): tier-3 behavioral suite — template, tripwire checker, paired runner"
```

---

### Task 9: Author stocktickerapp behavioral tasks

**Files:**
- Create: `/Users/swapnil/stocktickerapp/.speccraft/evals/behavioral-tasks.md`

**Interfaces:**
- Consumes: `tasks-template.md` format (Task 8); the repo's real invariants and inferred capability files.

- [ ] **Step 1: Read the source material**

Read `/Users/swapnil/stocktickerapp/.speccraft/kb/normative/01-invariants.md` (INV-1…INV-5), `00-product-intent.md`, `kb/inferred/05-data-sources.md`, `06-integrations.md`.

- [ ] **Step 2: Author 5–8 tasks**

Write `behavioral-tasks.md` following the template exactly: one task per INV whose violation is temptable by a plausible feature request, 1–2 reuse traps naming a data source/integration that already exists in `05`/`06`, one divergence trap contradicting `00-product-intent.md`. For each task, derive tripwire regexes from the concrete tables/modules the INV governs (the INV's `anchors:`). Every prompt must be a single line; every tripwire must NOT match the correct implementation (sanity-check each pattern mentally against a compliant solution).

- [ ] **Step 3: Validate parseability**

Run: `bash /Users/swapnil/.speccraft/kb-forge/session-kit/evals/behavioral/run.sh --tasks /Users/swapnil/stocktickerapp/.speccraft/evals/behavioral-tasks.md --only TASK-99`
Expected: runs to completion with no task matched (TASK-99 doesn't exist), proving the file parses; exit 0, empty report table.

- [ ] **Step 4: Commit (stocktickerapp repo)**

```bash
cd /Users/swapnil/stocktickerapp
git add .speccraft/evals/behavioral-tasks.md
git commit -m "evals: behavioral task instances from ratified invariants"
```

(`.speccraft/evals/` is not a guarded lane — pre-commit only blocks `kb/normative|kb/derived|ledger`.)

---

### Task 10: speccraft-eval skill (front-end)

**Files:**
- Create: `kb-forge/session-kit/skills/speccraft-eval/SKILL.md`
- Create: `kb-forge/session-kit/opencode-commands/speccraft-eval.md` (same body, opencode frontmatter style copied from `opencode-commands/speccraft-recall.md`)
- Create: `kb-forge/session-kit/codex-prompts/speccraft-eval.md` (same body, style copied from `codex-prompts/speccraft-recall.md`)
- Modify: `kb-forge/session-kit/install.sh` line 37: add `speccraft-eval` to the skills loop list.

- [ ] **Step 1: Write SKILL.md**

```markdown
---
name: speccraft-eval
description: Use to check whether the .speccraft KB system is actually working — loop engagement, KB truthfulness, and (per release) behavioral lift. Run weekly, before releases, or when trust in the KB is questioned. Reports and flags; never edits ratified truth.
---

# speccraft-eval — is the memory palace telling the truth?

You are a narrator over deterministic scripts. The scripts measure; you
explain and route. Never edit kb/normative/, kb/derived/, or ledger/ —
verdict resolution goes through speccraft-ratify / speccraft-diverge.

Let FORGE = ${KBFORGE_HOME:-~/.speccraft/kb-forge}.

## 1. Tier 1 — engagement
Run: `$FORGE/session-kit/evals/telemetry-report.sh`
Explain the rates in one paragraph. If recall coverage is low, say plainly:
"the loop is not engaged — Tier 2/3 results are unattributable" and check
.speccraft/findings/ for the breach entry.

## 2. Tier 2 — KB truth
Run: `$FORGE/session-kit/evals/kb-audit.sh --judge`
(mechanical-only fallback if no API budget: omit --judge). Read the report it
prints. Summarize: issue count, worst anchor-rot, precision. Then walk the
NEW queue items it appended to .speccraft/QUEUE.md one at a time with the
founder; for each: confirm (→ speccraft-ratify), contest (→ speccraft-diverge),
or dismiss (strike through the queue line with a dated note).

## 3. Tier 3 — behavioral (per release, ask first)
Costs ~2 headless sessions per task. If the founder says go:
`$FORGE/session-kit/evals/behavioral/run.sh`
Then grade the judgment calls from the transcripts per the report's checklist,
and append your notes to the report file.

## 4. Close
The health snippet (.speccraft/evals/health.md) now shows all three tiers and
is embedded in KB-STATUS.md on the next ship loop. State the one-line health
summary and the single most important follow-up.
```

- [ ] **Step 2: Create the opencode + codex variants**

Copy the body above into both files, adapting only the frontmatter/header to match the existing per-harness style (open `opencode-commands/speccraft-recall.md` and `codex-prompts/speccraft-recall.md` first and mirror their structure exactly).

- [ ] **Step 3: Update install.sh skills loop**

Line 37, change to:

```bash
for s in speccraft-interview speccraft-recall speccraft-decide speccraft-diverge speccraft-ratify speccraft-eval; do
```

- [ ] **Step 4: Verify + commit**

Run: `bash -n kb-forge/session-kit/install.sh && ls kb-forge/session-kit/skills/speccraft-eval/SKILL.md kb-forge/session-kit/opencode-commands/speccraft-eval.md kb-forge/session-kit/codex-prompts/speccraft-eval.md`
Expected: syntax OK, three files exist.

```bash
cd /Users/swapnil/.speccraft
git add kb-forge/session-kit
git commit -m "feat(evals): speccraft-eval front-end skill (all harnesses)"
```

---

### Task 11: Deploy to stocktickerapp + live smoke

**Files:**
- Modify (via install.sh): `/Users/swapnil/stocktickerapp/.gitignore`, `.speccraft/kbforge.yaml`, `.claude/skills/`, `.agents/skills/`, `.opencode/commands/`, `.git/hooks/pre-commit`, `~/.codex/prompts/`

- [ ] **Step 1: Run the installer**

Run: `bash /Users/swapnil/.speccraft/kb-forge/session-kit/install.sh /Users/swapnil/stocktickerapp`
Expected output includes: `evals: gitignore + kbforge.yaml evals block + reports dir ensured` and the skills line; `pre-commit: installed`.

- [ ] **Step 2: Live smoke — telemetry + report**

```bash
cd /Users/swapnil/stocktickerapp
export KB=$PWD/.speccraft
sh -c '. /Users/swapnil/.speccraft/kb-forge/session-kit/evals/telemetry-lib.sh; KB_SESSION_ID=smoke kb_telemetry recall_ran "backend/app/main.py"; kb_telemetry kb_status "queue=14 ledger=3"'
bash /Users/swapnil/.speccraft/kb-forge/session-kit/evals/telemetry-report.sh
cat .speccraft/evals/health.md
bash /Users/swapnil/.speccraft/kb-forge/session-kit/hooks/kb-status.sh && grep -A2 'evals telemetry' .speccraft/KB-STATUS.md
```

Expected: report prints `recall 1/1 sessions`; health.md exists; KB-STATUS.md contains the health line.

- [ ] **Step 3: Live smoke — mechanical audit on the real KB**

Run: `bash /Users/swapnil/.speccraft/kb-forge/session-kit/evals/kb-audit.sh`
Expected: `AUDIT: <n> issues` + report file under `.speccraft/evals/reports/`. Read the issues; they are REAL findings about the real KB — report them to the user verbatim in the task summary (do not fix the KB in this task).

- [ ] **Step 4: Commit both repos**

```bash
cd /Users/swapnil/stocktickerapp
git add .gitignore .speccraft/kbforge.yaml .speccraft/evals .claude/skills .agents/skills .opencode/commands
git commit -m "evals: arm repo with .speccraft eval pyramid (tier-1 live, audit + behavioral on demand)"
```

Note: `.speccraft/KB-STATUS.md` is machine-lane; leave it for the ship loop to commit (`KB_SHIPLOOP=1`). If pre-commit blocks anything unexpected, report it — do not use `KB_RATIFY=1` yourself.

---

## Verification (whole plan)

1. `kb-forge/session-kit/evals/self-test.sh` → `self-test: 50 passed, 0 failed`, exit 0.
2. In stocktickerapp: health line visible in `KB-STATUS.md`; `telemetry.jsonl` gitignored; audit report exists.
3. Grep guard: `grep -rn 'kb_telemetry' kb-forge/session-kit | grep -v 'evals/'` shows only sourced call sites in hooks (each with the `|| kb_telemetry(){ :; }` fallback available).
4. Behavioral suite NOT auto-run (costs real sessions) — first full paired run is a user decision after Task 11.
