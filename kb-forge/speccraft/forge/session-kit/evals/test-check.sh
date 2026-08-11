#!/usr/bin/env bash
# Phase-4 speccraft-check assertions.
set -euo pipefail
FORGE="$(cd "$(dirname "$0")/../.." && pwd)"   # .../speccraft/forge
TMP="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# fixture: a product repo + a .speccraft with one grep-ban convention
mkkb() { # $1=kbdir  $2=check_mode(optional)
  local kb="$1"; mkdir -p "$kb/kb/normative/conventions"
  printf 'repo: %s\n' "$REPO" > "$kb/kbforge.yaml"
  if [ -n "${2:-}" ]; then printf 'check_mode: %s\n' "$2" >> "$kb/kbforge.yaml"; fi
}
addconv() { # $1=kb $2=id $3=pattern $4=anchors $5=strict(true/"")
  local kb="$1"
  { echo '---'; echo 'status: ratified'; echo "anchors: [$4]";
    echo "avoid_pattern: \"$3\""; echo 'seam: "effective_tier(user)"';
    echo 'avoid: "raw User.tier for gating"';
    [ "$5" = "true" ] && echo 'strict: true';
    echo '---'; echo "## $2 — one entitlement seam"; } > "$kb/kb/normative/conventions/$2.md"
}
REPO="$TMP/repo"; mkdir -p "$REPO/backend/worker"

echo "== grep-ban finds a violation (lenient exits 0 with report) =="
KB="$TMP/kb1"; mkkb "$KB"; addconv "$KB" CONV-11 '\bUser\.tier\b' 'backend/worker' ""
printf 'if User.tier == "pro":\n    pass\n' > "$REPO/backend/worker/push.py"
OUT=$(python3 "$FORGE/check.py" --config "$KB/kbforge.yaml"); RC=0 || RC=$?
printf '%s' "$OUT" | grep -q 'backend/worker/push.py:1' && ok "reports violation with file:line" || bad "reports violation"
printf '%s' "$OUT" | grep -q 'effective_tier' && ok "reports the seam fix" || bad "reports seam"
python3 "$FORGE/check.py" --config "$KB/kbforge.yaml" >/dev/null 2>&1; [ $? -eq 0 ] && ok "lenient default exits 0" || bad "lenient exits 0"

echo "== --strict exits nonzero on a violation =="
python3 "$FORGE/check.py" --config "$KB/kbforge.yaml" --strict >/dev/null 2>&1 && bad "--strict exits nonzero" || ok "--strict exits nonzero"

echo "== global check_mode: strict exits nonzero =="
KB2="$TMP/kb2"; mkkb "$KB2" strict; addconv "$KB2" CONV-11 '\bUser\.tier\b' 'backend/worker' ""
python3 "$FORGE/check.py" --config "$KB2/kbforge.yaml" >/dev/null 2>&1 && bad "global strict nonzero" || ok "global strict nonzero"

echo "== per-check strict: true fails even when global is lenient =="
KB3="$TMP/kb3"; mkkb "$KB3"; addconv "$KB3" CONV-11 '\bUser\.tier\b' 'backend/worker' true
OUT=$(python3 "$FORGE/check.py" --config "$KB3/kbforge.yaml" 2>&1) || true; RC=0; python3 "$FORGE/check.py" --config "$KB3/kbforge.yaml" >/dev/null 2>&1 || RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '\[strict\]' && ok "per-check strict fails + tagged [strict]" || bad "per-check strict"

echo "== clean repo: no violations, exit 0 =="
KB4="$TMP/kb4"; mkkb "$KB4"; addconv "$KB4" CONV-11 '\bUser\.tier\b' 'backend/worker' ""
CLEAN="$TMP/clean"; mkdir -p "$CLEAN/backend/worker"; printf 'x = effective_tier(user)\n' > "$CLEAN/backend/worker/ok.py"
sed -i.bak "s#repo: .*#repo: $CLEAN#" "$KB4/kbforge.yaml"
python3 "$FORGE/check.py" --config "$KB4/kbforge.yaml" 2>&1 | grep -q 'speccraft-check: 0 violations' && ok "clean repo 0 violations" || bad "clean repo"

echo "== convention without avoid_pattern is skipped =="
KB5="$TMP/kb5"; mkkb "$KB5"
{ echo '---'; echo 'status: ratified'; echo 'anchors: [backend]'; echo 'seam: "x()"'; echo '---'; echo '## CONV-9'; } > "$KB5/kb/normative/conventions/CONV-9.md"
python3 "$FORGE/check.py" --config "$KB5/kbforge.yaml" 2>&1 | grep -q 'speccraft-check: 0 violations' && ok "no avoid_pattern → skipped" || bad "skipped"

echo "== custom check script: nonzero → violation, exit0 → pass =="
KB6="$TMP/kb6"; mkdir -p "$KB6/kb/normative/checks"; printf 'repo: %s\n' "$REPO" > "$KB6/kbforge.yaml"
cat > "$KB6/kb/normative/checks/CHK-01-demo.sh" <<'EOF'
#!/usr/bin/env bash
# check-for: INV-1
# strict: true
echo "model Portfolio absent from target_metadata"
exit 1
EOF
chmod +x "$KB6/kb/normative/checks/CHK-01-demo.sh"
OUT=$(python3 "$FORGE/check.py" --config "$KB6/kbforge.yaml" 2>&1) || true; RC=0; python3 "$FORGE/check.py" --config "$KB6/kbforge.yaml" >/dev/null 2>&1 || RC=$?
printf '%s' "$OUT" | grep -q 'Portfolio absent' && ok "script stdout surfaced" || bad "script stdout"
printf '%s' "$OUT" | grep -q 'CHK-01' && [ "$RC" -ne 0 ] && ok "script strict header → nonzero exit" || bad "script strict"
# a passing (exit 0) script produces no violation
cat > "$KB6/kb/normative/checks/CHK-02-ok.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$KB6/kb/normative/checks/CHK-02-ok.sh"
python3 "$FORGE/check.py" --config "$KB6/kbforge.yaml" 2>&1 | grep -q 'CHK-02' && bad "exit0 script should not report" || ok "exit0 script → no violation"

echo "== grep-ban anchor is a PATH PREFIX, not an exact file/dir (regression: silent 0-scan) =="
KB7="$TMP/kb7"; mkkb "$KB7"; addconv "$KB7" CONV-12 '\bUser\.tier\b' 'backend/worker/push' true
# backend/worker/push.py already exists (written above) and contains User.tier;
# 'backend/worker/push' is neither an exact file nor an exact dir — only a prefix.
OUT=$(python3 "$FORGE/check.py" --config "$KB7/kbforge.yaml" 2>&1) || true
printf '%s' "$OUT" | grep -q 'backend/worker/push.py' && ok "prefix anchor 'backend/worker/push' still scans push.py" || bad "prefix anchor silently scanned nothing"

echo "== avoid_pattern with a character class survives a RAW read (would be mangled by frontmatter()) =="
KB8="$TMP/kb8"; mkkb "$KB8"
mkdir -p "$REPO/backend/legacy"
printf "if user.tier == 'x':\n    pass\n" > "$REPO/backend/legacy/raw.py"
addconv "$KB8" CONV-13 '[Uu]se[r]\.tie[r]' 'backend/legacy' ""
OUT=$(python3 "$FORGE/check.py" --config "$KB8/kbforge.yaml" 2>&1) || true
printf '%s' "$OUT" | grep -q 'backend/legacy/raw.py' && ok "character-class avoid_pattern matched via raw read" || bad "character-class avoid_pattern lost/mangled"

echo "check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
