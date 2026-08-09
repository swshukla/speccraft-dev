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
