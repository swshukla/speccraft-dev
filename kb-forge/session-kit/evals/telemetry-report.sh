#!/bin/bash
# Tier 1 evals report — rates over window, telemetry GC, health snippet,
# breach finding. Never blocks anything; exit 0 unless bad args.
# Usage: telemetry-report.sh [--kb <.speccraft-dir>] [--window N] [--retention N]
set -u
KB=""; WINDOW=""; RET=""
while [ $# -gt 0 ]; do case "$1" in
  --kb) KB=$2; shift 2;; --window) WINDOW=$2; shift 2;;
  --retention) RET=$2; shift 2;; *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$KB" ] || KB="$(git rev-parse --show-toplevel 2>/dev/null)/.speccraft"
F="$KB/evals/telemetry.jsonl"
[ -f "$F" ] || exit 0
cfgval(){ awk -v k="$1:" '$1==k {print $2; exit}' "$KB/kbforge.yaml" 2>/dev/null; }
WINDOW="${WINDOW:-$(cfgval report_window_days)}"; WINDOW="${WINDOW:-14}"
RET="${RET:-$(cfgval telemetry_retention_days)}"; RET="${RET:-90}"
MINR=$(cfgval min_recall_rate); MINR=${MINR:-0.70}
cutoff(){ date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
       || date -u -d "-$1 days" +%Y-%m-%dT%H:%M:%SZ; }
CUT_RET=$(cutoff "$RET"); CUT_WIN=$(cutoff "$WINDOW")

TOTAL=$(wc -l < "$F" | tr -d ' ')
PARSED_F=$(mktemp)
jq -cR 'fromjson? // empty' "$F" > "$PARSED_F"
BAD=$((TOTAL - $(wc -l < "$PARSED_F" | tr -d ' ')))
# GC: atomic prune to parseable + in-retention
jq -c --arg c "$CUT_RET" 'select(.ts >= $c)' "$PARSED_F" > "$F.tmp" && mv "$F.tmp" "$F"
WIN=$(jq -c --arg c "$CUT_WIN" 'select(.ts >= $c)' "$PARSED_F"); rm -f "$PARSED_F"

uniq_sessions(){ printf '%s\n' "$WIN" | jq -r "select(.event$1) | .session" | sort -u | grep -c .; }
DEN=$(uniq_sessions '=="recall_ran" or .event=="recall_empty"' || true)
NUM=$(uniq_sessions '=="recall_ran"' || true)
count_ev(){ printf '%s\n' "$WIN" | jq -c "select(.event==\"$1\")" | grep -c . || true; }
RUSED=$(count_ev ratify_used); RBLOCK=$(count_ev guard_commit_block)
statuses(){ printf '%s\n' "$WIN" | jq -r 'select(.event=="kb_status") | .detail'; }
QF=$(statuses | head -1 | sed -n 's/.*queue=\([0-9]*\).*/\1/p')
QL=$(statuses | tail -1 | sed -n 's/.*queue=\([0-9]*\).*/\1/p')
LF=$(statuses | head -1 | sed -n 's/.*ledger=\([0-9]*\).*/\1/p')
LL=$(statuses | tail -1 | sed -n 's/.*ledger=\([0-9]*\).*/\1/p')

LINE="- evals telemetry (last ${WINDOW}d): recall ${NUM}/${DEN} sessions | ratify ${RUSED} used, ${RBLOCK} blocked | queue ${QF:-?}→${QL:-?} | ledger ${LF:-?}→${LL:-?} | unparseable ${BAD}"
echo "$LINE"
H="$KB/evals/health.md"
KEEP=$(grep -E '^- last (audit|behavioral):' "$H" 2>/dev/null || true)
{ echo "$LINE"; [ -n "$KEEP" ] && printf '%s\n' "$KEEP"; } > "$H"

if [ "${DEN:-0}" -ge 5 ] && awk "BEGIN{exit !($NUM/$DEN < $MINR)}"; then
  mkdir -p "$KB/findings"
  FD="$KB/findings/$(date +%F)-evals-recall-rate.md"
  [ -f "$FD" ] || cat > "$FD" <<EOF
# Finding: KB recall rate below threshold
- window: last ${WINDOW}d | recall sessions: ${NUM}/${DEN} (< ${MINR})
- meaning: the loop is not engaged; Tier 2/3 eval results are unattributable.
- source: evals telemetry ($(date +%F)); see .speccraft/evals/telemetry.jsonl
EOF
fi
exit 0
