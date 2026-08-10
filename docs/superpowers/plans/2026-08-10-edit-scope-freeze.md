# Edit-Scope Freeze — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Confine each fanned-out agent to an orchestrator-assigned edit lane; hard-deny out-of-lane edits (agent escalates, never self-widens). Dormant unless a lane is assigned.

**Architecture:** A PreToolUse hook `kb-freeze.sh` (matcher `Edit|Write|MultiEdit`) reads the session's lane (from a session-keyed file, or the `SPECCRAFT_FREEZE` env as fallback) and denies edits whose repo-relative path is outside every lane prefix. The orchestrator sets `SPECCRAFT_FREEZE` at fan-out; a SessionStart step materializes it to `$TMPDIR/speccraft-freeze-$SID`. Reuses the exact setup pattern of `kb-recall-gate.sh`. No product code, no KB schema change.

**Tech Stack:** POSIX/bash hooks (jq), the existing `session-kit/evals/` bash test harness.

## Global Constraints

- **Fail-open by construction:** no lane assigned (no file AND no env) → `exit 0` (allow). A malformed/empty lane → treat as unfrozen (allow), never block-all.
- **Reuse the `kb-recall-gate.sh` hook prologue verbatim:** `ROOT=$(git rev-parse --show-toplevel) || exit 0`; `KB="$ROOT/.speccraft"`; `FORGE="${KBFORGE_HOME:-$HOME/.speccraft/kb-forge}"`; `[ -f "$KB/kbforge.yaml" ] || exit 0`; read `IN=$(cat)`, `FP=…tool_input.file_path`, `SID=…session_id`; `case "$FP"` → `"$KB"/*) exit 0` (KB is kb-guard's job), `"$ROOT"/*) REL="${FP#"$ROOT"/}"`, `*) exit 0`. Use the hook's telemetry call (`kb_telemetry …`) the same way `kb-recall-gate.sh` does.
- **Deny JSON (compact, matches existing hooks):** `jq -nc --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'`.
- **Lane file:** `${TMPDIR:-/tmp}/speccraft-freeze-$SID`, one path prefix per line.
- **In-lane rule (proper boundary):** `REL` is in-lane iff, for some prefix `p` (trailing `/` stripped), `REL == p` **or** `REL` starts with `p + "/"`. So lane `a/b/crypto` matches `a/b/crypto/x.py` and `a/b/crypto` but NOT `a/b/crypto_old.py` or `a/b/cryptozoology/`.
- **Tests:** `session-kit/evals/test-freeze.sh`, styled like `test-seams.sh` (`set -euo pipefail`, own `pass`/`fail`/`ok`/`bad`), ending `echo "freeze: $pass passed, $fail failed"` + `[ "$fail" -eq 0 ]`; wired into `self-test.sh` as a `freeze` section modeled on `seams`/`queueteeth`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `session-kit/hooks/kb-freeze.sh` | PreToolUse enforce (deny out-of-lane) + `--set` writer | **Create** |
| `session-kit/hooks/kb-briefing.sh` | SessionStart: materialize `SPECCRAFT_FREEZE`→lane file; show active lane | **Modify** |
| `session-kit/settings.json` | Register `kb-freeze.sh` in PreToolUse (between `kb-guard` and `kb-recall-gate`) | **Modify** |
| `session-kit/skills/speccraft-freeze/SKILL.md` + codex/opencode mirrors | Orchestrator lane-assignment reference | **Create** |
| `SPEC.md` | Document freeze + `SPECCRAFT_FREEZE` | **Modify** |
| `session-kit/evals/test-freeze.sh` + `self-test.sh` | The suite + wire-in | **Create/Modify** |

---

## Task 1: `kb-freeze.sh` — the enforce hook + `--set`

**Files:** Create `session-kit/hooks/kb-freeze.sh`; Create `session-kit/evals/test-freeze.sh`.

**Interfaces:**
- Consumes: tool_input JSON (`file_path`, `session_id`); lane from `$TMPDIR/speccraft-freeze-$SID` or `SPECCRAFT_FREEZE` env.
- Produces: `exit 0` (allow) or a `permissionDecision:"deny"` blob (out-of-lane). `--set [--sid <sid>] <paths…>` writes the lane file.

- [ ] **Step 1: Write the failing test**

Create `session-kit/evals/test-freeze.sh`:

```bash
#!/usr/bin/env bash
# Phase-3 edit-scope freeze assertions.
set -euo pipefail
FORGE="$(cd "$(dirname "$0")/../.." && pwd)"   # .../speccraft/forge
HOOK="$FORGE/session-kit/hooks/kb-freeze.sh"
TMP="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# a git repo with a .speccraft
G="$TMP/repo"; mkdir -p "$G/.speccraft"
( cd "$G" && git init -q && git config user.email t@t && git config user.name t )
printf 'repo: %s\n' "$G" > "$G/.speccraft/kbforge.yaml"

# run the hook for a rel path + session id, with a given TMPDIR (so the lane file is found)
run() { # $1=rel $2=sid ; env SPECCRAFT_FREEZE optional
  printf '{"tool_input":{"file_path":"%s"},"session_id":"%s"}' "$G/$1" "$2" \
    | ( cd "$G" && KBFORGE_HOME="$FORGE" TMPDIR="$TMP" bash "$HOOK" 2>/dev/null )
}
setlane() { printf '%s\n' "$@" | tr ' ' '\n' | sed '/^$/d' > "$TMP/speccraft-freeze-$1"; }  # $1=sid, rest handled by caller

echo "== unfrozen session allows any edit =="
OUT=$(run "backend/app/billing.py" u1)
[ -z "$OUT" ] && ok "no lane file -> allow" || bad "unfrozen allow"

echo "== in-lane allows, out-of-lane denies =="
printf 'backend/worker/crypto\n' > "$TMP/speccraft-freeze-s1"
OUT=$(run "backend/worker/crypto/gen.py" s1); [ -z "$OUT" ] && ok "in-lane allowed" || bad "in-lane allowed"
OUT=$(run "backend/app/billing.py" s1)
printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"' && printf '%s' "$OUT" | grep -q 'backend/worker/crypto' && ok "out-of-lane denied, names lane" || bad "out-of-lane denied"

echo "== prefix boundary (crypto != crypto_old / cryptozoology) =="
OUT=$(run "backend/worker/crypto_old.py" s1); printf '%s' "$OUT" | grep -q deny && ok "crypto_old denied" || bad "crypto_old boundary"
OUT=$(run "backend/worker/cryptozoology/z.py" s1); printf '%s' "$OUT" | grep -q deny && ok "cryptozoology denied" || bad "cryptozoology boundary"

echo "== multiple lanes =="
printf 'backend/worker/crypto\nbackend/app/services/crypto\n' > "$TMP/speccraft-freeze-s2"
OUT=$(run "backend/app/services/crypto/x.py" s2); [ -z "$OUT" ] && ok "second lane allowed" || bad "second lane"
OUT=$(run "frontend/x.tsx" s2); printf '%s' "$OUT" | grep -q deny && ok "neither lane denied" || bad "neither lane"

echo "== .speccraft not gated by freeze (kb-guard's job) =="
OUT=$(run ".speccraft/kb/normative/00.md" s1); [ -z "$OUT" ] && ok ".speccraft not freeze-gated" || bad ".speccraft freeze-gated"

echo "== env SPECCRAFT_FREEZE used when no file =="
OUT=$(printf '{"tool_input":{"file_path":"%s"},"session_id":"e1"}' "$G/backend/app/billing.py" \
  | ( cd "$G" && KBFORGE_HOME="$FORGE" TMPDIR="$TMP" SPECCRAFT_FREEZE="backend/worker/crypto" bash "$HOOK" 2>/dev/null ))
printf '%s' "$OUT" | grep -q deny && ok "env lane enforced (no file)" || bad "env lane"

echo "== --set writes/widens the lane file =="
( cd "$G" && KBFORGE_HOME="$FORGE" TMPDIR="$TMP" bash "$HOOK" --set --sid s3 backend/app/billing >/dev/null 2>&1 )
OUT=$(run "backend/app/billing/charge.py" s3); [ -z "$OUT" ] && ok "--set lane allows" || bad "--set lane"

echo "freeze: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-freeze.sh`
Expected: FAIL — `kb-freeze.sh` does not exist.

- [ ] **Step 3: Write `kb-freeze.sh`**

Open `kb-recall-gate.sh` and copy its prologue (ROOT/KB/FORGE/kbforge-guard/telemetry-load/IN/FP/SID/case→REL) verbatim into `kb-freeze.sh`, then implement the freeze logic. Structure:

```bash
#!/usr/bin/env bash
# PreToolUse (Edit|Write|MultiEdit): confine edits to the session's assigned lane.
# Dormant unless a lane is assigned (SPECCRAFT_FREEZE env or the session lane file).

# --- --set mode: orchestrator writes/widens a session's lane ---
if [ "${1:-}" = "--set" ]; then
  shift; SID="${SPECCRAFT_SID:-}"
  if [ "${1:-}" = "--sid" ]; then SID="$2"; shift 2; fi
  [ -n "$SID" ] || { echo "kb-freeze --set: need --sid <id> (or SPECCRAFT_SID)" >&2; exit 2; }
  printf '%s\n' "$@" | tr ' ' '\n' | sed '/^$/d' > "${TMPDIR:-/tmp}/speccraft-freeze-$SID"
  exit 0
fi

# --- <PROLOGUE copied from kb-recall-gate.sh: ROOT/KB/FORGE, kbforge guard, telemetry,
#     IN=$(cat), FP=tool_input.file_path, SID=session_id, case "$FP" → REL or exit 0> ---

FREEZE="${TMPDIR:-/tmp}/speccraft-freeze-$SID"
LANES=""
if [ -f "$FREEZE" ]; then
  LANES=$(cat "$FREEZE")
elif [ -n "${SPECCRAFT_FREEZE:-}" ]; then
  LANES=$(printf '%s\n' $SPECCRAFT_FREEZE)   # word-split env into lines (intentional, unquoted)
fi
[ -n "$LANES" ] || exit 0                    # unfrozen → allow

inlane=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  p="${p%/}"
  if [ "$REL" = "$p" ] || [ "${REL#"$p"/}" != "$REL" ]; then inlane=1; break; fi
done <<EOF
$LANES
EOF
[ "$inlane" -eq 1 ] && exit 0

LANESHOW=$(printf '%s' "$LANES" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
export KB_SESSION_ID="$SID"; kb_telemetry freeze_block "$REL" 2>/dev/null || true
REASON="FREEZE GATE — $REL is outside your assigned edit lane. Your lane: $LANESHOW. This edit was not applied. Do NOT work around it — widening the lane is an orchestrator/coordination decision, not a solo edit. Surface to the orchestrator that you need $REL, or confirm it's out of scope for your task."
jq -nc --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
```
Match the telemetry mechanism to `kb-recall-gate.sh` (source/call). `chmod +x` the hook.

- [ ] **Step 4: Run to verify pass**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-freeze.sh`
Expected: PASS — `freeze: N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/session-kit/hooks/kb-freeze.sh kb-forge/speccraft/forge/session-kit/evals/test-freeze.sh
git commit -m "feat(speccraft): kb-freeze.sh — PreToolUse edit-lane enforcement"
```

---

## Task 2: SessionStart materialize + briefing display + registration

**Files:** Modify `session-kit/hooks/kb-briefing.sh`; Modify `session-kit/settings.json`; Test `session-kit/evals/test-freeze.sh` (extend).

**Interfaces:**
- Consumes: `SPECCRAFT_FREEZE` env at SessionStart; the SessionStart input's `session_id`.
- Produces: `$TMPDIR/speccraft-freeze-$SID` materialized from the env (so the PreToolUse hook reads a stable file, widenable via `--set`); the briefing shows the active lane; `kb-freeze.sh` is registered in PreToolUse before `kb-recall-gate.sh`.

- [ ] **Step 1: Extend the test** (append to `test-freeze.sh`, before the summary echo)

```bash
echo "== SessionStart materializes SPECCRAFT_FREEZE -> lane file + shows lane =="
BF="$TMP/bf"; mkdir -p "$BF/.speccraft/kb/derived" "$BF/.speccraft/kb/normative"
( cd "$BF" && git init -q && git config user.email t@t && git config user.name t )
printf 'repo: %s\n' "$BF" > "$BF/.speccraft/kbforge.yaml"
printf 'source_commit: %s\n' "$(cd "$BF" && printf x>f && git add -A && git commit -qm i && git rev-parse --short HEAD)" > "$BF/.speccraft/kb/derived/inventory.md"
printf '# INV\n' > "$BF/.speccraft/kb/normative/01-invariants.md"
OUT=$(printf '{"session_id":"bs1"}' | ( cd "$BF" && KBFORGE_HOME="$FORGE" TMPDIR="$TMP" SPECCRAFT_FREEZE="backend/worker/crypto" bash "$FORGE/session-kit/hooks/kb-briefing.sh" 2>/dev/null ))
[ -f "$TMP/speccraft-freeze-bs1" ] && grep -q 'backend/worker/crypto' "$TMP/speccraft-freeze-bs1" && ok "SessionStart materialized lane file" || bad "materialize"
printf '%s' "$OUT" | grep -qi 'lane' && ok "briefing shows active lane" || bad "briefing shows lane"
# no env -> no file
printf '{"session_id":"bs2"}' | ( cd "$BF" && KBFORGE_HOME="$FORGE" TMPDIR="$TMP" bash "$FORGE/session-kit/hooks/kb-briefing.sh" >/dev/null 2>&1 )
[ ! -f "$TMP/speccraft-freeze-bs2" ] && ok "no env -> no lane file" || bad "no env no file"
```

- [ ] **Step 2: Run → fails** (kb-briefing doesn't materialize/show lane yet).

- [ ] **Step 3: Materialize + display in `kb-briefing.sh`**

`kb-briefing.sh` runs at SessionStart. Add near its top (after `KB`/`FORGE` resolve, before the print block): read the SessionStart input's `session_id`, and if `SPECCRAFT_FREEZE` is set, materialize + prepare a display line:

```sh
FZIN=$(cat 2>/dev/null || true)
FSID=$(printf '%s' "$FZIN" | jq -r '.session_id // empty' 2>/dev/null)
if [ -n "${SPECCRAFT_FREEZE:-}" ] && [ -n "$FSID" ]; then
  printf '%s\n' $SPECCRAFT_FREEZE | sed '/^$/d' > "${TMPDIR:-/tmp}/speccraft-freeze-$FSID"
fi
```
And add a briefing line (with the other `echo`s) shown only when frozen:
```sh
[ -n "${SPECCRAFT_FREEZE:-}" ] && echo "🔒 edit lane (this session is frozen): ${SPECCRAFT_FREEZE}"
```
Note: `kb-briefing.sh` may not currently read stdin — adding `cat` is safe at SessionStart (input is JSON on stdin). Confirm it doesn't break the existing briefing output.

- [ ] **Step 4: Register `kb-freeze.sh` in `settings.json`**

Insert `kb-freeze.sh` into the PreToolUse hooks array **between** `kb-guard.sh` and `kb-recall-gate.sh`:
```json
        { "type": "command", "command": "~/.speccraft/kb-forge/session-kit/hooks/kb-freeze.sh", "timeout": 10 },
```
(so order is: kb-guard → **kb-freeze** → kb-recall-gate). Keep JSON valid.

- [ ] **Step 5: Run → passes.** `bash kb-forge/speccraft/forge/session-kit/evals/test-freeze.sh` green; also `python3 -c "import json;json.load(open('kb-forge/speccraft/forge/session-kit/settings.json'))"` (valid JSON).

- [ ] **Step 6: Commit**

```bash
git add kb-forge/speccraft/forge/session-kit/hooks/kb-briefing.sh kb-forge/speccraft/forge/session-kit/settings.json kb-forge/speccraft/forge/session-kit/evals/test-freeze.sh
git commit -m "feat(speccraft): SessionStart materializes freeze lane; register kb-freeze hook"
```

---

## Task 3: docs — `speccraft-freeze` skill + mirrors + SPEC

**Files:** Create `session-kit/skills/speccraft-freeze/SKILL.md` + `codex-prompts/speccraft-freeze.md` + `opencode-commands/speccraft-freeze.md`; Modify `SPEC.md`.

- [ ] **Step 1:** Write `speccraft-freeze/SKILL.md` — an **orchestrator** reference: to confine a fanned-out agent, set `SPECCRAFT_FREEZE="<space-separated path prefixes>"` in its launch environment; the SessionStart materializes it and the PreToolUse `kb-freeze.sh` hard-denies out-of-lane edits. Widen a running session with `kb-freeze.sh --set --sid <id> <paths…>`. Assign **non-overlapping** lanes across parallel agents. Agent-facing note: a freeze denial means **surface to the orchestrator** ("I need `<path>`, outside my lane") — never work around it. Match the existing SKILL.md style/frontmatter.

- [ ] **Step 2:** Mirror into `codex-prompts/speccraft-freeze.md` + `opencode-commands/speccraft-freeze.md`, harness-adapted exactly as the other mirrors are (compare an existing skill↔mirror pair first). Note in the mirrors that the automatic PreToolUse deny is a Claude-Code hook; under Codex/OpenCode the discipline is advisory (self-apply).

- [ ] **Step 3:** `SPEC.md` — document the freeze mechanism (`SPECCRAFT_FREEZE` env → session lane file → PreToolUse deny), the in-lane boundary rule, and that it's dormant unless assigned.

- [ ] **Step 4:** Verify + commit. `grep -l 'SPECCRAFT_FREEZE' kb-forge/speccraft/forge/SPEC.md kb-forge/speccraft/forge/session-kit/skills/speccraft-freeze/SKILL.md` (both listed); each mirror mentions the lane mechanism.
```bash
git add kb-forge/speccraft/forge/session-kit/skills/speccraft-freeze kb-forge/speccraft/forge/session-kit/codex-prompts/speccraft-freeze.md kb-forge/speccraft/forge/session-kit/opencode-commands/speccraft-freeze.md kb-forge/speccraft/forge/SPEC.md
git commit -m "docs(speccraft): speccraft-freeze skill + mirrors + SPEC (edit-scope freeze)"
```

---

## Task 4: Wire `test-freeze.sh` into `self-test.sh`

**Files:** Modify `session-kit/evals/self-test.sh`.

- [ ] **Step 1:** Add a `freeze` section modeled EXACTLY on the `seams` section (runs `test-freeze.sh`, folds `freeze: N passed, N failed` into `$PASS`/`$FAIL`, nonzero-exit guard). Use the file's real `$HERE`/`run_section`/`no` names.

- [ ] **Step 2:** Run the full suite:

Run: `bash kb-forge/speccraft/forge/session-kit/evals/self-test.sh 2>&1 | tail -1`
Expected: `self-test: N passed, 0 failed` where N = prior total (184) + freeze assertions. Report N. (Slow ~4min.)

- [ ] **Step 3:** Confirm the fold is real (a freeze failure fails self-test), then commit:
```bash
git add kb-forge/speccraft/forge/session-kit/evals/self-test.sh
git commit -m "test(speccraft): wire edit-scope freeze suite into self-test"
```

---

## Self-Review

**Spec coverage** (against `2026-08-10-edit-scope-freeze-design.md`):
- §4.1 assign via `SPECCRAFT_FREEZE` → Task 3 (documented) + Task 1/2 (env consumed) ✓
- §4.2 materialize at SessionStart + lane display → Task 2 ✓
- §4.3 PreToolUse enforce + boundary rule + deny → Task 1 ✓
- §4.4 `--set` widen; orchestrator-owned; no self-unfreeze → Task 1 (`--set`), Task 3 (docs) ✓
- §4.5 docs → Task 3 ✓
- §5 tests (unfrozen, in/out-lane, boundary, multi-lane, materialize, --set, .speccraft-not-gated, env-fallback) → Task 1 + Task 2 ✓
- registration + ordering → Task 2 ✓

**Placeholder scan:** Task 1 Step 3 says "copy the prologue from kb-recall-gate.sh verbatim" and "match the telemetry mechanism" — a read-and-adapt with the exact behavior specified (the freeze logic itself is literal). Task 2 Step 3 adapts kb-briefing's insertion point (read-and-adapt). No vague-in-code placeholders.

**Type/name consistency:** the lane file path `${TMPDIR:-/tmp}/speccraft-freeze-$SID` is identical in the hook (read), `--set` (write), and the SessionStart materialize (write). The in-lane boundary rule is stated once and used once. `freeze: N passed` summary line matches between `test-freeze.sh` and the self-test parse.

---

## Execution Handoff

Plan complete. Two read-and-adapt spots (both flagged): the hook prologue + telemetry call copied from `kb-recall-gate.sh`, and the insertion point in `kb-briefing.sh`. Everything else — the freeze logic, boundary rule, deny JSON, `--set`, settings.json entry, and all tests — is literal.
