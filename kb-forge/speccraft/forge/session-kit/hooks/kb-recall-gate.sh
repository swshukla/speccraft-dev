#!/bin/bash
# PreToolUse hook (Edit|Write|MultiEdit) — recall gate: deny-once on the
# FIRST edit to a file anchored by ratified normative facts, carrying the
# facts in the deny reason. The speccraft-recall skill pre-clears the gate
# by writing the same dedup cache. Deny wording is the empirically
# validated v3 template (spec 2026-07-25-pre-edit-recall-injection.md):
# briefing reference + verifiable KB paths + divergence rule — coercive
# variants get classified as prompt injection and ignored.
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

OUT=$(python3 "$FORGE/recall.py" --config "$KB/kbforge.yaml" \
      --lanes normative --gate-check --files "$REL" 2>/dev/null)
[ $? -ne 3 ] && exit 0   # no ratified normative anchor — passive tier covers it

echo "$REL" >> "$CACHE"   # deny at most once: the retry passes
export KB_SESSION_ID="$SID"
kb_telemetry recall_gate_block "$REL"

REASON="RECALL GATE (.speccraft session-kit, announced in your session briefing): first edit to a KB-governed file.
$REL is anchored by ratified facts in the KB (paths relative to .speccraft/):
$OUT
Your edit was not applied. Re-issue it now, honoring these facts alongside the user's request. To verify a fact, Read the KB file listed above. If a fact genuinely conflicts with the user's explicit request, follow the user and queue the divergence (speccraft-diverge) — never self-ratify. The gate fires once per file per session; your next edit to $REL will proceed."

jq -n --arg r "$REASON" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
