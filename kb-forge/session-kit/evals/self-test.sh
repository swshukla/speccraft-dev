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
mk_repo(){ # $1 = fixture superdev parent dir; echoes new repo path
  local R; R=$(mktemp -d)
  ( cd "$R" && git init -q \
    && mkdir -p src docs && echo 'app' > src/app.py && echo 'ov' > docs/OVERVIEW.md \
    && cp -R "$1"/superdev . && git add -A && git commit -qm init \
    && C=$(git rev-parse --short HEAD) \
    && grep -rl '__COMMIT__' superdev | while read -r f; do sed -i '' "s/__COMMIT__/$C/g" "$f"; done \
    && git add -A && git commit -qm pin ) >/dev/null 2>&1
  echo "$R"
}

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

# ---------- section: hooks ----------
if run_section hooks; then
  KIT="$(cd "$HERE/.." && pwd)"
  for s in "$KIT/hooks/kb-briefing.sh" "$KIT/hooks/kb-recall-post.sh" \
           "$KIT/hooks/kb-guard.sh" "$KIT/hooks/kb-status.sh"; do
    bash -n "$s" && ok || no "hooks: bash syntax $s"
    grep -q 'telemetry-lib.sh' "$s" && ok || no "hooks: $s sources telemetry lib"
  done
  sh -n "$KIT/pre-commit" && ok || no "hooks: sh syntax pre-commit"
  grep -q 'ratify_used' "$KIT/pre-commit" && ok || no "hooks: pre-commit logs ratify_used"
  grep -q 'guard_commit_block' "$KIT/pre-commit" && ok || no "hooks: pre-commit logs guard_commit_block"
  grep -q 'kb_telemetry kb_status' "$KIT/hooks/kb-status.sh" && ok || no "hooks: kb-status logs counts"
  grep -q 'evals/health.md' "$KIT/hooks/kb-status.sh" && ok || no "hooks: kb-status embeds health"
  # safety: hooks still no-op cleanly outside any KB repo
  D=$(mktemp -d); (cd "$D" && git init -q .)
  (cd "$D" && "$KIT/hooks/kb-briefing.sh" </dev/null) && ok || no "hooks: briefing no-op exits 0"
  (cd "$D" && echo '{}' | "$KIT/hooks/kb-recall-post.sh") && ok || no "hooks: recall-post no-op exits 0"
  rm -rf "$D"
fi

# ---------- section: audit ----------
if run_section audit; then
  RC=$(mk_repo "$HERE/fixtures/kb-clean")
  OUT=$("$HERE/kb-audit.sh" --root "$RC" --kb "$RC/superdev")
  assert_contains "$OUT" 'AUDIT: 0 issues' "audit: clean fixture passes"
  ls "$RC/superdev/evals/reports/" | grep -q audit.md && ok || no "audit: report written"
  RD=$(mk_repo "$HERE/fixtures/kb-defects")
  OUT=$("$HERE/kb-audit.sh" --root "$RD" --kb "$RD/superdev")
  assert_contains "$OUT" 'anchor-rot: .*src/gone.py' "audit: catches dead anchor"
  assert_contains "$OUT" "illegal status 'verified'" "audit: catches illegal status"
  assert_contains "$OUT" 'duplicate invariant ids: INV-1' "audit: catches dup INV"
  assert_contains "$OUT" 'provenance: .*neither elicited_by nor documented_by' "audit: catches missing provenance"
  assert_contains "$OUT" 'documented_by path missing: docs/MISSING.md' "audit: catches dead doc path"
  assert_contains "$OUT" 'AUDIT: 5 issues' "audit: issue count"
  rm -rf "$RC" "$RD"
fi

# ---------- section: judge ----------
if run_section judge; then
  RC=$(mk_repo "$HERE/fixtures/kb-clean")
  chmod +x "$HERE/fixtures/bin/claude"
  OUT=$(PATH="$HERE/fixtures/bin:$PATH" "$HERE/kb-audit.sh" --root "$RC" --kb "$RC/superdev" --judge)
  R=$(cat "$RC"/superdev/evals/reports/*-audit.md)
  assert_contains "$R" 'SUPPORTED' "judge: verdicts in report"
  assert_contains "$R" 'precision 0.33' "judge: precision computed (1/3)"
  Q=$(cat "$RC/superdev/QUEUE.md")
  assert_contains "$Q" 'CONTRADICTED.*INV-2' "judge: contradiction queued"
  assert_contains "$Q" 'POSSIBLY_STALE.*INV-1' "judge: stale queued"
  assert_not_contains "$Q" 'retail users' "judge: SUPPORTED not queued"
  grep -q 'last audit: .*precision 0.33' "$RC/superdev/evals/health.md" \
    && ok || no "judge: health line upserted"
  # elicited intent files are never sampled as claims (only INVs get the compliance pass)
  assert_not_contains "$R" 'Identity: a demo product' "judge: elicited claims not judged"
  # no claude on PATH -> semantic SKIPPED, still exit 0
  RC2=$(mk_repo "$HERE/fixtures/kb-clean")
  OUT2=$(PATH=/usr/bin:/bin "$HERE/kb-audit.sh" --root "$RC2" --kb "$RC2/superdev" --judge)
  grep -q 'SKIPPED' "$RC2"/superdev/evals/reports/*-audit.md && ok || no "judge: skips without claude"
  rm -rf "$RC" "$RC2"
fi

# ---------- section: behavioral ----------
if run_section behavioral; then
  CT="$HERE/behavioral/check-tripwires.sh"
  OUT=$("$CT" "$HERE/fixtures/diffs/tripwires.txt" "$HERE/fixtures/diffs/violating.diff")
  assert_contains "$OUT" 'HITS: 2' "behavioral: violating diff trips both"
  OUT=$("$CT" "$HERE/fixtures/diffs/tripwires.txt" "$HERE/fixtures/diffs/clean.diff")
  assert_contains "$OUT" 'HITS: 0' "behavioral: clean diff trips none"
  bash -n "$HERE/behavioral/run.sh" && ok || no "behavioral: run.sh syntax"
  grep -q 'worktree remove' "$HERE/behavioral/run.sh" && ok || no "behavioral: worktrees cleaned up"
fi

echo "self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
