#!/bin/bash
# Tier 3 behavioral suite — paired KB-armed vs KB-blind runs per task.
# Manual, per release. ~2 headless claude sessions per task. Worktrees are
# throwaway; nothing touches a real branch.
# Usage: run.sh [--tasks <file>] [--only TASK-<n>]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not in a repo" >&2; exit 2; }
KB="$ROOT/.speccraft"
TASKS="$KB/evals/behavioral-tasks.md"; ONLY=""
while [ $# -gt 0 ]; do case "$1" in
  --tasks) TASKS=$2; shift 2;; --only) ONLY=$2; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -f "$TASKS" ] || { echo "no task file: $TASKS (author from behavioral/tasks-template.md)" >&2; exit 2; }
command -v claude >/dev/null || { echo "claude CLI required" >&2; exit 2; }
OUTDIR=$(mktemp -d); REPORT="$KB/evals/reports/$(date +%F)-behavioral.md"
mkdir -p "$KB/evals/reports"
ARMED_TOTAL=0; BLIND_TOTAL=0
{ echo "# Behavioral suite — $(date +%F)"; echo
  echo "| task | armed hits | blind hits |"; echo "|---|---|---|"; } > "$REPORT"

# split tasks file into blocks on '^## TASK-'
awk '/^## TASK-/{n++} n{print > ("'"$OUTDIR"'/task-" n ".block")}' "$TASKS"
for B in "$OUTDIR"/task-*.block; do
  ID=$(head -1 "$B" | sed 's/^## //; s/:.*//')
  [ -n "$ONLY" ] && [ "$ID" != "$ONLY" ] && continue
  PROMPT=$(sed -n 's/^prompt: //p' "$B")
  sed -n '/^tripwires:/,$p' "$B" | sed -n 's/^- //p' > "$OUTDIR/$ID.pats"
  H_ARMED=""; H_BLIND=""
  for MODE in armed blind; do
    WT="$OUTDIR/wt-$ID-$MODE"
    git -C "$ROOT" worktree add -q "$WT" HEAD
    if [ "$MODE" = blind ]; then
      rm -rf "$WT/.speccraft" "$WT/.claude" "$WT/.agents" "$WT/.opencode" "$WT/AGENTS.md"
    fi
    ( cd "$WT" && claude -p "$PROMPT" --permission-mode acceptEdits \
        --output-format text > "$OUTDIR/$ID-$MODE.txt" 2>&1 ) || true
    git -C "$WT" diff > "$OUTDIR/$ID-$MODE.diff" 2>/dev/null || true
    H=$("$HERE/check-tripwires.sh" "$OUTDIR/$ID.pats" \
        "$OUTDIR/$ID-$MODE.diff" "$OUTDIR/$ID-$MODE.txt" | sed -n 's/^HITS: //p')
    if [ "$MODE" = armed ]; then H_ARMED=$H; else H_BLIND=$H; fi
    git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null || true
  done
  echo "| $ID | $H_ARMED | $H_BLIND |" >> "$REPORT"
  ARMED_TOTAL=$((ARMED_TOTAL + H_ARMED)); BLIND_TOTAL=$((BLIND_TOTAL + H_BLIND))
  echo "$ID: armed $H_ARMED vs blind $H_BLIND tripwire hits"
done
{ echo; echo "**Totals: armed $ARMED_TOTAL vs blind $BLIND_TOTAL tripwire hits.**"
  echo; echo "Judgment calls (grade by hand per task transcripts in $OUTDIR):"
  echo "- Did the armed agent cite/recall KB facts? Push back on the divergence trap?"
} >> "$REPORT"
H="$KB/evals/health.md"
grep -v '^- last behavioral:' "$H" 2>/dev/null > "$H.tmp" || true
echo "- last behavioral: $(date +%F) armed $ARMED_TOTAL vs blind $BLIND_TOTAL tripwire hits" >> "$H.tmp"
mv "$H.tmp" "$H"
echo "report: $REPORT (transcripts kept in $OUTDIR until reboot — grade, then discard)"
