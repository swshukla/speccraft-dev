#!/bin/bash
# PreToolUse hook (Edit|Write|MultiEdit) — deny session writes to the KB's
# founder/machine lanes at edit time (friendly early layer; the git
# pre-commit hook is the hard chokepoint). Repo-relative.
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
KB=$ROOT/superdev
FORGE="${KBFORGE_HOME:-$HOME/superdev/kb-forge}"
. "$FORGE/session-kit/evals/telemetry-lib.sh" 2>/dev/null || kb_telemetry(){ :; }

FP=$(jq -r '.tool_input.file_path // empty')
case "$FP" in
  "$KB"/kb/normative/*|"$KB"/ledger/*|"$KB"/kb/derived/*|"$KB"/README.md|"$KB"/KB-STATUS.md)
    kb_telemetry guard_block "${FP#"$ROOT"/}"
    jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",
      permissionDecision:"deny",
      permissionDecisionReason:"KB founder/machine lane. Sessions write only superdev/QUEUE.md (append), superdev/kb/decisions/, superdev/kb/inferred/. Use the superdev-diverge skill to propose the change — ratification is human-only."}}'
    ;;
esac
exit 0
