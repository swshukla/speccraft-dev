#!/bin/bash
# PostToolUse hook (Edit|Write|MultiEdit) — capture-on-contact: after the
# session touches a product file, inject the KB facts anchored to it.
# Repo-relative; deduped per session+file; KB files don't trigger recall.
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

CACHE="${TMPDIR:-/tmp}/speccraft-recall-seen-$SID"
grep -qxF "$REL" "$CACHE" 2>/dev/null && exit 0
echo "$REL" >> "$CACHE"

OUT=$(python3 "$FORGE/recall.py" --config "$KB/kbforge.yaml" --files "$REL" 2>/dev/null | head -20)
export KB_SESSION_ID="$SID"
[ -z "$OUT" ] && { kb_telemetry recall_empty "$REL"; exit 0; }
kb_telemetry recall_ran "$REL"

printf '%s' "$OUT" | jq -Rs --arg rel "$REL" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",
    additionalContext:("KB recall for \($rel) — honor ratified facts; queue divergences (speccraft-diverge), never self-ratify:\n" + .)}}'
exit 0
