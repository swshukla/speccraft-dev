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

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
KB=$ROOT/.speccraft
FORGE="${KBFORGE_HOME:-$HOME/.speccraft/kb-forge}"
[ -f "$KB/kbforge.yaml" ] || exit 0
. "$FORGE/session-kit/evals/telemetry-lib.sh" 2>/dev/null || kb_telemetry(){ :; }

IN=$(cat)
FP=$(printf '%s' "$IN" | jq -r '.tool_input.file_path // empty')
SID=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"')
case "$FP" in
  "$KB"/*) exit 0 ;;
  "$ROOT"/*) REL=${FP#"$ROOT"/} ;;
  *) exit 0 ;;
esac

FREEZE="${TMPDIR:-/tmp}/speccraft-freeze-$SID"
LANES=""
if [ -f "$FREEZE" ]; then
  LANES=$(cat "$FREEZE")
elif [ -n "${SPECCRAFT_FREEZE:-}" ]; then
  LANES=$(printf '%s\n' $SPECCRAFT_FREEZE)   # word-split env into lines (intentional, unquoted)
fi
# keep only non-blank lane prefixes; if none, the session is effectively unfrozen (fail open)
LANES=$(printf '%s\n' "$LANES" | sed 's/[[:space:]]*$//' | grep -v '^[[:space:]]*$' || true)
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
