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

echo "== blank/whitespace lane file fails OPEN (no block-all) =="
printf '   \n\t\n \n' > "$TMP/speccraft-freeze-w1"
OUT=$(run "backend/app/billing.py" w1)
[ -z "$OUT" ] && ok "whitespace-only lane file -> allow (fail open)" || bad "whitespace lane false-denied"

echo "== SessionStart materializes SPECCRAFT_FREEZE -> lane file + shows lane =="
BF="$TMP/bf"; mkdir -p "$BF/.speccraft/kb/derived" "$BF/.speccraft/kb/normative"
( cd "$BF" && git init -q && git config user.email t@t && git config user.name t )
printf 'repo: %s\n' "$BF" > "$BF/.speccraft/kbforge.yaml"
printf 'source_commit: %s\n' "$(cd "$BF" && printf x>f && git add -A && git commit -qm i && git rev-parse --short HEAD)" > "$BF/.speccraft/kb/derived/inventory.md"
printf '# INV\n' > "$BF/.speccraft/kb/normative/01-invariants.md"
OUT=$(printf '{"session_id":"bs1"}' | ( cd "$BF" && KBFORGE_HOME="$FORGE" TMPDIR="$TMP" SPECCRAFT_FREEZE="backend/worker/crypto" bash "$FORGE/session-kit/hooks/kb-briefing.sh" 2>/dev/null ))
[ -f "$TMP/speccraft-freeze-bs1" ] && grep -q 'backend/worker/crypto' "$TMP/speccraft-freeze-bs1" && ok "SessionStart materialized lane file" || bad "materialize"
printf '%s' "$OUT" | grep -q '🔒 edit lane' && ok "briefing shows active lane" || bad "briefing shows active lane"
# no env -> no file
printf '{"session_id":"bs2"}' | ( cd "$BF" && KBFORGE_HOME="$FORGE" TMPDIR="$TMP" bash "$FORGE/session-kit/hooks/kb-briefing.sh" >/dev/null 2>&1 )
[ ! -f "$TMP/speccraft-freeze-bs2" ] && ok "no env -> no lane file" || bad "no env no file"
# no env -> no freeze marker in briefing output (non-vacuous negative for the check above)
NOENV=$(printf '{"session_id":"bs3"}' | ( cd "$BF" && KBFORGE_HOME="$FORGE" TMPDIR="$TMP" bash "$FORGE/session-kit/hooks/kb-briefing.sh" 2>/dev/null ))
printf '%s' "$NOENV" | grep -q '🔒 edit lane' && bad "no-env briefing wrongly shows lane" || ok "no-env briefing hides lane"

echo "freeze: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
