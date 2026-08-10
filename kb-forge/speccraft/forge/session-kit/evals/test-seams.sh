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
RC=0; python3 "$FORGE/recall.py" --config "$KB/kbforge.yaml" --no-coverage-check --files backend/app/services/tiers.py || RC=$?
[ "$RC" -eq 0 ] && ok "covered file exits 0" || bad "covered file exits 0 (got $RC)"
RC=0; python3 "$FORGE/recall.py" --config "$KB/kbforge.yaml" --no-coverage-check --files backend/nowhere/unknown.py || RC=$?
[ "$RC" -eq 3 ] && ok "uncovered file exits 3" || bad "uncovered file exits 3 (got $RC)"

echo "seams: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
