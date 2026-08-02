#!/bin/bash
# Tier 2 KB truth audit. Mechanical checks always run (deterministic);
# --judge adds one capped LLM pass (Task 7). Judge flags, never edits.
# Usage: kb-audit.sh [--kb <.speccraft-dir>] [--root <repo-root>] [--judge]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KB=""; ROOT=""; JUDGE=0; APPEND_TEST=""
# insert "$1" as the next-numbered item at the end of QUEUE.md's ## Open
# section (numbering scoped to that section, never a file-wide count, and
# never appended past arbitrary end-of-file). Test-only entry point below
# (--append-test) exercises this without a full eval run.
queue_insert_open(){
  local text="$1" n
  n=$(awk '/^## Open/{o=1;next}/^## /{o=0}o&&/^[0-9]+\./{c++}END{print c+1}' "$KB/QUEUE.md")
  awk -v n="$n" -v t="$text" '
    /^## Open/{o=1; print; next}
    o && /^## /{print n". "t; print ""; o=0}
    {print}
    END{ if(o) print n". "t }
  ' "$KB/QUEUE.md" > "$KB/QUEUE.md.tmp" && mv "$KB/QUEUE.md.tmp" "$KB/QUEUE.md"
}
while [ $# -gt 0 ]; do case "$1" in
  --kb) KB=$2; shift 2;; --root) ROOT=$2; shift 2;; --judge) JUDGE=1; shift;;
  --append-test) APPEND_TEST=$2; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$ROOT" ] || ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$KB" ] || KB="$ROOT/.speccraft"
if [ -n "$APPEND_TEST" ]; then
  queue_insert_open "$APPEND_TEST"
  exit 0
fi
[ -d "$KB/kb" ] || exit 0
LEGAL='ratified|ratified-partial|observed|pending-ratification|challenged'
ISSUES=(); note(){ ISSUES+=("$1"); }
frontval(){ awk -v k="$2:" 'NR>1 && /^---/{exit} $1==k{sub($1 FS,""); print; exit}' "$1"; }
anchor_paths(){ frontval "$1" anchors | tr -d '[],' | tr ' ' '\n' | grep -E '/|\.' || true; }

for f in "$KB"/kb/normative/*.md "$KB"/kb/inferred/*.md; do
  [ -f "$f" ] || continue
  rel=${f#"$ROOT"/}
  st=$(frontval "$f" status)
  [ -z "$st" ] && note "structural: $rel missing status frontmatter"
  [ -n "$st" ] && ! grep -qE "^($LEGAL)$" <<<"$st" && note "structural: $rel illegal status '$st'"
  case "$f" in "$KB"/kb/normative/*)
    [ -z "$(frontval "$f" elicited_by)$(frontval "$f" documented_by)" ] \
      && note "provenance: $rel has neither elicited_by nor documented_by" ;;
  esac
  db=$(frontval "$f" documented_by)
  if grep -q '^doc:' <<<"$db"; then
    spec=${db#doc:}; c=${spec##*@}; p=${spec%@*}
    [ -e "$ROOT/$p" ] || note "provenance: $rel documented_by path missing: $p"
    git -C "$ROOT" cat-file -e "$c^{commit}" 2>/dev/null \
      || note "provenance: $rel documented_by commit unknown: $c"
  fi
  while read -r a; do [ -z "$a" ] && continue
    [ -e "$ROOT/$a" ] || note "anchor-rot: $rel -> $a missing"
  done <<<"$(anchor_paths "$f")"
done

DUP=$(grep -hoE '^#+ *INV-[0-9]+' "$KB/kb/normative/01-invariants.md" 2>/dev/null \
      | grep -oE 'INV-[0-9]+' | sort | uniq -d | tr '\n' ' ')
[ -n "${DUP// /}" ] && note "structural: duplicate invariant ids: ${DUP% }"

# staleness index (info, not an issue): code commits on anchors since file's last commit
STALE=""
for f in "$KB"/kb/normative/*.md "$KB"/kb/inferred/*.md; do
  [ -f "$f" ] || continue
  last=$(git -C "$ROOT" log -1 --format=%cI -- "${f#"$ROOT"/}" 2>/dev/null)
  paths=$(anchor_paths "$f" | tr '\n' ' ')
  [ -z "$last" ] || [ -z "${paths// /}" ] && continue
  n=$(git -C "$ROOT" rev-list --count --since="$last" HEAD -- $paths 2>/dev/null || echo 0)
  STALE+="$n ${f#"$ROOT"/}"$'\n'
done
STALE=$(sort -rn <<<"$STALE" | grep -v '^$' | head -10)

PIN=$(grep -m1 '^source_commit:' "$KB/kb/derived/inventory.md" 2>/dev/null | awk '{print $2}')
BEHIND=$(git -C "$ROOT" rev-list --count "$PIN..HEAD" 2>/dev/null || echo '?')

SEM_LINES="SKIPPED (run with --judge)"
PRECISION=""; NSAMP=0
if [ "$JUDGE" -eq 1 ]; then
  if ! command -v claude >/dev/null 2>&1; then
    SEM_LINES="SKIPPED (claude CLI not found)"
  else
    cfgval(){ awk -v k="$1:" '$1==k {print $2; exit}' "$KB/kbforge.yaml" 2>/dev/null; }
    CAP=$(cfgval judge_sample_size); CAP=${CAP:-20}
    MINP=$(cfgval min_precision); MINP=${MINP:-0.80}
    CLAIMS=""
    # seed the capped sample with anchor-scope judge targets first — new
    # files under normative anchors are the highest-yield semantic checks
    TAB=$(printf '\t')
    while IFS="$TAB" read -r jkb janch jfile; do
      [ -z "${jkb:-}" ] && continue
      [ "$(grep -c '^- claim' <<<"$CLAIMS")" -ge "$CAP" ] && break
      CLAIMS+="- claim: new file $jfile entered the scope of anchor $janch; verify the fact still holds over it | file: .speccraft/$jkb"$'\n'
    done <<<"$(python3 "$HERE/../../drift.py" --config "$KB/kbforge.yaml" --judge-targets 2>/dev/null)"
    # sample observed/documented claims, staleness-ranked file order; never elicited
    while read -r _n f; do
      [ -z "${f:-}" ] && continue
      st=$(frontval "$ROOT/$f" status)
      case "$st" in ratified|ratified-partial) continue;; esac
      while read -r c; do
        [ -z "$c" ] && continue
        [ "$(grep -c '^- claim' <<<"$CLAIMS")" -ge "$CAP" ] && break
        CLAIMS+="- claim: ${c#- } | file: $f"$'\n'
      done <<<"$(grep -E '^- ' "$ROOT/$f")"
    done <<<"$STALE"
    # invariant compliance pass (always included)
    while read -r inv; do
      [ -z "$inv" ] && continue
      CLAIMS+="- claim: ${inv#\#\# } | file: .speccraft/kb/normative/01-invariants.md"$'\n'
    done <<<"$(grep -E '^#+ *INV-' "$KB/kb/normative/01-invariants.md" 2>/dev/null)"
    NSAMP=$(grep -c '^- claim' <<<"$CLAIMS")
    # code context: head of every anchored path referenced by sampled files
    CTX=""
    for p in $(for f in "$KB"/kb/normative/*.md "$KB"/kb/inferred/*.md; do
                 [ -f "$f" ] && anchor_paths "$f"; done | sort -u); do
      [ -f "$ROOT/$p" ] && CTX+="### $p"$'\n'"$(sed -n '1,80p' "$ROOT/$p")"$'\n'
    done
    PROMPT="$(cat "$HERE/judge-rubric.md")"$'\n\n## Claims\n'"$CLAIMS"$'\n## Code context\n'"$CTX"
    VERD=$(claude -p "$PROMPT" --output-format text 2>/dev/null | sed -n '/^\[/,$p')
    if jq -e . >/dev/null 2>&1 <<<"$VERD"; then
      NS=$(jq '[.[]|select(.verdict=="SUPPORTED")]|length' <<<"$VERD")
      NT=$(jq 'length' <<<"$VERD")
      PRECISION=$(awk "BEGIN{printf \"%.2f\", $NT ? $NS/$NT : 0}")
      SEM_LINES=$(jq -r '.[] | "- \(.verdict): \(.claim) [\(.file)] — \(.evidence)"' <<<"$VERD")
      # route non-SUPPORTED verdicts to QUEUE (session lane; scoped to ## Open)
      while read -r line; do
        [ -z "$line" ] && continue
        queue_insert_open "[evals-audit $(date +%F)] $line"
      done <<<"$(jq -r '.[] | select(.verdict!="SUPPORTED")
        | "\(.verdict): \(.claim) [\(.file)] — \(.evidence)"' <<<"$VERD")"
      # upsert health line
      mkdir -p "$KB/evals"
      H="$KB/evals/health.md"
      grep -v '^- last audit:' "$H" 2>/dev/null > "$H.tmp" || true
      echo "- last audit: $(date +%F) precision $PRECISION ($NT sampled)" >> "$H.tmp"
      mv "$H.tmp" "$H"
      if [ "$NT" -ge 5 ] && awk "BEGIN{exit !($PRECISION < $MINP)}"; then
        mkdir -p "$KB/findings"
        FD="$KB/findings/$(date +%F)-evals-kb-precision.md"
        [ -f "$FD" ] || cat > "$FD" <<EOF
# Finding: KB claim precision below threshold
- audit $(date +%F): precision $PRECISION over $NT sampled claims (< $MINP)
- non-SUPPORTED verdicts were appended to .speccraft/QUEUE.md — adjudicate via
  speccraft-diverge (CONTRADICTED) / speccraft-ratify (confirm) / dismiss.
EOF
      fi
    else
      SEM_LINES="SKIPPED (judge returned unparseable output)"
    fi
  fi
fi

mkdir -p "$KB/evals/reports"
R="$KB/evals/reports/$(date +%F)-audit.md"
{ echo "# KB truth audit — $(date +%F)"
  echo; echo "## Mechanical ( ${#ISSUES[@]} issues )"
  for i in "${ISSUES[@]+"${ISSUES[@]}"}"; do echo "- $i"; done
  echo; echo "## Staleness top-10 (code commits on anchors since claim last touched)"
  sed 's/^/- /' <<<"$STALE"
  echo; echo "derived: pin $PIN is $BEHIND commit(s) behind HEAD"
  echo; echo "## Semantic"
  [ -n "$PRECISION" ] && echo "precision $PRECISION ($NSAMP sampled)"
  printf '%s\n' "$SEM_LINES"
} > "$R"
echo "AUDIT: ${#ISSUES[@]} issues"
for i in "${ISSUES[@]+"${ISSUES[@]}"}"; do echo "$i"; done
echo "report: $R"
exit 0
