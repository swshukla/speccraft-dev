#!/bin/bash
# kb-forge evals self-test — seeded-defect fixtures. Asserts every planted
# defect is caught and clean fixtures pass. Usage: self-test.sh [section]
set -u
exec </dev/null   # hooks under test $(cat) stdin; never inherit the caller's
HERE="$(cd "$(dirname "$0")" && pwd)"
ONLY="${1:-all}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
no(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert_contains(){ printf '%s' "$1" | grep -qE "$2" && ok || no "$3"; }
assert_not_contains(){ printf '%s' "$1" | grep -qE "$2" && no "$3" || ok; }
run_section(){ [ "$ONLY" = all ] || [ "$ONLY" = "$1" ]; }
mk_repo(){ # $1 = fixture .speccraft parent dir; echoes new repo path
  local R; R=$(mktemp -d)
  ( cd "$R" && git init -q \
    && mkdir -p src docs && echo 'app' > src/app.py && echo 'ov' > docs/OVERVIEW.md \
    && cp -R "$1"/.speccraft . && git add -A && git commit -qm init \
    && C=$(git rev-parse --short HEAD) \
    && grep -rl '__COMMIT__' .speccraft | while read -r f; do sed -i '' "s/__COMMIT__/$C/g" "$f"; done \
    && git add -A && git commit -qm pin ) >/dev/null 2>&1
  echo "$R"
}

# ---------- section: lib ----------
if run_section lib; then
  T=$(mktemp -d); export KB="$T/.speccraft"; mkdir -p "$KB"
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
  T=$(mktemp -d); KB="$T/.speccraft"; mkdir -p "$KB/evals" "$KB/findings"
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
  (cd "$D" && echo '{}' | "$KIT/hooks/kb-recall-gate.sh") && ok || no "hooks: recall-gate no-op exits 0"
  rm -rf "$D"

  # recall gate — deny-once on ratified normative anchors
  bash -n "$KIT/hooks/kb-recall-gate.sh" && ok || no "hooks: bash syntax kb-recall-gate.sh"
  RG=$(mk_repo "$HERE/fixtures/kb-clean"); RG=$(cd "$RG" && pwd -P); SIDG="st$$"
  python3 "$KIT/../recall.py" --config "$RG/.speccraft/kbforge.yaml" \
    --lanes normative --gate-check --files src/app.py >/dev/null 2>&1
  [ $? -eq 3 ] && ok || no "recall: gate-check exits 3 on ratified normative anchor"
  python3 "$KIT/../recall.py" --config "$RG/.speccraft/kbforge.yaml" \
    --lanes normative --gate-check --files nowhere/x.py >/dev/null 2>&1
  [ $? -eq 0 ] && ok || no "recall: gate-check exits 0 when uncovered"
  OUTG=$(cd "$RG" && printf '{"session_id":"%s","tool_input":{"file_path":"%s/src/app.py"}}' "$SIDG" "$RG" \
    | KBFORGE_HOME="$KIT/.." "$KIT/hooks/kb-recall-gate.sh")
  printf '%s' "$OUTG" | grep -q '"permissionDecision": *"deny"' && ok || no "hooks: gate denies first edit to governed file"
  printf '%s' "$OUTG" | grep -q 'kb/normative/' && ok || no "hooks: deny reason cites verifiable KB path"
  OUTG2=$(cd "$RG" && printf '{"session_id":"%s","tool_input":{"file_path":"%s/src/app.py"}}' "$SIDG" "$RG" \
    | KBFORGE_HOME="$KIT/.." "$KIT/hooks/kb-recall-gate.sh")
  [ -z "$OUTG2" ] && ok || no "hooks: gate denies at most once per session+file"
  rm -f "${TMPDIR:-/tmp}/speccraft-recall-seen-$SIDG"; rm -rf "$RG"
fi

# ---------- section: audit ----------
# ---------- drift: anchor scope (third direction) ----------
if run_section drift; then
  KIT="$(cd "$HERE/.." && pwd)"
  RD=$(mk_repo "$HERE/fixtures/kb-clean"); RD=$(cd "$RD" && pwd -P)
  echo "repo: ." >> "$RD/.speccraft/kbforge.yaml"   # fixture yaml has no repo key
  ( cd "$RD" \
    && printf -- "---\nname: scope-inv\nstatus: ratified\nanchors: [src/]\n---\n# INV-S\n" \
       > .speccraft/kb/normative/02-scope.md \
    && printf -- "---\nname: scope-obs\nstatus: observed\nanchors: [docs/]\n---\n# OBS-S\n" \
       > .speccraft/kb/inferred/09-scope.md \
    && git add -A && git commit -qm facts \
    && C=$(git rev-parse --short HEAD) \
    && sed -i '' "s/^source_commit:.*/source_commit: $C/" .speccraft/kb/derived/inventory.md \
    && mkdir -p src/workers && echo n > src/workers/new.py \
    && echo e > extra.py && git add -A && git commit -qm pre \
    && git mv extra.py docs/moved.md && echo r > rootnew.py \
    && git add -A && git commit -qm changes ) >/dev/null 2>&1
  DOUT=$(cd "$RD" && python3 "$KIT/../drift.py" --config .speccraft/kbforge.yaml --queue 2>&1)
  printf '%s' "$DOUT" | grep -q 'ANCHOR SCOPE drift' && ok || no "drift: anchor scope section present"
  printf '%s' "$DOUT" | grep -q '02-scope.md  (anchor: src/) \[normative\]' && ok || no "drift: normative scope finding reported"
  printf '%s' "$DOUT" | grep -q 'src/workers/new.py' && ok || no "drift: new nested file caught"
  printf '%s' "$DOUT" | grep -q 'docs/moved.md' && ok || no "drift: rename into scope caught (--no-renames)"
  printf '%s' "$DOUT" | grep -q 'rootnew.py' && no "drift: unrelated new file wrongly reported" || ok
  SIGOUT=$(cd "$RD" && python3 -c "
import sys; sys.path.insert(0, '$KIT/../../..')
from speccraft.forge import signals
print('\n'.join(signals.read_lines('.speccraft', 'drift')))
")
  printf '%s' "$SIGOUT" | grep -q 'anchor scope drift: `kb/normative/02-scope.md`' && ok || no "drift: normative scope finding signaled"
  printf '%s' "$SIGOUT" | grep -q 'anchor scope drift: `kb/inferred/09-scope.md`' && no "drift: inferred scope finding wrongly signaled" || ok
  grep -q 'anchor scope drift' "$RD/.speccraft/QUEUE.md" 2>/dev/null && no "drift: mechanical finding leaked into QUEUE.md" || ok
  JT=$(cd "$RD" && python3 "$KIT/../drift.py" --config .speccraft/kbforge.yaml --judge-targets)
  printf '%s\n' "$JT" | grep -q "^kb/normative/02-scope.md	src/	src/workers/new.py$" && ok || no "drift: judge-targets line exact"
  printf '%s' "$JT" | grep -q 'inferred' && no "drift: judge-targets leaked non-normative" || ok
  rm -rf "$RD"
fi

# ---------- dep-diff: version drift vs gotcha cards ----------
if run_section depdiff; then
  KIT="$(cd "$HERE/.." && pwd)"
  RP=$(mktemp -d); RP=$(cd "$RP" && pwd -P)
  ( cd "$RP" && git init -q && mkdir -p .speccraft/kb/derived .speccraft/kb/inferred \
    && echo "repo: ." > .speccraft/kbforge.yaml \
    && printf 'stripe==5.0.0\nclick==8.1.0\n' > requirements.txt \
    && printf -- "---\nname: dp\nstatus: observed\nanchors: [topic:dependencies]\n---\n# Cards\n\n## Stripe idempotency on \`stripe\` calls\nprose click here\n" \
       > .speccraft/kb/inferred/09-dependency-practices.md \
    && echo x > app.py && git add -A && git commit -qm base ) >/dev/null 2>&1
  DPIN=$(cd "$RP" && git rev-parse --short HEAD)
  printf -- "---\nname: inventory\nprovenance: derived\nsource_commit: %s\n---\n" "$DPIN" > "$RP/.speccraft/kb/derived/inventory.md"
  printf -- "---\nname: deps\nprovenance: derived\n---\n# inv\n\n## Python (runtime) (2)\n\n- \`click\` @ **8.1.0**\n- \`stripe\` @ **5.0.0** ⚠risk\n" > "$RP/.speccraft/kb/derived/dependencies.md"
  ( cd "$RP" && echo y >> app.py && git add -A && git commit -qm noman ) >/dev/null 2>&1
  DOUT=$(cd "$RP" && python3 "$KIT/../dep-diff.py" --config .speccraft/kbforge.yaml --queue 2>&1)
  [ -z "$DOUT" ] && ok || no "dep-diff: silent early exit when no manifest changed"
  ( cd "$RP" && printf 'stripe==6.0.0\nclick==8.2.0\n' > requirements.txt \
    && git add -A && git commit -qm bump ) >/dev/null 2>&1
  DOUT=$(cd "$RP" && python3 "$KIT/../dep-diff.py" --config .speccraft/kbforge.yaml --queue 2>&1)
  printf '%s' "$DOUT" | grep -q 'stripe  5.0.0 → 6.0.0' && ok || no "dep-diff: changed version detected"
  printf '%s' "$DOUT" | grep -q 'mentions `stripe`' && ok || no "dep-diff: backticked card match"
  DEPSIG=$(cd "$RP" && python3 -c "
import sys; sys.path.insert(0, '$KIT/../../..')
from speccraft.forge import signals
print('\n'.join(signals.read_lines('.speccraft', 'deps')))
")
  printf '%s' "$DEPSIG" | grep -q 'dep-diff: `stripe` 5.0.0 → 6.0.0' && ok || no "dep-diff: card-matched change signaled"
  printf '%s' "$DEPSIG" | grep -q 'dep-diff: `click`' && no "dep-diff: routine bump wrongly signaled" || ok
  grep -q 'dep-diff:' "$RP/.speccraft/QUEUE.md" 2>/dev/null && no "dep-diff: mechanical finding leaked into QUEUE.md" || ok
  rm -rf "$RP"
fi

# ---------- deps0 advisory refresh: diff scan, queue only NEW CVEs ----------
if run_section depsadv; then
  KIT="$(cd "$HERE/.." && pwd)"
  RA=$(mktemp -d); RA=$(cd "$RA" && pwd -P)
  ( cd "$RA" && git init -q && mkdir -p .speccraft/kb/derived \
    && echo "repo: ." > .speccraft/kbforge.yaml \
    && printf 'requests==2.0.0\n' > requirements.txt \
    && git add -A && git commit -qm base ) >/dev/null 2>&1
  APIN=$(cd "$RA" && git rev-parse --short HEAD)
  printf -- "---\nname: inventory\nprovenance: derived\nsource_commit: %s\n---\n" "$APIN" \
    > "$RA/.speccraft/kb/derived/inventory.md"
  # baseline already knows VULN-1
  printf '{"last_scan":"2000-01-01","counts":{"python":1,"js":null},"ids":{"python":{"py:requests:VULN-1":"old"},"js":{}}}' \
    > "$RA/.speccraft/kb/derived/advisories-meta.json"
  # injected scan: VULN-1 (known) + VULN-2 (new)
  printf '{"dependencies":[{"name":"requests","version":"2.0.0","vulns":[{"id":"VULN-1","fix_versions":["2.1.0"]},{"id":"VULN-2","fix_versions":["2.2.0"]}]}]}' \
    > "$RA/newscan.json"
  AOUT=$(cd "$RA" && python3 "$KIT/../deps0.py" --config .speccraft/kbforge.yaml \
           --advisories-only --queue --advisory-input python="$RA/newscan.json" 2>&1)
  ADVSIG(){ cd "$RA" && python3 -c "
import sys; sys.path.insert(0, '$KIT/../../..')
from speccraft.forge import signals
print('\n'.join(signals.read_lines('.speccraft', 'advisories')))
"; }
  ASIG1=$(ADVSIG)
  printf '%s' "$ASIG1" | grep -q 'deps0-advisory: new python advisory.*VULN-2' && ok || no "deps0-adv: new CVE signaled"
  printf '%s' "$ASIG1" | grep -q 'VULN-1' && no "deps0-adv: known CVE wrongly re-signaled" || ok
  grep -q 'VULN' "$RA/.speccraft/QUEUE.md" 2>/dev/null && no "deps0-adv: mechanical finding leaked into QUEUE.md" || ok
  [ -f "$RA/.speccraft/kb/derived/dependencies.md" ] && no "deps0-adv: advisories-only wrongly rewrote inventory" || ok
  # second identical scan must be silent (baseline now holds both IDs)
  AOUT=$(cd "$RA" && python3 "$KIT/../deps0.py" --config .speccraft/kbforge.yaml \
           --advisories-only --queue --advisory-input python="$RA/newscan.json" 2>&1)
  ASIG2=$(ADVSIG)
  N2=$(printf '%s\n' "$ASIG2" | grep -c 'VULN-2')
  [ "$N2" -eq 1 ] && ok || no "deps0-adv: unchanged scan re-signaled (got $N2 VULN-2 lines)"
  rm -rf "$RA"
fi

# ---------- stale commit guard (two-tier) ----------
if run_section staleguard; then
  KIT="$(cd "$HERE/.." && pwd)"
  RS=$(mktemp -d); RS=$(cd "$RS" && pwd -P)
  ( cd "$RS" && git init -q && mkdir -p .speccraft/kb/normative .speccraft/kb/inferred src lib other \
    && echo "repo: ." > .speccraft/kbforge.yaml \
    && printf -- "---\nname: pend\nstatus: pending-ratification\nanchors: [src/]\n---\n# P-1\n" \
       > .speccraft/kb/normative/03-pending.md \
    && printf -- "## Adjudication — 2026-07-01\n\n- [ ] verify \`lib/util.py\` retry behavior\n- [ ] pathless pricing question\n" \
       > .speccraft/QUEUE.md \
    && echo a > base.py && git add -A && git commit -qm init ) >/dev/null 2>&1
  PC="$KIT/pre-commit"
  ( cd "$RS" && echo n > src/gov.py && git add src/gov.py \
    && KBFORGE_HOME="$KIT/.." sh "$PC" ) >/dev/null 2>&1
  [ $? -eq 1 ] && ok || no "staleguard: blocks staged file under pending-fact anchor"
  ( cd "$RS" && git reset -q && echo n > lib/util.py && git add lib/util.py \
    && KBFORGE_HOME="$KIT/.." sh "$PC" ) >/dev/null 2>&1
  [ $? -eq 1 ] && ok || no "staleguard: blocks staged file named by queue item path"
  WOUT=$( cd "$RS" && git reset -q && echo n > other/free.py && git add other/free.py \
    && KBFORGE_HOME="$KIT/.." sh "$PC" 2>&1 ); WRC=$?
  [ $WRC -eq 0 ] && ok || no "staleguard: warning tier does not block"
  printf '%s' "$WOUT" | grep -q '2 open QUEUE.md item(s) unrelated' && ok || no "staleguard: warning names open count"
  ( cd "$RS" && git reset -q && echo n2 > src/gov2.py && git add src/gov2.py \
    && KB_ACK_STALE=1 KBFORGE_HOME="$KIT/.." sh "$PC" ) >/dev/null 2>&1
  [ $? -eq 0 ] && ok || no "staleguard: KB_ACK_STALE bypasses"
  grep -q '"event":"stale_ack"' "$RS/.speccraft/evals/telemetry.jsonl" && ok || no "staleguard: stale_ack telemetry recorded"
  grep -q '"event":"stale_guard_block"' "$RS/.speccraft/evals/telemetry.jsonl" && ok || no "staleguard: stale_guard_block telemetry recorded"
  grep -q '"event":"stale_warn"' "$RS/.speccraft/evals/telemetry.jsonl" && ok || no "staleguard: stale_warn telemetry recorded"
  rm -rf "$RS"
fi

# ---------- trust decay: demote + archive ----------
if run_section decay; then
  KIT="$(cd "$HERE/.." && pwd)"
  RT=$(mktemp -d); RT=$(cd "$RT" && pwd -P)
  ( cd "$RT" && git init -q && mkdir -p .speccraft/kb/normative .speccraft/kb/inferred .speccraft/kb/derived src \
    && echo "repo: ." > .speccraft/kbforge.yaml \
    && printf 'a\nb\n' > src/gone.py && printf 'x\ny\n' > src/ed.py \
    && printf -- "---\nname: i1\nstatus: observed\nanchors: [src/]\n---\nsee src/gone.py:1-2\n" > .speccraft/kb/inferred/05-a.md \
    && printf -- "---\nname: n1\nstatus: ratified\nanchors: [src/]\n---\ncites src/ed.py:1-2\n" > .speccraft/kb/normative/01-i.md \
    && printf -- "---\nname: n2\nstatus: ratified\nanchors: [src/]\n---\ncites src/gone.py:1\n" > .speccraft/kb/normative/02-i.md \
    && printf -- "## Adjudication — 2026-06-01\n\n- [ ] divergence: keep me\n" > .speccraft/QUEUE.md \
    && git add -A && git commit -qm base ) >/dev/null 2>&1
  TPIN=$(cd "$RT" && git rev-parse --short HEAD)
  printf -- "---\nname: inventory\nprovenance: derived\nsource_commit: %s\n---\n" "$TPIN" > "$RT/.speccraft/kb/derived/inventory.md"
  ( cd "$RT" && git rm -q src/gone.py && printf 'X\nY\n' > src/ed.py \
    && git add -A && git commit -qm ch ) >/dev/null 2>&1
  ( cd "$RT" && python3 "$KIT/../drift.py" --config .speccraft/kbforge.yaml --demote ) >/dev/null 2>&1
  grep -q 'status: challenged' "$RT/.speccraft/kb/inferred/05-a.md" && ok || no "decay: inferred fact demoted on hard staleness"
  grep -q 'status: ratified' "$RT/.speccraft/kb/normative/01-i.md" && ok || no "decay: ratified fact with lines-changed NOT demoted"
  grep -q 'status: challenged' "$RT/.speccraft/kb/normative/02-i.md" && ok || no "decay: ratified fact citing DELETED file demoted"
  grep -q 'AUTO-DEMOTE' "$RT/.speccraft/ledger/trust-decay.md" && ok || no "decay: ledger entry written"
  grep -q 'status_note: auto-demoted' "$RT/.speccraft/kb/inferred/05-a.md" && ok || no "decay: status_note carries evidence"
  # decay.py: trims QUEUE-ARCHIVE.md `- resolved <date>:` lines older than
  # queue_archive_days; never touches QUEUE.md (the human adjudication lane).
  echo "queue_archive_days: 30" >> "$RT/.speccraft/kbforge.yaml"
  BEFORE_QUEUE=$(cat "$RT/.speccraft/QUEUE.md")
  TODAY="$(date -u +%Y-%m-%d)"
  printf -- '- resolved 2000-01-01: kb/x cites y.py:1\n- resolved %s: kb/x cites z.py:2\n' "$TODAY" \
    > "$RT/.speccraft/QUEUE-ARCHIVE.md"
  ( cd "$RT" && python3 "$KIT/../decay.py" --config .speccraft/kbforge.yaml ) >/dev/null 2>&1
  AFTER_QUEUE=$(cat "$RT/.speccraft/QUEUE.md")
  grep -q 'divergence: keep me' "$RT/.speccraft/QUEUE.md" && ok || no "decay: adjudication item never archived"
  [ "$BEFORE_QUEUE" = "$AFTER_QUEUE" ] && ok || no "decay: decay.py never touches QUEUE.md"
  grep -q '2000-01-01' "$RT/.speccraft/QUEUE-ARCHIVE.md" && no "decay: archive trims entries older than queue_archive_days" || ok
  grep -q -- "- resolved $TODAY:" "$RT/.speccraft/QUEUE-ARCHIVE.md" && ok || no "decay: archive keeps recent entries"
  ( cd "$RT" && KBFORGE_HOME="$KIT/.." "$KIT/hooks/kb-briefing.sh" </dev/null | grep -q 'Trust: .* challenged (2 auto)' ) && ok || no "decay: briefing trust line counts auto-demotions"
  rm -rf "$RT"
fi

# ---------- init migration: superdev/ -> .speccraft/ ----------
if run_section migrate; then
  KIT="$(cd "$HERE/.." && pwd)"
  RM=$(mktemp -d); RM=$(cd "$RM" && pwd -P)
  ( cd "$RM" && git init -q && mkdir -p superdev/kb/normative src \
    && echo "product: old" > superdev/kbforge.yaml \
    && printf -- "---\nname: inv\nstatus: ratified\nanchors: [src/]\n---\n# INV-1\n" > superdev/kb/normative/01-inv.md \
    && echo x > src/app.py && git add -A && git commit -qm oldkb ) >/dev/null 2>&1
  KBFORGE_HOME="$KIT/.." bash "$KIT/../kbforge-init.sh" "$RM" >/dev/null 2>&1
  [ -f "$RM/.speccraft/kb/normative/01-inv.md" ] && ok || no "migrate: ratified fact survives superdev -> .speccraft rename"
  [ ! -d "$RM/superdev" ] && ok || no "migrate: old superdev/ dir gone after rename"
  mkdir -p "$RM/superdev" && echo "product: old2" > "$RM/superdev/kbforge.yaml"
  MOUT=$(KBFORGE_HOME="$KIT/.." bash "$KIT/../kbforge-init.sh" "$RM" 2>&1)
  printf '%s' "$MOUT" | grep -q 'WARNING: both superdev/' && ok || no "migrate: warns when both dirs exist"
  [ -f "$RM/superdev/kbforge.yaml" ] && ok || no "migrate: never guesses when both exist"
  rm -rf "$RM"
fi

if run_section audit; then
  RC=$(mk_repo "$HERE/fixtures/kb-clean")
  OUT=$("$HERE/kb-audit.sh" --root "$RC" --kb "$RC/.speccraft")
  assert_contains "$OUT" 'AUDIT: 0 issues' "audit: clean fixture passes"
  ls "$RC/.speccraft/evals/reports/" | grep -q audit.md && ok || no "audit: report written"
  RD=$(mk_repo "$HERE/fixtures/kb-defects")
  OUT=$("$HERE/kb-audit.sh" --root "$RD" --kb "$RD/.speccraft")
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
  OUT=$(PATH="$HERE/fixtures/bin:$PATH" "$HERE/kb-audit.sh" --root "$RC" --kb "$RC/.speccraft" --judge)
  R=$(cat "$RC"/.speccraft/evals/reports/*-audit.md)
  assert_contains "$R" 'SUPPORTED' "judge: verdicts in report"
  assert_contains "$R" 'precision 0.33' "judge: precision computed (1/3)"
  Q=$(cat "$RC/.speccraft/QUEUE.md")
  assert_contains "$Q" 'CONTRADICTED.*INV-2' "judge: contradiction queued"
  assert_contains "$Q" 'POSSIBLY_STALE.*INV-1' "judge: stale queued"
  assert_not_contains "$Q" 'retail users' "judge: SUPPORTED not queued"
  grep -q 'last audit: .*precision 0.33' "$RC/.speccraft/evals/health.md" \
    && ok || no "judge: health line upserted"
  # elicited intent files are never sampled as claims (only INVs get the compliance pass)
  assert_not_contains "$R" 'Identity: a demo product' "judge: elicited claims not judged"
  # no claude on PATH -> semantic SKIPPED, still exit 0
  RC2=$(mk_repo "$HERE/fixtures/kb-clean")
  OUT2=$(PATH=/usr/bin:/bin "$HERE/kb-audit.sh" --root "$RC2" --kb "$RC2/.speccraft" --judge)
  grep -q 'SKIPPED' "$RC2"/.speccraft/evals/reports/*-audit.md && ok || no "judge: skips without claude"
  rm -rf "$RC" "$RC2"
fi

# ---------- section: prove (pull-based proof engine) ----------
if run_section prove; then
  RP=$(mk_repo "$HERE/fixtures/kb-clean"); RP=$(cd "$RP" && pwd -P)
  chmod +x "$HERE/fixtures/bin/claude"
  MP="$HERE/fixtures/bin"
  # INV-1 -> POSSIBLY_STALE (exit 10)
  O1=$(PATH="$MP:$PATH" "$HERE/prove.sh" "$RP" INV-1); R1=$?
  [ "$R1" -eq 10 ] && ok || no "prove: INV-1 exit 10 (got $R1)"
  assert_contains "$O1" '^VERDICT: POSSIBLY_STALE$' "prove: INV-1 verdict POSSIBLY_STALE"
  # INV-2 -> CONTRADICTED (exit 20)
  O2=$(PATH="$MP:$PATH" "$HERE/prove.sh" "$RP" INV-2); R2=$?
  [ "$R2" -eq 20 ] && ok || no "prove: INV-2 exit 20 (got $R2)"
  assert_contains "$O2" '^VERDICT: CONTRADICTED$' "prove: INV-2 verdict CONTRADICTED"
  # substring resolution -> SUPPORTED (exit 0)
  O3=$(PATH="$MP:$PATH" "$HERE/prove.sh" "$RP" "retail users"); R3=$?
  [ "$R3" -eq 0 ] && ok || no "prove: 'retail users' exit 0 (got $R3)"
  assert_contains "$O3" '^VERDICT: SUPPORTED$' "prove: 'retail users' verdict SUPPORTED"
  assert_contains "$O3" '^CLAIM: The app targets retail users' "prove: substring resolved to the right claim"
  # unresolvable substring -> resolution error (exit 2)
  PATH="$MP:$PATH" "$HERE/prove.sh" "$RP" "zzz-nonexistent" >/dev/null 2>&1; R4=$?
  [ "$R4" -eq 2 ] && ok || no "prove: unresolvable fact exit 2 (got $R4)"
  # CODEHASH present and deterministic across two runs of the same fact
  H1=$(printf '%s\n' "$O1" | grep '^CODEHASH:')
  [ -n "$H1" ] && ok || no "prove: CODEHASH line present"
  O1b=$(PATH="$MP:$PATH" "$HERE/prove.sh" "$RP" INV-1)
  H1b=$(printf '%s\n' "$O1b" | grep '^CODEHASH:')
  [ "$H1" = "$H1b" ] && ok || no "prove: CODEHASH deterministic across runs ('$H1' vs '$H1b')"
  # engine renders no artifacts and writes no QUEUE — pure measurement
  [ ! -d "$RP/.speccraft/proofs" ] && ok || no "prove: engine writes no proofs/ (skill's job)"
  rm -rf "$RP"
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

# ---------- section: two-lane queue suite (SIGNALS.md / QUEUE.md / QUEUE-ARCHIVE.md) ----------
if run_section queuesplit; then
  echo "== two-lane queue suite =="
  QOUT=$(bash "$HERE/test-queue-split.sh" 2>&1); QRC=$?
  printf '%s\n' "$QOUT"
  QP=$(printf '%s' "$QOUT" | grep -Eo '[0-9]+ passed' | tail -1 | grep -Eo '[0-9]+')
  QF=$(printf '%s' "$QOUT" | grep -Eo '[0-9]+ failed' | tail -1 | grep -Eo '[0-9]+')
  PASS=$((PASS + ${QP:-0})); FAIL=$((FAIL + ${QF:-0}))
  if [ "$QRC" -ne 0 ] && [ "${QF:-0}" -eq 0 ]; then
    # suite failed but gave no parseable failure count — still must fail self-test
    no "queuesplit: test-queue-split.sh exited nonzero ($QRC)"
  fi
fi

# ---------- section: queue-teeth (high-debt gate enforcement) ----------
if run_section queueteeth; then
  echo "== queue-teeth suite =="
  QTOUT=$(bash "$HERE/test-queue-teeth.sh" 2>&1); QTRC=$?
  printf '%s\n' "$QTOUT"
  QTP=$(printf '%s' "$QTOUT" | grep -Eo '[0-9]+ passed' | tail -1 | grep -Eo '[0-9]+')
  QTF=$(printf '%s' "$QTOUT" | grep -Eo '[0-9]+ failed' | tail -1 | grep -Eo '[0-9]+')
  PASS=$((PASS + ${QTP:-0})); FAIL=$((FAIL + ${QTF:-0}))
  if [ "$QTRC" -ne 0 ] && [ "${QTF:-0}" -eq 0 ]; then
    # suite failed but gave no parseable failure count — still must fail self-test
    no "queueteeth: test-queue-teeth.sh exited nonzero ($QTRC)"
  fi
fi

echo "self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
