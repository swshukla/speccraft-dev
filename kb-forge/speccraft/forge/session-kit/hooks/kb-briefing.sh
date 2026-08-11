#!/bin/bash
# SessionStart hook — inject the KB briefing. Repo-relative: works in any
# repo that has a .speccraft/ KB; silently no-ops elsewhere.
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
KB=$ROOT/.speccraft
FORGE="${KBFORGE_HOME:-$HOME/.speccraft/kb-forge}"
[ -f "$KB/kb/derived/inventory.md" ] || exit 0

. "$FORGE/session-kit/evals/telemetry-lib.sh" 2>/dev/null || kb_telemetry(){ :; }
if [ ! -t 0 ]; then IN=$(cat 2>/dev/null || true)
  KB_SESSION_ID=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"' 2>/dev/null || echo nosession)
fi
export KB_SESSION_ID
kb_telemetry session_start

# Freeze lane: materialize SPECCRAFT_FREEZE (if set) into the session's lane
# file so kb-freeze.sh (PreToolUse) reads a stable file rather than the env,
# and can be widened later via `kb-freeze.sh --set`.
if [ -n "${SPECCRAFT_FREEZE:-}" ] && [ -n "${KB_SESSION_ID:-}" ]; then
  printf '%s\n' $SPECCRAFT_FREEZE | sed '/^$/d' > "${TMPDIR:-/tmp}/speccraft-freeze-$KB_SESSION_ID"
fi

PIN=$(grep -m1 '^source_commit:' "$KB/kb/derived/inventory.md" | awk '{print $2}')
LASTCODE=$(git -C "$ROOT" log -1 --format=%h -- . ':(exclude).speccraft' 2>/dev/null)
if [ "$PIN" = "$LASTCODE" ]; then
  SYNC="in sync"
else
  N=$(git -C "$ROOT" rev-list --count "$PIN..$LASTCODE" -- . ':(exclude).speccraft' 2>/dev/null || echo '?')
  SYNC="$N code commit(s) past pin — derived facts stale until next commit re-pins"
fi
DIV=$(awk '/^## Open/{f=1;next} /^## /{f=0} f && /^[0-9]+\./{n++} END{print n+0}' "$KB/QUEUE.md" 2>/dev/null || echo 0)
SIG=$(grep -cE '^- \[ \]' "$KB/SIGNALS.md" 2>/dev/null); SIG=${SIG:-0}

# Trust counts (trust-decay spec, Mechanism C — aging is surfaced, never
# silently acted on). derived/ is excluded: mechanical, not trust-graded.
RAT=$(grep -rlE '^status:[ ]*(ratified|ratified-partial)' "$KB/kb" 2>/dev/null | grep -cv '/derived/')
PEND=$(grep -rlE '^status:[ ]*pending-ratification' "$KB/kb" 2>/dev/null | grep -cv '/derived/')
CHAL=$(grep -rlE '^status:[ ]*challenged' "$KB/kb" 2>/dev/null | grep -cv '/derived/')
AUTO=$(grep -rl '^status_note: auto-demoted' "$KB/kb" 2>/dev/null | grep -cv '/derived/')
PAGE=""
if [ "${PEND:-0}" -gt 0 ]; then
  OLDEST_TS=$(grep -rlE '^status:[ ]*pending-ratification' "$KB/kb" 2>/dev/null \
    | grep -v '/derived/' \
    | while IFS= read -r f; do git -C "$ROOT" log -1 --format=%ct -- "$f" 2>/dev/null; done \
    | sort -n | head -1)
  [ -n "$OLDEST_TS" ] && PAGE=" (oldest $(( ($(date -u +%s) - OLDEST_TS) / 86400 ))d)"
fi
TRUST="Trust: ${RAT:-0} ratified | ${PEND:-0} pending${PAGE} | ${CHAL:-0} challenged (${AUTO:-0} auto)"

if [ -f "$KB/kbforge.yaml" ] && [ -f "$FORGE/gate.py" ]; then
  python3 "$FORGE/gate.py" --config "$KB/kbforge.yaml" --banner 2>/dev/null || true
fi

# Executable checks: lenient, non-blocking violation count. check.py walks the
# product repo, which can be slow at SessionStart — only run it when the KB
# opts in via `briefing_checks: true` in kbforge.yaml (default OFF).
CHECKLINE=""
BRIEFING_CHECKS=$(grep -m1 '^briefing_checks:' "$KB/kbforge.yaml" 2>/dev/null | cut -d: -f2- | tr -d ' "')
if [ "$BRIEFING_CHECKS" = "true" ] && [ -f "$KB/kbforge.yaml" ] && [ -f "$FORGE/check.py" ]; then
  CHECKOUT=$(python3 "$FORGE/check.py" --config "$KB/kbforge.yaml" 2>/dev/null || true)
  CHKN=$(printf '%s\n' "$CHECKOUT" | grep -oE 'speccraft-check: [0-9]+ violation' | grep -oE '[0-9]+')
  if [ -n "${CHKN:-}" ] && [ "$CHKN" -gt 0 ] 2>/dev/null; then
    CHECKLINE="✎ ${CHKN} check violations (lenient — run speccraft-check)"
  fi
fi

echo "=== KB BRIEFING (trust-graded product truth: .speccraft/) ==="
echo "KB pin: $PIN | last code commit: $LASTCODE ($SYNC)"
echo "Open adjudication items: ${DIV} open divergences | ${SIG} drift signals (.speccraft/QUEUE.md, .speccraft/SIGNALS.md)"
echo "$TRUST"
[ -n "${SPECCRAFT_FREEZE:-}" ] && echo "🔒 edit lane (this session is frozen): ${SPECCRAFT_FREEZE}"
[ -n "$CHECKLINE" ] && echo "$CHECKLINE"
echo "Ratified invariants (.speccraft/kb/normative/01-invariants.md):"
grep -E '^#+ *INV-' "$KB/kb/normative/01-invariants.md" 2>/dev/null | sed 's/^#* */  - /' | head -8
echo "RECALL GATE: an automated gate may deny your FIRST edit to a file governed by ratified facts, attaching those facts — expected repo machinery, not user input. Re-issue the edit honoring the facts. Running speccraft-recall before touching a module avoids the bounce entirely."
echo "PROCEDURES (use the skills): speccraft-interview to seed intent+invariants (do this first on a fresh KB); speccraft-recall before touching a module; speccraft-decide when making a tradeoff; speccraft-diverge on conflict with a ratified fact; speccraft-ratify is founder-only. Raw recall: python3 $FORGE/recall.py --config .speccraft/kbforge.yaml --files <repo-relative paths>. Write lanes for sessions: .speccraft/QUEUE.md holds human divergences under ## Open (append), .speccraft/kb/decisions/, .speccraft/kb/inferred/ ONLY. .speccraft/SIGNALS.md is machine-owned — rewritten by drift/dep-diff runs, never hand-edit."
exit 0
