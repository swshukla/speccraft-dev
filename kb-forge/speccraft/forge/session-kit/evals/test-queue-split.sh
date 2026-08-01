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

echo "signals.py: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
