#!/bin/bash
# kb-forge evals self-test — seeded-defect fixtures. Asserts every planted
# defect is caught and clean fixtures pass. Usage: self-test.sh [section]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ONLY="${1:-all}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
no(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert_contains(){ printf '%s' "$1" | grep -qE "$2" && ok || no "$3"; }
assert_not_contains(){ printf '%s' "$1" | grep -qE "$2" && no "$3" || ok; }
run_section(){ [ "$ONLY" = all ] || [ "$ONLY" = "$1" ]; }

# ---------- section: lib ----------
if run_section lib; then
  T=$(mktemp -d); export KB="$T/superdev"; mkdir -p "$KB"
  . "$HERE/telemetry-lib.sh"
  KB_SESSION_ID=sess1 kb_telemetry recall_ran "src/app.py"
  OUT=$(cat "$KB/evals/telemetry.jsonl" 2>/dev/null)
  assert_contains "$OUT" '"event":"recall_ran"' "lib: event written"
  assert_contains "$OUT" '"session":"sess1"' "lib: session recorded"
  echo "$OUT" | jq -e . >/dev/null 2>&1 && ok || no "lib: line is valid JSON"
  # never fails caller even with unwritable KB
  KB=/nonexistent kb_telemetry x && ok || no "lib: returns 0 on bad KB"
  # size backstop: >5MB truncates to newest 10000 lines
  yes '{"ts":"2026-01-01T00:00:00Z","session":"s","event":"pad","detail":""}' \
    | head -75000 > "$KB/evals/telemetry.jsonl"
  kb_telemetry after_backstop
  LINES=$(wc -l < "$KB/evals/telemetry.jsonl" | tr -d ' ')
  [ "$LINES" -le 10001 ] && ok || no "lib: size backstop truncated ($LINES lines)"
  tail -1 "$KB/evals/telemetry.jsonl" | grep -q after_backstop && ok || no "lib: append after backstop"
  rm -rf "$T"; unset KB
fi

# ---------- section: report ----------
if run_section report; then
  T=$(mktemp -d); KB="$T/superdev"; mkdir -p "$KB/evals" "$KB/findings"
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  sed "s/REPLACETS/$NOW/" "$HERE/fixtures/telemetry.jsonl" > "$KB/evals/telemetry.jsonl"
  printf -- '- last audit: none\n' > /dev/null # (health starts absent)
  OUT=$("$HERE/telemetry-report.sh" --kb "$KB")
  assert_contains "$OUT" 'recall 1/2' "report: recall rate 1/2 sessions"
  assert_contains "$OUT" 'ratify 1 used, 1 blocked' "report: ratify counts"
  assert_contains "$OUT" 'queue 14→12' "report: queue trend"
  assert_contains "$OUT" 'unparseable 2' "report: malformed counted"
  grep -q 'recall 1/2' "$KB/evals/health.md" && ok || no "report: health.md written"
  # GC: pruned the 2020 line and the malformed lines
  grep -q '"session":"old"' "$KB/evals/telemetry.jsonl" && no "report: GC pruned old line" || ok
  L=$(wc -l < "$KB/evals/telemetry.jsonl" | tr -d ' ')
  [ "$L" -eq 8 ] && ok || no "report: GC kept 8 in-retention parseable lines (got $L)"
  # breach finding NOT written (only 2 sessions < 5 minimum)
  ls "$KB/findings/" | grep -q evals-recall && no "report: no breach under min sessions" || ok
  # preserves audit/behavioral lines on rerun
  echo '- last audit: 2026-07-21 precision 0.85' >> "$KB/evals/health.md"
  "$HERE/telemetry-report.sh" --kb "$KB" > /dev/null
  grep -q 'last audit: 2026-07-21' "$KB/evals/health.md" && ok || no "report: preserves audit line"
  rm -rf "$T"
fi

echo "self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
