#!/usr/bin/env bash
# Phase-0 two-lane queue assertions. Run standalone or from self-test.sh.
set -euo pipefail
FORGE="$(cd "$(dirname "$0")/../.." && pwd)"   # .../speccraft/forge
PYME() { python3 -c "import sys; sys.path.insert(0, '$FORGE/../..'); $1"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ok: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "== signals.py region round-trip =="
PYME "
from speccraft.forge import signals
kb = '$TMP'
signals.write_region(kb, 'drift', '## drift\n- [ ] a\n- [ ] b')
assert signals.read_lines(kb, 'drift') == ['- [ ] a', '- [ ] b'], signals.read_lines(kb,'drift')
# overwrite is idempotent + replaces, never appends
signals.write_region(kb, 'drift', '## drift\n- [ ] a')
assert signals.read_lines(kb, 'drift') == ['- [ ] a']
# a second region is untouched by writing the first
signals.write_region(kb, 'deps', '- [ ] dep1')
signals.write_region(kb, 'drift', '## drift\n- [ ] a')
assert signals.read_lines(kb, 'deps') == ['- [ ] dep1']
# header reflects total open count
import os
txt = open(os.path.join(kb, 'SIGNALS.md'), encoding='utf-8').read()
assert txt.splitlines()[0] == '# SIGNALS — 2 open mechanical signals', txt.splitlines()[0]
print('REGION_OK')
" | grep -q REGION_OK && ok "region round-trip" || bad "region round-trip"

echo "== archive_resolved appends =="
PYME "
from speccraft.forge import signals
import os
kb = '$TMP'
signals.archive_resolved(kb, ['- resolved 2026-08-01: kb/x cites y.py:1'])
signals.archive_resolved(kb, ['- resolved 2026-08-01: kb/x cites z.py:2'])
lines = open(os.path.join(kb,'QUEUE-ARCHIVE.md'), encoding='utf-8').read().splitlines()
assert lines == ['- resolved 2026-08-01: kb/x cites y.py:1', '- resolved 2026-08-01: kb/x cites z.py:2'], lines
print('ARCHIVE_OK')
" | grep -q ARCHIVE_OK && ok "archive appends" || bad "archive appends"

echo "== fence-collision robustness =="
PYME "
from speccraft.forge import signals
import os
kb = '$TMP'
os.remove(os.path.join(kb,'SIGNALS.md')) if os.path.exists(os.path.join(kb,'SIGNALS.md')) else None
# drift body literally contains the deps OPENING fence marker text
signals.write_region(kb, 'drift', '## drift\n- [ ] mentions <!-- signals:deps --> in text')
signals.write_region(kb, 'deps', '- [ ] realdep')
# both regions must still be independently readable and correct
assert signals.read_lines(kb, 'deps') == ['- [ ] realdep'], signals.read_lines(kb,'deps')
d = signals.read_lines(kb, 'drift')
assert d == ['- [ ] mentions <!-- signals:deps --> in text'], d
print('COLLISION_OK')
" | grep -q COLLISION_OK && ok "fence-collision handled" || bad "fence-collision handled"

echo "== region order-independence =="
PYME "
from speccraft.forge import signals
import os, re
kb = '$TMP'
p = os.path.join(kb,'SIGNALS.md')
if os.path.exists(p): os.remove(p)
signals.write_region(kb, 'deps', '- [ ] keepdep')
# remove the drift fence block entirely, simulating a file missing that region
txt = open(p, encoding='utf-8').read()
txt = re.sub(r'(?m)^<!-- signals:drift -->\n?<!-- /signals:drift -->\n?', '', txt)
open(p,'w',encoding='utf-8').write(txt)
# writing drift now appends it AFTER deps (out of canonical order)
signals.write_region(kb, 'drift', '- [ ] newdrift')
# deps must still be readable despite drift now being physically last
assert signals.read_lines(kb, 'deps') == ['- [ ] keepdep'], signals.read_lines(kb,'deps')
assert signals.read_lines(kb, 'drift') == ['- [ ] newdrift'], signals.read_lines(kb,'drift')
print('ORDER_OK')
" | grep -q ORDER_OK && ok "region order-independence" || bad "region order-independence"

echo "== drift.py projection (idempotency / lane isolation / no self-citation) =="
CODE="$TMP/code"; KB="$TMP/kb"
mkdir -p "$CODE" "$KB/kb/normative" "$KB/kb/derived"
( cd "$CODE" && git init -q && git config user.email t@t && git config user.name t \
  && mkdir -p src && printf 'a\nb\nc\nd\n' > src/svc.py && git add . && git commit -qm init )
PIN="$( cd "$CODE" && git rev-parse --short HEAD )"
# a KB fact citing src/svc.py line 2
printf '# facts\n- svc does X (`src/svc.py:2`)\n' > "$KB/kb/normative/00.md"
printf 'source_commit: %s\n' "$PIN" > "$KB/kb/derived/inventory.md"
printf 'repo: %s\n' "$CODE" > "$KB/kbforge.yaml"
# change src/svc.py so line 2's neighborhood shifts -> a drift finding
( cd "$CODE" && printf 'a\nCHANGED\nb\nc\nd\n' > src/svc.py && git commit -qam change )

run_drift() { python3 "$FORGE/drift.py" --config "$KB/kbforge.yaml" --queue >/dev/null 2>&1 || true; }
run_drift
FIRST="$(cat "$KB/SIGNALS.md")"
run_drift
SECOND="$(cat "$KB/SIGNALS.md")"

[ "$FIRST" = "$SECOND" ] && ok "idempotent (byte-identical on rerun)" || bad "idempotent"
[ ! -s "$KB/QUEUE.md" ] || ! grep -q -- '- \[ \]' "$KB/QUEUE.md" 2>/dev/null \
  && ok "lane isolation (no mechanical lines in QUEUE.md)" || bad "lane isolation"
! grep -Eq 'cites .*(QUEUE|SIGNALS|QUEUE-ARCHIVE)\.md' "$KB/SIGNALS.md" \
  && ! grep -q 'SIGNALS.md' "$KB/SIGNALS.md" \
  && ok "no self-citation" || bad "no self-citation"
grep -q 'signals:drift' "$KB/SIGNALS.md" && ok "drift region present" || bad "drift region present"
grep -qE '^- \[ \]' "$KB/SIGNALS.md" && ok 'drift region has real findings (non-vacuous)' || bad 'drift region has real findings (non-vacuous)'

echo "== drift.py re-projects on ratify (pin advances to head): resolved findings clear + archive =="
# simulate speccraft-ratify: advance the pin to HEAD (the normal post-ratify state)
printf 'source_commit: %s\n' "$( cd "$CODE" && git rev-parse --short HEAD )" > "$KB/kb/derived/inventory.md"
run_drift
! grep -qE '^- \[ \]' "$KB/SIGNALS.md" \
  && ok "drift region cleared once pin == head (re-projected empty)" \
  || bad "drift region cleared once pin == head (re-projected empty)"
grep -q -- '- resolved ' "$KB/QUEUE-ARCHIVE.md" 2>/dev/null \
  && ok "prior drift finding archived to QUEUE-ARCHIVE.md" \
  || bad "prior drift finding archived to QUEUE-ARCHIVE.md"

echo "== drift idempotency with multiple findings =="
MKB="$TMP/mkb"; mkdir -p "$MKB/kb/normative" "$MKB/kb/derived"
printf '# facts\n- svc X (`src/svc.py:2`)\n- svc Y (`src/svc.py:4`)\n- more (`src/svc.py:1`)\n' > "$MKB/kb/normative/00.md"
printf 'source_commit: %s\n' "$PIN" > "$MKB/kb/derived/inventory.md"
printf 'repo: %s\n' "$CODE" > "$MKB/kbforge.yaml"
python3 "$FORGE/drift.py" --config "$MKB/kbforge.yaml" --queue >/dev/null 2>&1 || true
A="$(cat "$MKB/SIGNALS.md")"
python3 "$FORGE/drift.py" --config "$MKB/kbforge.yaml" --queue >/dev/null 2>&1 || true
B="$(cat "$MKB/SIGNALS.md")"
[ "$A" = "$B" ] && ok 'multi-finding idempotent' || bad 'multi-finding idempotent'
[ "$(grep -cE '^- \[ \]' "$MKB/SIGNALS.md")" -ge 2 ] && ok 'multi-finding produced >=2 real findings' || bad 'multi-finding produced >=2 real findings'
# and no spurious resolved churn on the identical second run
[ ! -f "$MKB/QUEUE-ARCHIVE.md" ] || [ ! -s "$MKB/QUEUE-ARCHIVE.md" ] && ok 'no spurious archive churn' || bad 'no spurious archive churn'

echo "== dep-diff.py projection (SIGNALS.md deps region, not QUEUE.md) =="
DCODE="$TMP/dcode"; DKB="$TMP/dkb"
mkdir -p "$DCODE" "$DKB/kb/derived"
( cd "$DCODE" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'requests==2.28.0\n' > requirements.txt && git add . && git commit -qm init )
DPIN="$( cd "$DCODE" && git rev-parse --short HEAD )"
printf 'source_commit: %s\n' "$DPIN" > "$DKB/kb/derived/inventory.md"
printf 'repo: %s\n' "$DCODE" > "$DKB/kbforge.yaml"
# pinned dependency table as deps0.py would have written it
printf '## Python (runtime) (1)\n- `requests` @ **2.28.0**\n' > "$DKB/kb/derived/dependencies.md"
# bump the pinned version at HEAD — requests is RISK-tagged, so this is a real,
# queue-worthy finding even with no gotcha card mentioning it
( cd "$DCODE" && printf 'requests==2.31.0\n' > requirements.txt && git commit -qam bump )

python3 "$FORGE/dep-diff.py" --config "$DKB/kbforge.yaml" --queue >/dev/null 2>&1 || true
DFIRST="$(cat "$DKB/SIGNALS.md" 2>/dev/null || true)"
python3 "$FORGE/dep-diff.py" --config "$DKB/kbforge.yaml" --queue >/dev/null 2>&1 || true
DSECOND="$(cat "$DKB/SIGNALS.md" 2>/dev/null || true)"

[ -f "$DKB/SIGNALS.md" ] && ok "dep-diff wrote SIGNALS.md" || bad "dep-diff wrote SIGNALS.md"
[ ! -f "$DKB/QUEUE.md" ] || ! grep -q -- '- \[ \]' "$DKB/QUEUE.md" 2>/dev/null \
  && ok "dep-diff wrote no QUEUE.md lines" || bad "dep-diff wrote no QUEUE.md lines"
grep -q 'signals:deps' "$DKB/SIGNALS.md" 2>/dev/null && ok "deps region present" || bad "deps region present"
PYME "
from speccraft.forge import signals
dkb = '$DKB'
lines = signals.read_lines(dkb, 'deps')
assert any(l.startswith('- [ ] dep-diff:') for l in lines), lines
assert any('requests' in l for l in lines), lines
print('DEPS_NONVACUOUS_OK')
" | grep -q DEPS_NONVACUOUS_OK && ok "deps region has a real, non-vacuous finding" || bad "deps region has a real, non-vacuous finding"
[ "$DFIRST" = "$DSECOND" ] && ok "dep-diff idempotent (byte-identical on rerun)" || bad "dep-diff idempotent"
PYME "
from speccraft.forge import signals
dkb = '$DKB'
assert signals.read_lines(dkb, 'drift') == [], signals.read_lines(dkb,'drift')
print('DEPS_ISOLATION_OK')
" | grep -q DEPS_ISOLATION_OK && ok "dep-diff writes deps without disturbing drift" || bad "dep-diff writes deps without disturbing drift"

echo "== dep-diff.py self-clears deps region once version drift resolves (no manifest movement vs pin) =="
# advance the pin to HEAD so there is no more manifest diff — the previously
# written deps finding must vanish, not linger forever (decay.py no longer
# cleans SIGNALS.md, so dep-diff itself must self-clear on re-run)
printf 'source_commit: %s\n' "$( cd "$DCODE" && git rev-parse --short HEAD )" > "$DKB/kb/derived/inventory.md"
python3 "$FORGE/dep-diff.py" --config "$DKB/kbforge.yaml" --queue >/dev/null 2>&1 || true
PYME "
from speccraft.forge import signals
dkb = '$DKB'
assert signals.read_lines(dkb, 'deps') == [], signals.read_lines(dkb,'deps')
print('DEPS_SELFCLEAR_OK')
" | grep -q DEPS_SELFCLEAR_OK && ok "dep-diff self-clears deps region once version drift resolves" || bad "dep-diff self-clears deps region once version drift resolves"

echo "== deps0 advisories go to advisories region, additive =="
PYME "
from speccraft.forge import signals
kb='$TMP'
# simulate two advisory scans appending distinct CVEs
signals.write_region(kb, 'advisories', '\n'.join(signals.read_lines(kb,'advisories') + ['- [ ] advisory: CVE-2024-1 in jose']))
signals.write_region(kb, 'advisories', '\n'.join(signals.read_lines(kb,'advisories') + ['- [ ] advisory: CVE-2024-2 in urllib3']))
got = signals.read_lines(kb, 'advisories')
assert got == ['- [ ] advisory: CVE-2024-1 in jose', '- [ ] advisory: CVE-2024-2 in urllib3'], got
print('ADV_OK')
" | grep -q ADV_OK && ok "advisories additive in region" || bad "advisories additive"

echo "== deps0.py wires its real advisory scan path to SIGNALS.md advisories region (additive across runs) =="
ACODE="$TMP/acode"; AKB="$TMP/akb"
mkdir -p "$ACODE" "$AKB/kb/derived"
( cd "$ACODE" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'jose==1.0.0\n' > requirements.txt && git add . && git commit -qm init )
APIN="$( cd "$ACODE" && git rev-parse --short HEAD )"
printf 'source_commit: %s\n' "$APIN" > "$AKB/kb/derived/inventory.md"
printf 'repo: %s\n' "$ACODE" > "$AKB/kbforge.yaml"

# pre-computed pip-audit JSON (--advisory-input bypasses the network scanner,
# same mechanism the self-test / CI use): scan 1 finds CVE-2024-1 only, scan 2
# finds CVE-2024-1 (already-baselined) PLUS a genuinely new CVE-2024-2
AJ1="$TMP/adv1.json"; AJ2="$TMP/adv2.json"
printf '%s' '{"dependencies": [{"name": "jose", "version": "1.0.0", "vulns": [{"id": "CVE-2024-1", "fix_versions": ["1.0.1"]}]}]}' > "$AJ1"
printf '%s' '{"dependencies": [{"name": "jose", "version": "1.0.0", "vulns": [{"id": "CVE-2024-1", "fix_versions": ["1.0.1"]}]}, {"name": "urllib3", "version": "2.0.0", "vulns": [{"id": "CVE-2024-2", "fix_versions": ["2.0.1"]}]}]}' > "$AJ2"

python3 "$FORGE/deps0.py" --config "$AKB/kbforge.yaml" --advisories-only --queue --advisory-input python="$AJ1" >/dev/null 2>&1 || true
python3 "$FORGE/deps0.py" --config "$AKB/kbforge.yaml" --advisories-only --queue --advisory-input python="$AJ2" >/dev/null 2>&1 || true

[ ! -f "$AKB/QUEUE.md" ] || ! grep -q -- '- \[ \]' "$AKB/QUEUE.md" 2>/dev/null \
  && ok "deps0 advisories wrote no QUEUE.md lines (lane isolation)" || bad "deps0 advisories lane isolation"
grep -q 'signals:advisories' "$AKB/SIGNALS.md" 2>/dev/null && ok "deps0 advisories region present" || bad "deps0 advisories region present"
PYME "
from speccraft.forge import signals
akb = '$AKB'
lines = signals.read_lines(akb, 'advisories')
assert any(l.startswith('- [ ] deps0-advisory:') for l in lines), lines
assert any('CVE-2024-1' in l for l in lines), lines
assert any('CVE-2024-2' in l for l in lines), lines
assert len(lines) == 2, lines
print('DEPS0_ADV_OK')
" | grep -q DEPS0_ADV_OK && ok "deps0 real advisory path accumulates additively across two scans" || bad "deps0 real advisory path accumulates additively across two scans"

echo "== decay.py trims QUEUE-ARCHIVE.md by age, never touches QUEUE.md =="
DECKB="$TMP/deckb"; mkdir -p "$DECKB"
printf 'repo: /nonexistent\nqueue_archive_days: 30\n' > "$DECKB/kbforge.yaml"
printf '## Open\n- [ ] human: does X still hold given Y?\n' > "$DECKB/QUEUE.md"
TODAY="$(date -u +%Y-%m-%d)"
printf -- '- resolved 2000-01-01: kb/x cites y.py:1\n- resolved %s: kb/x cites z.py:2\n' \
    "$TODAY" > "$DECKB/QUEUE-ARCHIVE.md"
BEFORE_QUEUE="$(cat "$DECKB/QUEUE.md")"
python3 "$FORGE/decay.py" --config "$DECKB/kbforge.yaml" >/dev/null 2>&1 || true
AFTER_QUEUE="$(cat "$DECKB/QUEUE.md")"
[ "$BEFORE_QUEUE" = "$AFTER_QUEUE" ] \
    && ok "decay.py never touches QUEUE.md (human divergence untouched)" \
    || bad "decay.py never touches QUEUE.md (human divergence untouched)"
! grep -q '2000-01-01' "$DECKB/QUEUE-ARCHIVE.md" \
    && ok "decay.py trims archive entries older than queue_archive_days" \
    || bad "decay.py trims archive entries older than queue_archive_days"
grep -q -- "- resolved $TODAY:" "$DECKB/QUEUE-ARCHIVE.md" \
    && ok "decay.py keeps recent archive entries" \
    || bad "decay.py keeps recent archive entries"

echo "== kb-briefing.sh: scoped divergence + drift counts (not file-wide) =="
BKIT="$FORGE/session-kit"
BRT="$TMP/briefing"; mkdir -p "$BRT/.speccraft/kb/derived" "$BRT/.speccraft/kb/normative"
( cd "$BRT" && git init -q && git config user.email t@t && git config user.name t \
  && echo x > README && git add -A && git commit -qm init )
BPIN="$( cd "$BRT" && git rev-parse --short HEAD )"
printf 'source_commit: %s\n' "$BPIN" > "$BRT/.speccraft/kb/derived/inventory.md"
# QUEUE.md: 2 numbered items under ## Open, plus 1 numbered item under ## Ruled
# that must NOT be counted (proves scoping, not file-wide grep)
printf '## Open\n1. divergence one\n2. divergence two\n\n## Ruled\n1. this must NOT be counted (wrong lane)\n' \
  > "$BRT/.speccraft/QUEUE.md"
printf '# SIGNALS\n<!-- signals:drift -->\n- [ ] drift a\n- [ ] drift b\n- [ ] drift c\n<!-- /signals:drift -->\n' \
  > "$BRT/.speccraft/SIGNALS.md"
BOUT=$( cd "$BRT" && KBFORGE_HOME="$BKIT/.." "$BKIT/hooks/kb-briefing.sh" </dev/null )
echo "$BOUT" | grep -q '2 open divergences | 3 drift signals' \
  && ok "briefing: scoped divergence+drift counts (2 in ## Open, not 3 file-wide numbered lines)" \
  || bad "briefing: scoped divergence+drift counts"

# missing SIGNALS.md (fresh KB, no drift run yet) must yield 0, not an error
rm -f "$BRT/.speccraft/SIGNALS.md"
BOUT2=$( cd "$BRT" && KBFORGE_HOME="$BKIT/.." "$BKIT/hooks/kb-briefing.sh" </dev/null )
echo "$BOUT2" | grep -q '2 open divergences | 0 drift signals' \
  && ok "briefing: missing SIGNALS.md yields 0 drift signals, no error" \
  || bad "briefing: missing SIGNALS.md yields 0"

echo "== kb-audit numbers within ## Open, not file-wide =="
QKB="$TMP/qkb"; mkdir -p "$QKB/kb/derived"
printf '## Open\n1. existing divergence\n\n## Ruled — 2026-07-19\n\n9. a past ruling that a file-wide count WOULD catch\n' > "$QKB/QUEUE.md"
printf 'source_commit: abc\n' > "$QKB/kb/derived/inventory.md"
printf 'repo: %s\n' "$CODE" > "$QKB/kbforge.yaml"
# simulate kb-audit appending one finding (call the script's append path or its helper)
bash "$FORGE/session-kit/evals/kb-audit.sh" --kb "$QKB" --append-test "audited: sample finding" 2>/dev/null || true
# the new item must be numbered 2 (within ## Open); old file-wide grep -cE '^[0-9]+\.'
# would count 1. (Open) + 9. (Ruled) = 2 -> next = 3 (WRONG)
grep -qE '^2\. .*sample finding' "$QKB/QUEUE.md" && ok "scoped numbering (2)" || bad "scoped numbering"
awk '/^## Open/{o=1;next}/^## /{o=0}o&&/sample finding/{f=1}END{exit !f}' "$QKB/QUEUE.md" && ok "inserted inside ## Open" || bad "inserted inside ## Open"

echo "== migration keeps human lane, drops mechanical sections =="
MKB="$TMP/mkb"; mkdir -p "$MKB"
cat > "$MKB/QUEUE.md" <<'EOF'
## Open

1. real divergence (INV-5)

## Ruled — 2026-07-19

- a ruling

## Staleness — drift run 2026-07-25 (a→b)

- [ ] spot-check `QUEUE.md` — cites `x.py:1` [file changed elsewhere]

## Dependency drift — dep-diff run 2026-07-25 (a→b)

- [ ] dep-diff: bumped foo
EOF
python3 "$FORGE/migrate_split_queue.py" "$MKB/QUEUE.md"
grep -q 'real divergence' "$MKB/QUEUE.md" && ok "migration keeps ## Open" || bad "migration keeps ## Open"
grep -q 'a ruling' "$MKB/QUEUE.md" && ok "migration keeps ## Ruled" || bad "migration keeps ## Ruled"
! grep -q 'Staleness — drift run' "$MKB/QUEUE.md" && ok "migration drops staleness" || bad "migration drops staleness"
! grep -q 'Dependency drift' "$MKB/QUEUE.md" && ok "migration drops dep drift" || bad "migration drops dep drift"
! grep -q 'cites `QUEUE.md`' "$MKB/QUEUE.md" && ok "migration drops self-citation garbage" || bad "migration drops self-citation"

echo "signals.py: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
