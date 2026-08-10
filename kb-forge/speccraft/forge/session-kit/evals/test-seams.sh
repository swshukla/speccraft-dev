#!/usr/bin/env bash
# Phase-2 seam-aware recall + Confusion Protocol assertions.
set -euo pipefail
FORGE="$(cd "$(dirname "$0")/../.." && pwd)"   # .../speccraft/forge
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT   # -P: realpath, so gate.sh's git-toplevel match works under macOS's /var -> /private/var symlink
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

echo "== --all with an unmatched fact does not crash =="
RC=0
python3 "$FORGE/recall.py" --config "$KB/kbforge.yaml" --all --files backend/app/services/tiers.py >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] && ok "--all + unmatched fact no crash" || bad "--all + unmatched fact no crash (exit $RC)"

echo "== Confusion Protocol gate =="
# gate.sh's dedup cache is keyed by session id alone (${TMPDIR}/speccraft-recall-seen-$SID),
# not by repo — sweep any stale cache from a prior run of this suite so s1..s4 are fresh here.
rm -f "${TMPDIR:-/tmp}/speccraft-recall-seen-s1" "${TMPDIR:-/tmp}/speccraft-recall-seen-s2" \
      "${TMPDIR:-/tmp}/speccraft-recall-seen-s3" "${TMPDIR:-/tmp}/speccraft-recall-seen-s4" \
      "${TMPDIR:-/tmp}/speccraft-recall-seen-s9"
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

echo "== broken coverage check fails OPEN (no false deny) =="
# a risk path that IS covered, but make the covering fact unreadable so recall.py errors
# (exit 1, not 3) — the gate must fail OPEN, not treat a broken check as no-coverage.
cat > "$GKB/kb/normative/conventions/CONV-x.md" <<'EOF'
---
status: observed
anchors: [backend/app/tier_broken.py]
---
## x
EOF
chmod 000 "$GKB/kb/normative/conventions/CONV-x.md"
OUT=$(run_gate "backend/app/tier_broken.py" s9)
chmod 644 "$GKB/kb/normative/conventions/CONV-x.md"   # restore so cleanup works
[ -z "$OUT" ] && ok "broken check fails open (no deny)" || bad "broken check false-denied"

echo "seams: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
