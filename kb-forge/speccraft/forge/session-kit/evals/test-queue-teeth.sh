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
KB="$TMP/ban2"; mkkb "$KB" 3 14   # zero data rows: clean KB, must NOT be treated as corrupt
python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" && ok "zero-row FINDINGS.md is clean, not blocked" || bad "zero-row FINDINGS.md is clean, not blocked"
python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" --banner | grep -q '0 open HIGH' && ok "banner shows none" || bad "banner shows none"

echo "== banner: unreviewed commits between ratified_through and source_commit =="
G="$TMP/unrev"; SP="$G/.speccraft"; mkdir -p "$SP/findings" "$SP/kb/derived"
( cd "$G" && git init -q && git config user.email t@t && git config user.name t \
  && printf a > f && git add -A && git commit -qm c1 )
RAT="$(cd "$G" && git rev-parse --short HEAD)"
( cd "$G" && printf b >> f && git add -A && git commit -qm c2 )
SRC="$(cd "$G" && git rev-parse --short HEAD)"
printf 'repo: %s\nhigh_debt_ceiling: 3\nhigh_debt_max_age_days: 14\n' "$G" > "$SP/kbforge.yaml"
printf 'source_commit: %s\nratified_through: %s\n' "$SRC" "$RAT" > "$SP/kb/derived/inventory.md"
{ echo '| ID | Sev | Raised | Finding | Evidence (@pin) | Source | Status |';
  echo '|----|-----|--------|---------|-----------------|--------|--------|'; } > "$SP/findings/FINDINGS.md"
python3 "$FORGE/gate.py" --config "$SP/kbforge.yaml" --banner | grep -q 'unreviewed' \
  && ok "banner shows unreviewed commits" || bad "banner shows unreviewed commits"

echo "== gate: corrupt FINDINGS.md fails closed (M1) =="
KB="$TMP/corrupt"; mkkb "$KB" 3 14
{ echo '| ID | Sev | Raised | Finding | Evidence (@pin) | Source | Status |';
  echo '|----|-----|--------|---------|-----------------|--------|--------|';
  echo '| BUG-001 | High | broken row |'; } > "$KB/findings/FINDINGS.md"
python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" 2>/dev/null \
  && bad "corrupt FINDINGS.md fails closed" || ok "corrupt FINDINGS.md fails closed"

echo "== waive: ratified_through advance, ledger auto-created (I1), staged (I2) =="
G="$TMP/waiverepo"; SP="$G/.speccraft"
mkdir -p "$SP/findings" "$SP/kb/derived"   # NOTE: no ledger/ dir — I1
( cd "$G" && git init -q && git config user.email t@t && git config user.name t )
printf 'repo: %s\nhigh_debt_ceiling: 0\nhigh_debt_max_age_days: 14\n' "$G" > "$SP/kbforge.yaml"
printf 'source_commit: def5678\nratified_through: aaa1111\n' > "$SP/kb/derived/inventory.md"
{ echo '| ID | Sev | Raised | Finding | Evidence (@pin) | Source | Status |';
  echo '|----|-----|--------|---------|-----------------|--------|--------|';
  echo "| BUG-001 | High | $OLD | some finding | ev | src | proposed |"; } > "$SP/findings/FINDINGS.md"
( cd "$G" && git add -A && git commit -qm seed )
# ratify locally (uncommitted) — old ratified_through (aaa1111) is only in HEAD
printf 'source_commit: def5678\nratified_through: newxyz9\n' > "$SP/kb/derived/inventory.md"
python3 "$FORGE/gate.py" --config "$SP/kbforge.yaml" --waive "shipping launch" >/dev/null
[ -f "$SP/ledger/DEBT-WAIVERS.md" ] && ok "waive creates ledger/ when absent (I1)" || bad "waive creates ledger/ when absent (I1)"
grep -qE '^- [0-9]{4}-[0-9]{2}-[0-9]{2}  ratified_through aaa1111->newxyz9  deferred: BUG-001  — reason: "shipping launch"' "$SP/ledger/DEBT-WAIVERS.md" \
  && ok "waiver line well-formed" || bad "waiver line well-formed"
( cd "$G" && git diff --cached --name-only | grep -q DEBT-WAIVERS ) \
  && ok "waiver file git-staged (I2)" || bad "waiver file git-staged (I2)"

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

echo "== pre-commit: blocks ratified_through advance under debt, waiver unblocks =="
G="$TMP/repo"; SP="$G/.speccraft"
mkdir -p "$SP/findings" "$SP/kb/derived" "$SP/ledger"
( cd "$G" && git init -q && git config user.email t@t && git config user.name t )
printf 'repo: %s\nhigh_debt_ceiling: 0\nhigh_debt_max_age_days: 14\n' "$G" > "$SP/kbforge.yaml"
printf 'source_commit: aaaaaaa\nratified_through: aaaaaaa\n' > "$SP/kb/derived/inventory.md"
{ echo '| ID | Sev | Raised | Finding | Evidence (@pin) | Source | Status |';
  echo '|----|-----|--------|---------|-----------------|--------|--------|';
  echo "| BUG-001 | High | $(date +%F) | x | ev | src | proposed |"; } > "$SP/findings/FINDINGS.md"
cp "$FORGE/session-kit/pre-commit" "$G/.git/hooks/pre-commit"; chmod +x "$G/.git/hooks/pre-commit"
export KBFORGE_HOME="$FORGE"
# seed commit via ship-loop bypass — establishes initial pinned state without
# tripping the debt gate (FINDINGS.md already has an open HIGH over ceiling 0)
( cd "$G" && git add -A && KB_SHIPLOOP=1 git commit -qm "seed" )
# ship-loop advances source_commit only (the mechanical pin) -> NEVER gated,
# even with the same open-HIGH-over-ceiling debt staged above.
printf 'source_commit: shiploop1\nratified_through: aaaaaaa\n' > "$SP/kb/derived/inventory.md"
if ( cd "$G" && git add -A && KB_SHIPLOOP=1 git commit -qm "ship-loop pin advance" ) 2>/dev/null; then
  ok "ship-loop source_commit advance under debt succeeds (mechanical pin never gated)"
else
  bad "ship-loop source_commit advance under debt succeeds (mechanical pin never gated)"
fi
# advance ratified_through (the trust boundary) -> should be BLOCKED (1 open HIGH > ceiling 0)
printf 'source_commit: shiploop1\nratified_through: bbbbbbb\n' > "$SP/kb/derived/inventory.md"
if ( cd "$G" && git add -A && KB_RATIFY=1 git commit -qm "advance ratified_through" ) 2>/dev/null; then
  bad "pre-commit blocks ratified_through advance under debt"
else
  ok "pre-commit blocks ratified_through advance under debt"
fi
# now waive and retry -> allowed
python3 "$FORGE/gate.py" --config "$SP/kbforge.yaml" --waive "test waiver" >/dev/null
if ( cd "$G" && git add -A && KB_RATIFY=1 git commit -qm "advance ratified_through (waived)" ) 2>/dev/null; then
  ok "waiver unblocks ratified_through advance"
else
  bad "waiver unblocks ratified_through advance"
fi
unset KBFORGE_HOME

echo "== briefing: two-anchor status — green (caught up) =="
GKB="$TMP/briefgreen"; mkdir -p "$GKB/.speccraft/findings" "$GKB/.speccraft/kb/derived"
( cd "$GKB" && git init -q && git config user.email t@t && git config user.name t )
SPG="$GKB/.speccraft"
printf 'repo: %s\nhigh_debt_ceiling: 3\nhigh_debt_max_age_days: 14\n' "$GKB" > "$SPG/kbforge.yaml"
GSHA="$(cd "$GKB" && printf init > f && git add -A && git commit -qm i && git rev-parse --short HEAD)"
printf 'source_commit: %s\nratified_through: %s\n' "$GSHA" "$GSHA" > "$SPG/kb/derived/inventory.md"
mkdir -p "$SPG/kb/normative"; printf '# INV\n' > "$SPG/kb/normative/01-invariants.md"
{ echo '| ID | Sev | Raised | Finding | Evidence (@pin) | Source | Status |';
  echo '|----|-----|--------|---------|-----------------|--------|--------|'; } > "$SPG/findings/FINDINGS.md"
export KBFORGE_HOME="$FORGE"
OUT="$(cd "$GKB" && bash "$FORGE/session-kit/hooks/kb-briefing.sh" 2>/dev/null)"
unset KBFORGE_HOME
printf '%s\n' "$OUT" | head -1 | grep -q 'KB caught up' && ok "briefing first line shows KB caught up (green, anchors equal, 0 open HIGH)" || bad "briefing first line shows KB caught up (green, anchors equal, 0 open HIGH)"

echo "== briefing: two-anchor status — behind/blocked =="
BKB="$TMP/brief"; mkdir -p "$BKB/.speccraft/findings" "$BKB/.speccraft/kb/derived"
( cd "$BKB" && git init -q && git config user.email t@t && git config user.name t )
SP="$BKB/.speccraft"
printf 'repo: %s\nhigh_debt_ceiling: 0\nhigh_debt_max_age_days: 14\n' "$BKB" > "$SP/kbforge.yaml"
printf 'source_commit: %s\n' "$(cd "$BKB" && printf init > f && git add -A && git commit -qm i && git rev-parse --short HEAD)" > "$SP/kb/derived/inventory.md"
mkdir -p "$SP/kb/normative"; printf '# INV\n' > "$SP/kb/normative/01-invariants.md"
{ echo '| ID | Sev | Raised | Finding | Evidence (@pin) | Source | Status |';
  echo '|----|-----|--------|---------|-----------------|--------|--------|';
  echo "| BUG-001 | High | $(date +%F) | x | ev | src | proposed |"; } > "$SP/findings/FINDINGS.md"
export KBFORGE_HOME="$FORGE"
OUT="$(cd "$BKB" && bash "$FORGE/session-kit/hooks/kb-briefing.sh" 2>/dev/null)"
unset KBFORGE_HOME
printf '%s\n' "$OUT" | head -1 | grep -q 'KB behind' && ok "briefing first line is KB-behind banner" || bad "briefing first line is KB-behind banner"
printf '%s\n' "$OUT" | head -1 | grep -q 'BLOCKED' && ok "banner shows BLOCKED state on first line" || bad "banner shows BLOCKED state on first line"

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

echo "queue-teeth: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
