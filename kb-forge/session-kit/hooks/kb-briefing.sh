#!/bin/bash
# SessionStart hook — inject the KB briefing. Repo-relative: works in any
# repo that has a superdev/ KB; silently no-ops elsewhere.
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
KB=$ROOT/superdev
FORGE="${KBFORGE_HOME:-$HOME/superdev/kb-forge}"
[ -f "$KB/kb/derived/inventory.md" ] || exit 0

. "$FORGE/session-kit/evals/telemetry-lib.sh" 2>/dev/null || kb_telemetry(){ :; }
if [ ! -t 0 ]; then IN=$(cat 2>/dev/null || true)
  KB_SESSION_ID=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"' 2>/dev/null || echo nosession)
fi
export KB_SESSION_ID
kb_telemetry session_start

PIN=$(grep -m1 '^source_commit:' "$KB/kb/derived/inventory.md" | awk '{print $2}')
LASTCODE=$(git -C "$ROOT" log -1 --format=%h -- . ':(exclude)superdev' 2>/dev/null)
if [ "$PIN" = "$LASTCODE" ]; then
  SYNC="in sync"
else
  N=$(git -C "$ROOT" rev-list --count "$PIN..$LASTCODE" -- . ':(exclude)superdev' 2>/dev/null || echo '?')
  SYNC="$N code commit(s) past pin — derived facts stale until next commit re-pins"
fi
OPEN=$(grep -cE '^[0-9]+\.' "$KB/QUEUE.md" 2>/dev/null || echo '?')

echo "=== KB BRIEFING (trust-graded product truth: superdev/) ==="
echo "KB pin: $PIN | last code commit: $LASTCODE ($SYNC)"
echo "Open adjudication items: $OPEN (superdev/QUEUE.md)"
echo "Ratified invariants (superdev/kb/normative/01-invariants.md):"
grep -E '^#+ *INV-' "$KB/kb/normative/01-invariants.md" 2>/dev/null | sed 's/^#* */  - /' | head -8
echo "PROCEDURES (use the skills): superdev-interview to seed intent+invariants (do this first on a fresh KB); superdev-recall before touching a module; superdev-decide when making a tradeoff; superdev-diverge on conflict with a ratified fact; superdev-ratify is founder-only. Raw recall: python3 $FORGE/recall.py --config superdev/kbforge.yaml --files <repo-relative paths>. Write lanes for sessions: superdev/QUEUE.md (append), superdev/kb/decisions/, superdev/kb/inferred/ ONLY."
exit 0
