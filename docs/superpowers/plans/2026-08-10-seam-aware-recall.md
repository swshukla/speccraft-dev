# Seam-Aware Recall + Confusion Protocol — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface a ratified canonical seam ("USE `x` · AVOID `y`") when an agent edits a governed file, and hard-stop-once when an agent edits a risk-tagged path with no KB coverage (Confusion Protocol) — so parallel agents import the seam instead of cloning, and stop-and-file instead of guess-and-clone.

**Architecture:** `recall.py` already parses arbitrary frontmatter scalars and matches files to facts by `anchors:`; it gains (a) rendering of `seam:`/`avoid:` on matched facts and (b) a `--no-coverage-check` exit-code mode. `kb-recall-gate.sh` (PreToolUse) already denies-once on a ratified-normative match; it gains a second branch that denies-once on a risk-tagged path with no coverage. Seams are per-convention files under `kb/normative/conventions/`. No product code.

**Tech Stack:** Python 3.9+ (stdlib only), Bash hooks, the existing `session-kit/evals/` bash test harness.

## Global Constraints

- **Python ≥ 3.9, stdlib only, no new deps.** File IO `encoding="utf-8"`.
- **`recall.py` already parses `seam:`/`avoid:` for free** — `frontmatter()` captures any scalar key into the fact's `meta` dict. No parser change; only *rendering* + the new flag.
- **Coverage semantics:** "no coverage" = NO fact in ANY lane matches the file (do NOT pass `--lanes` to `--no-coverage-check`). The ratified gate stays `--lanes normative --gate-check`.
- **Hook conventions:** hooks resolve forge via `FORGE="${KBFORGE_HOME:-$HOME/.speccraft/kb-forge}"`, the KB via `KB=$ROOT/.speccraft`, and `risk_paths` from `kbforge.yaml` (match however `kb-recall-post.sh` already extracts it — reuse that exact approach). Deny is emitted as `jq -n … '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'`. The dedup cache is `${TMPDIR:-/tmp}/speccraft-recall-seen-$SID` (one `REL` per line).
- **Tests:** a new `session-kit/evals/test-seams.sh`, styled like `test-queue-teeth.sh` (`set -euo pipefail`, own `pass`/`fail`/`ok`/`bad`), ending with `echo "seams: $pass passed, $fail failed"` then `[ "$fail" -eq 0 ]`. Wired into `self-test.sh` as a `seams` section modeled on the `queueteeth` section.
- **Deny wording discipline:** the existing gate's deny reason is an "empirically validated v3 template" (briefing reference + verifiable KB paths + divergence rule; coercive variants get classified as prompt injection). Match that register in the new deny reason — reference the briefing, name the path, offer recall/elicit/diverge, note it fires once.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `recall.py` | Render `seam:`/`avoid:` on matched facts; add `--no-coverage-check` | **Modify** |
| `session-kit/hooks/kb-recall-gate.sh` | Second deny branch: risk-tagged + no-coverage → deny-once | **Modify** |
| `session-kit/skills/speccraft-recall/SKILL.md` | Seam USE/AVOID rendering + Confusion-Protocol stop | **Modify** |
| `session-kit/skills/speccraft-ratify/SKILL.md` | Convention-accepted → write `conventions/CONV-NN` + index line | **Modify** |
| `session-kit/skills/speccraft-diverge/SKILL.md` | Coverage-gap divergence variant | **Modify** |
| `session-kit/codex-prompts/`, `session-kit/opencode-commands/` | Mirror the 3 SKILL updates | **Modify** |
| `SPEC.md` | Document seam fields + Confusion Protocol | **Modify** |
| `session-kit/evals/test-seams.sh` | The suite | **Create** |
| `session-kit/evals/self-test.sh` | Wire in the `seams` section | **Modify** |

---

## Task 1: `recall.py` — seam rendering + `--no-coverage-check`

**Files:** Modify `recall.py`; Create `session-kit/evals/test-seams.sh`.

**Interfaces:**
- Consumes: existing `collect()`/`match()`/`frontmatter()` (frontmatter already yields `meta` with `seam`/`avoid` scalars).
- Produces: `recall.py --files <p>` renders `→ USE:`/`→ AVOID:` lines under a matched fact that has `seam`/`avoid`; `recall.py --no-coverage-check --files <p>` exits 3 if no fact covers `<p>`, else 0.

- [ ] **Step 1: Write the failing test**

Create `session-kit/evals/test-seams.sh`:

```bash
#!/usr/bin/env bash
# Phase-2 seam-aware recall + Confusion Protocol assertions.
set -euo pipefail
FORGE="$(cd "$(dirname "$0")/../.." && pwd)"   # .../speccraft/forge
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# fixture KB with a conventions/ seam and a plain fact
mkkb() {  # $1=dir
  local kb="$1"
  mkdir -p "$kb/kb/normative/conventions" "$kb/kb/derived"
  printf 'repo: %s\nrisk_paths: "auth|payment|tier|billing"\n' "$TMP" > "$kb/kbforge.yaml"
  printf 'source_commit: abc1234\n' > "$kb/kb/derived/inventory.md"
  cat > "$kb/kb/normative/conventions/CONV-11-entitlement.md" <<'EOF'
---
status: ratified
anchors: [backend/app/services/tiers.py, topic:entitlement]
seam: "effective_tier(user) — import from backend.app.services.tiers"
avoid: "raw User.tier for gating"
---
## CONV-11 — one entitlement seam
Tier gating goes through effective_tier(). Raw User.tier is defect C-01.
EOF
  # a plain (non-seam) ratified fact
  cat > "$kb/kb/normative/00-intent.md" <<'EOF'
---
status: ratified
anchors: [backend/app/main.py]
---
## Intent
Some ratified intent, no seam.
EOF
}

echo "== recall renders USE/AVOID for a seam-governed file =="
KB="$TMP/kb1"; mkkb "$KB"
OUT=$(python3 "$FORGE/recall.py" --config "$KB/kbforge.yaml" --files backend/app/services/tiers.py 2>/dev/null)
printf '%s' "$OUT" | grep -q 'USE: effective_tier' && ok "renders USE" || bad "renders USE"
printf '%s' "$OUT" | grep -q 'AVOID: raw User.tier' && ok "renders AVOID" || bad "renders AVOID"

echo "== plain fact renders without USE/AVOID, no crash =="
OUT=$(python3 "$FORGE/recall.py" --config "$KB/kbforge.yaml" --files backend/app/main.py 2>/dev/null)
printf '%s' "$OUT" | grep -q '00-intent.md' && ! printf '%s' "$OUT" | grep -q 'USE:' && ok "plain fact no USE/AVOID" || bad "plain fact no USE/AVOID"

echo "== --no-coverage-check exit codes =="
python3 "$FORGE/recall.py" --config "$KB/kbforge.yaml" --no-coverage-check --files backend/app/services/tiers.py; RC=$?
[ "$RC" -eq 0 ] && ok "covered file exits 0" || bad "covered file exits 0 (got $RC)"
python3 "$FORGE/recall.py" --config "$KB/kbforge.yaml" --no-coverage-check --files backend/nowhere/unknown.py; RC=$?
[ "$RC" -eq 3 ] && ok "uncovered file exits 3" || bad "uncovered file exits 3 (got $RC)"

echo "seams: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-seams.sh`
Expected: FAIL — no `USE:`/`AVOID:` rendering yet; `--no-coverage-check` is an unknown flag (argparse errors).

- [ ] **Step 3: Add seam rendering to `recall.py`'s matched loop**

Open `recall.py`. The matched-fact loop builds a row per fact and prints
`[{status:<20}] {kbf}   <- {', '.join(hits)}`. **Carry the fact's `meta` dict into the row**, sort by `(rank, kbf)` (kbf is unique, so `meta` never enters the comparison), and after printing each fact's line, print the seam lines when present:

```python
    # when building each matched row, include meta (the fact's frontmatter dict):
    #   matched.append((RANK.get(status, 9), kbf, status, hits, meta))
    # sort deterministically without comparing dicts:
    matched.sort(key=lambda r: (r[0], r[1]))
    for _rank, kbf, status, hits, meta in matched:
        print(f"[{status:<20}] {kbf}   <- {', '.join(hits)}")
        if meta.get("seam"):
            print(f"        → USE: {meta['seam']}")
        if meta.get("avoid"):
            print(f"        → AVOID: {meta['avoid']}")
```

Adapt to the file's actual variable names (the row tuple, the fact iteration). Keep the existing `NO KB COVERAGE …` no-match path and the `[status] path <- anchors` format unchanged; only append the USE/AVOID lines.

- [ ] **Step 4: Add `--no-coverage-check`**

Add the flag next to `--coverage-count`:

```python
    ap.add_argument("--no-coverage-check", action="store_true",
                    help="Confusion Protocol: exit 3 if NO fact covers the --files, else 0")
```

And an early exit mirroring `--coverage-count` (after `facts`/`files` are resolved, before the render loop):

```python
    if args.no_coverage_check:
        cov = sum(1 for f in files
                  if any(match(a, [f], set(args.topic)) for _, _, a in facts))
        sys.exit(3 if cov == 0 else 0)
```

(Uses all lanes — do not restrict to normative. `match`/`facts`/`files` are the same names `--coverage-count` uses.)

- [ ] **Step 5: Run to verify pass**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-seams.sh`
Expected: PASS — `seams: 5 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add kb-forge/speccraft/forge/recall.py kb-forge/speccraft/forge/session-kit/evals/test-seams.sh
git commit -m "feat(speccraft): recall renders seam USE/AVOID; --no-coverage-check"
```

---

## Task 2: `kb-recall-gate.sh` — the Confusion Protocol deny branch

**Files:** Modify `session-kit/hooks/kb-recall-gate.sh`; Test `session-kit/evals/test-seams.sh` (extend).

**Interfaces:**
- Consumes: `recall.py --no-coverage-check` (Task 1); `risk_paths` from `kbforge.yaml`.
- Produces: an Edit to a risk-tagged path with no coverage is denied once (with a coverage-gap reason); covered paths and non-risk paths are not denied; ratified-seam matches still deny via the existing branch (precedence).

- [ ] **Step 1: Write the failing test** (append to `test-seams.sh`, before the summary echo)

```bash
echo "== Confusion Protocol gate =="
GKB="$TMP/gate/.speccraft"; mkdir -p "$GKB/kb/normative/conventions" "$GKB/kb/derived"
( cd "$TMP/gate" && git init -q && git config user.email t@t && git config user.name t )
printf 'repo: %s\nrisk_paths: "auth|payment|tier|billing"\n' "$TMP/gate" > "$GKB/kbforge.yaml"
printf 'source_commit: abc1234\n' > "$GKB/kb/derived/inventory.md"
GATE="$FORGE/session-kit/hooks/kb-recall-gate.sh"
# helper: run the gate hook with a fake tool_input for a given rel path + fresh session
run_gate() { # $1=relpath $2=sid
  printf '{"tool_input":{"file_path":"%s"},"session_id":"%s"}' "$TMP/gate/$1" "$2" \
    | ( cd "$TMP/gate" && KBFORGE_HOME="$FORGE" bash "$GATE" 2>/dev/null )
}
# risk-tagged path, no coverage -> deny
OUT=$(run_gate "backend/app/billing_new.py" s1)
printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"' && ok "risk+no-coverage denies" || bad "risk+no-coverage denies"
# same file again (dedup) -> no deny
OUT=$(run_gate "backend/app/billing_new.py" s1)
[ -z "$OUT" ] && ok "dedup: second touch not denied" || bad "dedup"
# non-risk path, no coverage -> no deny
OUT=$(run_gate "frontend/components/Card.tsx" s2)
[ -z "$OUT" ] && ok "non-risk no-coverage allowed" || bad "non-risk allowed"
# risk path WITH coverage -> not denied by the no-coverage branch
cat > "$GKB/kb/normative/conventions/CONV-9-billing.md" <<'EOF'
---
status: observed
anchors: [backend/app/billing_seen.py]
---
## note
EOF
OUT=$(run_gate "backend/app/billing_seen.py" s3)
[ -z "$OUT" ] && ok "risk+covered(observed) not no-coverage-denied" || bad "risk+covered allowed"
# risk path governed by a RATIFIED seam -> ratified branch denies (precedence), with USE/AVOID
cat > "$GKB/kb/normative/conventions/CONV-11-tier.md" <<'EOF'
---
status: ratified
anchors: [backend/app/tier_gate.py]
seam: "effective_tier(user)"
avoid: "raw User.tier"
---
## CONV-11
EOF
OUT=$(run_gate "backend/app/tier_gate.py" s4)
printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"' && printf '%s' "$OUT" | grep -q 'effective_tier' && ok "ratified seam denies with USE/AVOID (precedence)" || bad "ratified seam precedence"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-seams.sh`
Expected: FAIL on "risk+no-coverage denies" — the current hook `exit 0`s when no ratified anchor.

- [ ] **Step 3: Add the Confusion Protocol branch**

In `kb-recall-gate.sh`, the ratified check is `OUT=$(… --gate-check …)` then line 29 `[ $? -ne 3 ] && exit 0`. Restructure so a non-ratified path FALLS THROUGH to the no-coverage check instead of exiting. Replace line 29's `exit 0` behavior:

```sh
if [ $? -eq 3 ]; then
  # ── existing ratified-normative deny (keep lines 31-42 verbatim) ──
  echo "$REL" >> "$CACHE"
  export KB_SESSION_ID="$SID"; kb_telemetry recall_gate_block "$REL"
  REASON="RECALL GATE …"    # unchanged existing wording
  jq -n --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi

# ── Confusion Protocol: risk-tagged path with NO coverage → deny once ──
RISK=$(grep -m1 '^risk_paths:' "$KB/kbforge.yaml" | sed -E 's/^risk_paths:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
if [ -n "$RISK" ] && printf '%s' "$REL" | grep -qE "$RISK"; then
  if python3 "$FORGE/recall.py" --config "$KB/kbforge.yaml" --no-coverage-check --files "$REL" >/dev/null 2>&1; then
    :   # exit 0 = covered, fall through to allow
  else
    echo "$REL" >> "$CACHE"
    export KB_SESSION_ID="$SID"; kb_telemetry recall_gate_nocoverage "$REL"
    REASON="RECALL GATE — CONFUSION PROTOCOL (.speccraft session-kit, announced in your session briefing): no KB coverage for a risk-tagged path.
$REL is a risk-tagged path (auth/payment/tier/billing/…) and NO KB fact — ratified or observed — governs it. Your edit was not applied. Do not guess-and-clone: a canonical seam may exist that you cannot see from here. Run speccraft-recall to check, or elicit the intent from the user, or file a coverage-gap divergence (speccraft-diverge) naming this path — then re-issue the edit. Fires once per file per session; your next edit to $REL will proceed."
    jq -n --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
  fi
fi
exit 0
```

Match the `risk_paths` extraction to however `kb-recall-post.sh` reads it (open it and reuse that exact snippet if it differs from the `grep|sed` above). Note `recall.py --no-coverage-check` exits 3 on no-coverage, so the `if python3 …; then` (exit 0) is the covered case and the `else` is the deny case.

- [ ] **Step 4: Run to verify pass**

Run: `bash kb-forge/speccraft/forge/session-kit/evals/test-seams.sh`
Expected: PASS — all Confusion-Protocol assertions plus Task 1's.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/session-kit/hooks/kb-recall-gate.sh kb-forge/speccraft/forge/session-kit/evals/test-seams.sh
git commit -m "feat(speccraft): Confusion Protocol — gate denies once on risk-path with no coverage"
```

---

## Task 3: SKILL + mirror + SPEC updates

**Files:** Modify `speccraft-recall/SKILL.md`, `speccraft-ratify/SKILL.md`, `speccraft-diverge/SKILL.md`; their `codex-prompts/` + `opencode-commands/` mirrors; `SPEC.md`.

- [ ] **Step 1: `speccraft-recall/SKILL.md`** — document that recall now renders `→ USE:`/`→ AVOID:` for a governed seam (honor the seam; import it, don't clone), and the Confusion-Protocol stop: a no-coverage denial on a risk-tagged path means *don't guess-and-clone* — run recall, elicit intent, or file a coverage-gap divergence, then re-issue.

- [ ] **Step 2: `speccraft-ratify/SKILL.md`** — where it says "Convention accepted → add to `kb/normative/03-conventions.md`", change to: write a per-convention file `kb/normative/conventions/CONV-NN-<slug>.md` with frontmatter `status: ratified`, `anchors:` (the governed paths + any `topic:` slugs), and — for a canonical-symbol seam — `seam:` (the symbol + how to import) and `avoid:` (the anti-pattern; optional `avoid_pattern:` grep for later enforcement). Add a one-line index entry to `kb/normative/03-conventions.md`. Preserve the scope note discipline ("banned on money paths, tolerated in pollers").

- [ ] **Step 3: `speccraft-diverge/SKILL.md`** — add the coverage-gap variant: when the recall gate denies for no-coverage on a risk-tagged path and the intent can't be elicited inline, file a `## Open` divergence naming the path and the decision needed (what canonical approach should govern it), so it gets elicited/ratified rather than guessed.

- [ ] **Step 4: Mirror** the three edits into `session-kit/codex-prompts/speccraft-{recall,ratify,diverge}.md` and `session-kit/opencode-commands/speccraft-{recall,ratify,diverge}.md`, harness-adapting exactly as the existing recall/diverge mirrors are adapted (compare each SKILL to its mirror to see the convention; keep front-matter/args style).

- [ ] **Step 5: `SPEC.md`** — document the seam fields (`seam`/`avoid`/`avoid_pattern` on `kb/normative/conventions/CONV-NN` files) and the Confusion Protocol (risk-tagged + no-coverage → deny-once). Note enforcement of `avoid_pattern` is Phase 4/5.

- [ ] **Step 6: Verify + commit**

Run: `grep -l 'USE:\|seam' kb-forge/speccraft/forge/session-kit/skills/speccraft-recall/SKILL.md && grep -rl 'conventions/CONV' kb-forge/speccraft/forge/session-kit/skills/speccraft-ratify/SKILL.md` (both listed). Eyeball each mirror matches its SKILL.
```bash
git add kb-forge/speccraft/forge/session-kit/skills kb-forge/speccraft/forge/session-kit/codex-prompts kb-forge/speccraft/forge/session-kit/opencode-commands kb-forge/speccraft/forge/SPEC.md
git commit -m "docs(speccraft): seam conventions + Confusion Protocol in skills, mirrors, SPEC"
```

---

## Task 4: Wire `test-seams.sh` into `self-test.sh`

**Files:** Modify `session-kit/evals/self-test.sh`.

- [ ] **Step 1:** Add a `seams` section modeled EXACTLY on the `queueteeth` section (which runs `test-queue-teeth.sh` and folds its `N passed`/`N failed` counts into `$PASS`/`$FAIL` with the nonzero-exit guard). Use the file's real `$HERE`/`run_section`/`no` names; point it at `test-seams.sh`; parse the `seams: N passed, N failed` summary line.

- [ ] **Step 2:** Run the full suite:

Run: `bash kb-forge/speccraft/forge/session-kit/evals/self-test.sh 2>&1 | tail -1`
Expected: `self-test: N passed, 0 failed` where N = prior total (172) + the seams assertions. Report N. (Suite is slow, ~3-4 min.)

- [ ] **Step 3:** Confirm a forced failure propagates (the section folds counts like `queueteeth`, so a seams failure would fail self-test). Commit:

```bash
git add kb-forge/speccraft/forge/session-kit/evals/self-test.sh
git commit -m "test(speccraft): wire seam-aware recall suite into self-test"
```

---

## Self-Review

**Spec coverage** (against `2026-08-10-seam-aware-recall-design.md`):
- §4.1 seams as per-convention files → Task 3 (ratify writes them) + Task 1/2 fixtures (worked examples) ✓
- §4.2 seam-aware recall rendering → Task 1 ✓
- §4.3 Confusion Protocol (`--no-coverage-check` + gate branch) → Task 1 (flag) + Task 2 (gate) ✓
- §4.4 SKILL + mirror updates → Task 3 ✓
- §5 tests → Task 1 (render/exit codes), Task 2 (gate: deny/dedup/non-risk/covered/ratified-precedence), Task 4 (wire-in) ✓
- §6 files → all covered ✓

**Placeholder scan:** Task 1 Step 3 ("adapt to the file's actual variable names for the row tuple") and Task 2 Step 3 ("match `risk_paths` extraction to `kb-recall-post.sh`") are read-and-adapt instructions with exact target behavior + literal render/deny snippets — not vague-in-code. `--no-coverage-check` code, the test fixtures, and the deny reason are literal.

**Type/name consistency:** `--no-coverage-check` exits 3-on-no-coverage in Task 1 and is consumed as such in Task 2's gate (`if python3 …; then` = covered). `seam`/`avoid` field names identical in the fixtures (Task 1/2), the render (Task 1), and the ratify schema (Task 3). The `seams: N passed` summary line matches between `test-seams.sh` (Task 1) and the self-test parse (Task 4).

---

## Execution Handoff

Plan complete. Two read-and-adapt spots (both flagged, both with exact target behavior): the matched-row tuple shape in `recall.py`'s render loop, and the `risk_paths` extraction snippet in the hooks. Everything else — the new flag, the fixtures, the gate branch, the deny reason — is literal.
