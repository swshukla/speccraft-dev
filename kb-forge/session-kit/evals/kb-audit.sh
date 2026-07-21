#!/bin/bash
# Tier 2 KB truth audit. Mechanical checks always run (deterministic);
# --judge adds one capped LLM pass (Task 7). Judge flags, never edits.
# Usage: kb-audit.sh [--kb <superdev-dir>] [--root <repo-root>] [--judge]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KB=""; ROOT=""; JUDGE=0
while [ $# -gt 0 ]; do case "$1" in
  --kb) KB=$2; shift 2;; --root) ROOT=$2; shift 2;; --judge) JUDGE=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$ROOT" ] || ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$KB" ] || KB="$ROOT/superdev"
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

mkdir -p "$KB/evals/reports"
R="$KB/evals/reports/$(date +%F)-audit.md"
{ echo "# KB truth audit — $(date +%F)"
  echo; echo "## Mechanical ( ${#ISSUES[@]} issues )"
  for i in "${ISSUES[@]+"${ISSUES[@]}"}"; do echo "- $i"; done
  echo; echo "## Staleness top-10 (code commits on anchors since claim last touched)"
  sed 's/^/- /' <<<"$STALE"
  echo; echo "derived: pin $PIN is $BEHIND commit(s) behind HEAD"
  echo; echo "## Semantic"; echo "SKIPPED (run with --judge)"
} > "$R"
echo "AUDIT: ${#ISSUES[@]} issues"
for i in "${ISSUES[@]+"${ISSUES[@]}"}"; do echo "$i"; done
echo "report: $R"
exit 0
