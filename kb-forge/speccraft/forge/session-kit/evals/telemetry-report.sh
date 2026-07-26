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
SGBLOCK=$(count_ev stale_guard_block); SGACK=$(count_ev stale_ack)
if [ "${SGBLOCK:-0}" -gt 0 ]; then
  SGRATIO=$(awk "BEGIN{printf \"%.2f\", $SGACK/$SGBLOCK}")
else
  SGRATIO="n/a"
fi
# Per-harness recall breakdown + commit-side eligibility bound
# (harness-agnostic-recall-proxy rev 2, Parts A+B). recall_ran counts are
# per-file-per-session, recall_eligible per-file-per-commit and includes
# human commits — different units, both inflating the same direction, so
# the ratio is an UPPER BOUND on the untracked fraction, never a rate.
TRACKED=$(count_ev recall_ran)
HARNESS_BD=$(printf '%s\n' "$WIN" \
  | jq -r 'select(.event=="recall_ran") | .harness // "untagged"' \
  | sort | uniq -c | awk '{printf "%s%s:%s", s, $2, $1; s=" "}')
ELIG=$(printf '%s\n' "$WIN" \
  | jq -r 'select(.event=="recall_eligible") | .detail' \
  | awk -F/ '{s+=$1} END{print s+0}')
if [ "${ELIG:-0}" -gt 0 ]; then
  UBPCT=$(awk "BEGIN{u=1-$TRACKED/$ELIG; if(u<0)u=0; printf \"%d\", u*100+0.5}")
  BOUND="<=${UBPCT}% (upper bound)"
else
  UBPCT=""; BOUND="n/a"
fi

statuses(){ printf '%s\n' "$WIN" | jq -r 'select(.event=="kb_status") | .detail'; }
QF=$(statuses | head -1 | sed -n 's/.*queue=\([0-9]*\).*/\1/p')
QL=$(statuses | tail -1 | sed -n 's/.*queue=\([0-9]*\).*/\1/p')
LF=$(statuses | head -1 | sed -n 's/.*ledger=\([0-9]*\).*/\1/p')
LL=$(statuses | tail -1 | sed -n 's/.*ledger=\([0-9]*\).*/\1/p')

LINE="- evals telemetry (last ${WINDOW}d): tracked recall ${NUM}/${DEN} sessions | recall_ran ${TRACKED} [${HARNESS_BD:-none}] vs eligible ${ELIG} file-touches → untracked ${BOUND} | ratify ${RUSED} used, ${RBLOCK} blocked | stale ${SGBLOCK} blocked, ${SGACK} acked (ack/block ${SGRATIO}) | queue ${QF:-?}→${QL:-?} | ledger ${LF:-?}→${LL:-?} | unparseable ${BAD}"
echo "$LINE"
H="$KB/evals/health.md"
KEEP=$(grep -E '^- last (audit|behavioral):' "$H" 2>/dev/null || true)
{ echo "$LINE"; [ -n "$KEEP" ] && printf '%s\n' "$KEEP"; } > "$H"

# health.json — structured twin of health.md (mission-control rev 2 contract:
# the dashboard reads this; it never parses the markdown)
printf '%s\n' "$WIN" | jq -s \
  --argjson win "${WINDOW}" --argjson num "${NUM:-0}" --argjson den "${DEN:-0}" \
  --argjson tracked "${TRACKED:-0}" --argjson elig "${ELIG:-0}" \
  --argjson ub "${UBPCT:-null}" --argjson rused "${RUSED:-0}" \
  --argjson rblock "${RBLOCK:-0}" --argjson sgb "${SGBLOCK:-0}" \
  --argjson sga "${SGACK:-0}" --argjson bad "${BAD:-0}" '
  {generated_at: (now | todate),
   window_days: $win,
   tracked_recall_sessions: {num: $num, den: $den},
   recall_ran_total: $tracked,
   recall_by_harness: ([.[] | select(.event=="recall_ran")
                        | (.harness // "untagged")] | group_by(.)
                        | map({(.[0]): length}) | add // {}),
   eligible_file_touches: $elig,
   untracked_upper_bound_pct: $ub,
   ratify: {used: $rused, blocked: $rblock},
   stale_guard: {blocked: $sgb, acked: $sga},
   unparseable: $bad}' > "$KB/evals/health.json" 2>/dev/null || true

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
