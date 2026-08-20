#!/usr/bin/env bash
# Ship-loop failure surfacing. The loop runs seven forge steps detached, with
# all output redirected to a $TMPDIR log nobody reads; before this suite a step
# could die and the loop would still re-pin and commit, leaving a partially
# refreshed KB that looked clean. These assertions pin that a failure reaches
# KB-STATUS.md, the file every agent session is handed at startup.
set -euo pipefail
FORGE="$(cd "$(dirname "$0")/../.." && pwd)"   # .../speccraft/forge
HOOK="$FORGE/session-kit/post-commit"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# A stub forge: trivial stand-ins for the seven steps, so a failure is something
# the test causes rather than waits for. kb-status.sh is the REAL one — it is
# the code under test.
mkforge() {  # $1=dir
  local f="$1" s
  mkdir -p "$f/session-kit/hooks" "$f/session-kit/evals"
  for s in drift dep-diff decay seed0 assume0 dup0 deps0; do
    cat > "$f/$s.py" <<EOF
import sys, os
open(os.path.join(os.environ["STUBMARK"], "$s.ran"), "w").write(sys.executable)
sys.exit(int(os.environ.get("FAIL_$(echo "$s" | tr 'a-z-' 'A-Z_')", "0")))
EOF
  done
  cp "$FORGE/session-kit/hooks/kb-status.sh" "$f/session-kit/hooks/kb-status.sh"
  chmod +x "$f/session-kit/hooks/kb-status.sh"
  printf '#!/bin/sh\nexit 0\n' > "$f/session-kit/evals/telemetry-report.sh"
  chmod +x "$f/session-kit/evals/telemetry-report.sh"
}

# A git repo carrying a .speccraft KB and one Python manifest, so the
# empty-inventory guard has something to compare against.
mkrepo() {  # $1=dir
  local r="$1" kb="$1/.speccraft"
  mkdir -p "$kb/kb/derived" "$kb/kb/normative" "$kb/ledger"
  ( cd "$r" && git init -q && git config user.email t@t && git config user.name t )
  printf 'repo: %s\n' "$r" > "$kb/kbforge.yaml"
  printf '.shiploop-failure.log\n' > "$kb/.gitignore"   # as kbforge-init writes it
  printf 'source_commit: abc1234\n' > "$kb/kb/derived/inventory.md"
  printf '## Python (runtime) (1)\n- `requests` @ **2.31.0**\n' > "$kb/kb/derived/dependencies.md"
  printf '## INV-1 — a thing\n' > "$kb/kb/normative/01-invariants.md"
  printf 'requests==2.31.0\n' > "$r/requirements.txt"
  printf 'print(1)\n' > "$r/app.py"
  # Two commits: `git diff-tree HEAD` is empty for a root commit, so the loop's
  # "touched only .speccraft/" guard would skip a single-commit fixture.
  ( cd "$r" && git add -A && git commit -q -m "seed" \
      && printf 'print(2)\n' >> app.py && git commit -qam "second" )
}

# Run the loop synchronously against the stubs. The lock is keyed by repo
# basename and lives in TMPDIR, so it is swept between runs or the second
# invocation silently no-ops.
run_loop() {  # $1=repo  (env: FAIL_<STEP>=1 to break a step)
  local r="$1"
  rm -rf "${TMPDIR:-/tmp}/kb-shiploop-$(basename "$r").lock"
  ( cd "$r" && STUBMARK="$MARK" KBFORGE_HOME="$STUBF" KB_SHIPLOOP_SYNC=1 \
      sh "$HOOK" >/dev/null 2>&1 ) || true
}

STUBF="$TMP/forge"; MARK="$TMP/marks"; mkdir -p "$MARK"
mkforge "$STUBF"

echo "== clean run leaves no failure banner =="
R1="$TMP/repo-clean"; mkrepo "$R1"
run_loop "$R1"
STATUS="$R1/.speccraft/KB-STATUS.md"
[ -f "$STATUS" ] && ok "KB-STATUS.md written" || bad "KB-STATUS.md written"
grep -q '⚠ \*\*ship loop:' "$STATUS" 2>/dev/null && bad "clean run must not banner" || ok "clean run has no banner"

echo "== a failing step reaches KB-STATUS.md =="
R2="$TMP/repo-fail"; mkrepo "$R2"; rm -f "$MARK"/*.ran
FAIL_DEPS0=1 run_loop "$R2"
STATUS="$R2/.speccraft/KB-STATUS.md"
grep -q '⚠ \*\*ship loop:' "$STATUS" 2>/dev/null && ok "banner present" || bad "banner present"
grep -q 'deps0' "$STATUS" 2>/dev/null && ok "banner names the failed step" || bad "banner names the failed step"
[ -f "$R2/.speccraft/.shiploop-failure.log" ] && ok "durable failure log written" \
  || bad "durable failure log written"

echo "== a failing step does not abort the steps after it =="
[ -f "$MARK/dup0.ran" ] && ok "step before the failure ran" || bad "step before the failure ran"
# deps0 is last in the sequence; assert the two non-python steps still followed
grep -q 'pin:' "$STATUS" 2>/dev/null && ok "kb-status still ran after failure" \
  || bad "kb-status still ran after failure"

echo "== the failure log is never committed =="
( cd "$R2" && git ls-files --error-unmatch .speccraft/.shiploop-failure.log ) >/dev/null 2>&1 \
  && bad "failure log leaked into the commit" || ok "failure log stays untracked"

echo "== a clean run clears a previous banner =="
rm -f "$MARK"/*.ran
# A real clean run follows a CODE commit. Re-running against the loop's own
# kb: commit is skipped by the anti-recursion guard, which is why the banner
# correctly persists until the next real commit.
( cd "$R2" && printf 'print(3)\n' >> app.py && git commit -qam "more code" )
run_loop "$R2"
grep -q '⚠ \*\*ship loop:' "$R2/.speccraft/KB-STATUS.md" 2>/dev/null \
  && bad "banner must self-clear" || ok "banner self-clears"

echo "== empty dependency inventory is caught despite exit 0 =="
# deps0 wraps tomllib/json parsing in `except Exception: return`, so a bad
# manifest or an old interpreter yields an empty table and a zero exit. The
# repo has requirements.txt, so an entry-less table is a silent failure.
R3="$TMP/repo-empty"; mkrepo "$R3"
printf '## Python (runtime) (0)\n_none found_\n' > "$R3/.speccraft/kb/derived/dependencies.md"
run_loop "$R3"
STATUS="$R3/.speccraft/KB-STATUS.md"
grep -q '⚠ \*\*ship loop:' "$STATUS" 2>/dev/null && ok "empty inventory banners" || bad "empty inventory banners"
grep -qi 'empty' "$STATUS" 2>/dev/null && ok "banner says why" || bad "banner says why"

echo "== interpreter is pinned, not inherited from PATH =="
R4="$TMP/repo-py"; mkrepo "$R4"; rm -f "$MARK"/*.ran
PYWRAP="$TMP/pywrap"; printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v python3)" > "$PYWRAP"
chmod +x "$PYWRAP"
( cd "$R4" && STUBMARK="$MARK" KBFORGE_HOME="$STUBF" KB_SHIPLOOP_SYNC=1 \
    KBFORGE_PYTHON="$PYWRAP" sh "$HOOK" >/dev/null 2>&1 ) || true
[ -f "$MARK/seed0.ran" ] && ok "KBFORGE_PYTHON ran the steps" || bad "KBFORGE_PYTHON ran the steps"

echo "shiploop-failure: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
