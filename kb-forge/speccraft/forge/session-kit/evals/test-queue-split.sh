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

echo "signals.py: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
