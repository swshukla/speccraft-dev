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

export KB_SESSION_ID="$SID"   # before recall: recall.py self-logs recall_ran
OUT=$(python3 "$FORGE/recall.py" --config "$KB/kbforge.yaml" --files "$REL" \
      --harness claude-hook 2>/dev/null | head -20)

# No-coverage disambiguation: silence is ambiguous, so say so explicitly —
# and say it louder when the path is risk-tagged in kbforge.yaml.
if [ -z "$OUT" ] || printf '%s' "$OUT" | grep -q '^NO KB COVERAGE'; then
  kb_telemetry recall_empty "$REL"
  RISK=$(grep -m1 '^risk_paths:' "$KB/kbforge.yaml" | cut -d: -f2- | tr -d ' "')
  if [ -n "$RISK" ] && printf '%s' "$REL" | grep -qE "$RISK" 2>/dev/null; then
    MSG="No KB coverage for $REL — this path is risk-tagged; proceed with caution and consider eliciting intent (speccraft-interview) before building further."
  else
    MSG="No KB coverage for $REL."
  fi
  printf '%s' "$MSG" | jq -Rs \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:.}}'
  exit 0
fi
# recall_ran is logged by recall.py itself (--harness claude-hook)

printf '%s' "$OUT" | jq -Rs --arg rel "$REL" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",
    additionalContext:("KB recall for \($rel) — honor ratified facts; queue divergences (speccraft-diverge), never self-ratify:\n" + .)}}'
exit 0
