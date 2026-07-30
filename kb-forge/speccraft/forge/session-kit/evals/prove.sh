#!/bin/bash
# speccraft prove engine — pull-based, single-fact proof VERIFIER (no render).
# Resolves ONE named fact, re-judges it against current code via the same
# headless `claude -p` judge kb-audit.sh uses, and emits a machine-readable
# block plus a verdict-coded exit status. It renders NOTHING and writes no
# QUEUE — that is the skill's job. This script is pure measurement.
#
# Usage: prove.sh <REPO_ROOT> <FACT-ID>
#   FACT-ID = INV-<n>  (a ratified invariant heading), or a unique substring of
#             a `- ` bullet / `## ` heading anywhere under .speccraft/kb/.
# Exit: 0 SUPPORTED · 10 POSSIBLY_STALE · 20 CONTRADICTED · 2 resolution error.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

[ $# -eq 2 ] || { echo "usage: prove.sh <REPO_ROOT> <FACT-ID>" >&2; exit 2; }
ROOT="$1"; FACT="$2"
KBROOT="$ROOT/.speccraft/kb"
[ -d "$KBROOT" ] || { echo "prove: no .speccraft/kb under $ROOT" >&2; exit 2; }

# --- helpers (same idiom as kb-audit.sh) ---
frontval(){ awk -v k="$2:" 'NR>1 && /^---/{exit} $1==k{sub($1 FS,""); print; exit}' "$1"; }
anchor_paths(){ frontval "$1" anchors | tr -d '[],' | tr ' ' '\n' | grep -E '/|\.' || true; }
relpath(){ printf '%s' "${1#$ROOT/}"; }

# ---------- 1. resolve FACT-ID -> CLAIM + KBFILE ----------
if [[ "$FACT" =~ ^INV-([0-9]+)$ ]]; then
  N="${BASH_REMATCH[1]}"
  KBFILE="$KBROOT/normative/01-invariants.md"
  [ -f "$KBFILE" ] || { echo "prove: invariants file not found: $(relpath "$KBFILE")" >&2; exit 2; }
  HEADING=$(grep -m1 -E "^## +INV-$N([^0-9]|\$)" "$KBFILE" || true)
  [ -n "$HEADING" ] || { echo "prove: INV-$N not found in $(relpath "$KBFILE")" >&2; exit 2; }
  CLAIM="${HEADING#\#\# }"
else
  # unique `- ` bullet or `## ` heading containing the substring, across kb/**
  MATCHES=$(grep -rnE '^(#+ |- )' "$KBROOT" --include='*.md' 2>/dev/null | grep -F -- "$FACT" || true)
  CNT=$(printf '%s' "$MATCHES" | grep -c . )
  if [ "$CNT" -ne 1 ]; then
    echo "prove: '$FACT' resolves to $CNT bullets/headings under .speccraft/kb (need exactly 1)" >&2
    exit 2
  fi
  KBFILE="${MATCHES%%:*}"
  CONTENT="${MATCHES#*:*:}"
  CLAIM=$(printf '%s' "$CONTENT" | sed -E 's/^(#+ +|- +)//')
fi
KBREL=$(relpath "$KBFILE")

# ---------- 2. build the single-claim judge prompt (kb-audit idiom) ----------
FILEANCHORS=$(anchor_paths "$KBFILE" | tr '\n' ' ' | sed -E 's/ +$//')
CLAIMS="- claim: $CLAIM | file: $KBREL"$'\n'
CTX=""
for p in $FILEANCHORS; do
  [ -f "$ROOT/$p" ] && CTX+="### $p"$'\n'"$(head -120 "$ROOT/$p")"$'\n'
done
PROMPT="$(cat "$HERE/judge-rubric.md")"$'\n\n## Claims\n'"$CLAIMS"$'\n## Code context\n'"$CTX"
VERD=$(claude -p "$PROMPT" --output-format text 2>/dev/null | sed -n '/^\[/,$p')

# ---------- 3. select the element for THIS fact ----------
SEL=""
if printf '%s' "$VERD" | jq -e . >/dev/null 2>&1; then
  if [ -n "${N:-}" ]; then
    SEL=$(jq -c --arg n "$N" 'first(.[]|select(.claim|test("INV-"+$n+"([^0-9]|$)"))) // empty' <<<"$VERD")
  else
    # exact echo of the sent claim, else its distinctive stem (parenthetical trimmed)
    SEL=$(jq -c --arg c "$CLAIM" 'first(.[]|select(.claim==$c)) // empty' <<<"$VERD")
    if [ -z "$SEL" ]; then
      STEM=$(printf '%s' "$CLAIM" | sed -E 's/[[:space:]]*\([^)]*\)[[:space:]]*$//')
      SEL=$(jq -c --arg s "$STEM" 'first(.[]|select(.claim|contains($s))) // empty' <<<"$VERD")
    fi
  fi
  [ -n "$SEL" ] || SEL=$(jq -c '.[0] // empty' <<<"$VERD")
fi

if [ -n "$SEL" ]; then
  VERDICT=$(jq -r '.verdict // "POSSIBLY_STALE"' <<<"$SEL")
  EVID=$(jq -r '.evidence // "not visible in context"' <<<"$SEL")
else
  # judge unavailable/unparseable — never claim SUPPORTED without evidence
  VERDICT="POSSIBLY_STALE"
  EVID="judge unavailable — could not re-verify"
fi

# ---------- 4. CODEHASH = deterministic short hash of the FILE anchors ----------
TMPC=$(mktemp)
for p in $FILEANCHORS; do
  [ -f "$ROOT/$p" ] && cat "$ROOT/$p" >> "$TMPC"
done
CODEHASH=$(git hash-object "$TMPC" 2>/dev/null | cut -c1-12)
[ -n "$CODEHASH" ] || CODEHASH=$( (sha1sum "$TMPC" 2>/dev/null || shasum "$TMPC") | cut -c1-12)
rm -f "$TMPC"

# ---------- 5. emit machine-readable block ----------
case "$VERDICT" in
  SUPPORTED)    RC=0 ;;
  CONTRADICTED) RC=20 ;;
  *)            VERDICT="POSSIBLY_STALE"; RC=10 ;;
esac
cat <<EOF
FACT: $FACT
CLAIM: $CLAIM
KBFILE: $KBREL
ANCHORS: $FILEANCHORS
CODEHASH: $CODEHASH
VERDICT: $VERDICT
EVIDENCE: $EVID
EOF
exit $RC
