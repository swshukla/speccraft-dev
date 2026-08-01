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
  && printf 'a\nb\nc\nd\n' > svc.py && git add . && git commit -qm init )
PIN="$( cd "$CODE" && git rev-parse --short HEAD )"
# a KB fact citing svc.py line 2
printf '# facts\n- svc does X (`svc.py:2`)\n' > "$KB/kb/normative/00.md"
printf 'source_commit: %s\n' "$PIN" > "$KB/kb/derived/inventory.md"
printf 'repo: %s\n' "$CODE" > "$KB/kbforge.yaml"
# change svc.py so line 2's neighborhood shifts -> a drift finding
( cd "$CODE" && printf 'a\nCHANGED\nb\nc\nd\n' > svc.py && git commit -qam change )

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

echo "signals.py: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
