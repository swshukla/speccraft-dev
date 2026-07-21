#!/bin/bash
# kbforge-init — scaffold a superdev/ KB in a product repo (phases 1-4 of the
# install story; phase 5, the judgment bootstrap, is human-paced).
#
# Usage: kbforge-init.sh /path/to/repo
set -e
REPO="${1:?usage: kbforge-init.sh /path/to/repo}"
REPO="$(cd "$REPO" && pwd)"
FORGE="$(cd "$(dirname "$0")" && pwd)"
git -C "$REPO" rev-parse --show-toplevel >/dev/null || { echo "$REPO is not a git repo"; exit 1; }
# The KB pins to a commit; a repo with zero commits can't be pinned. On a brand
# new repo, make one commit of your starter code first (even a stub).
git -C "$REPO" rev-parse HEAD >/dev/null 2>&1 || {
  echo "ERROR: $REPO has no commits yet. Make an initial commit of your"
  echo "starter code first (e.g. 'git add -A && git commit -m init'), then re-run."
  exit 1
}
KB="$REPO/superdev"

if [ -f "$KB/kbforge.yaml" ]; then
  echo "superdev/ already exists in $REPO — running installer only."
else
  mkdir -p "$KB/kb/derived" "$KB/kb/inferred" "$KB/kb/normative" \
           "$KB/kb/decisions" "$KB/ledger"
  cat > "$KB/kbforge.yaml" <<EOF
# kb-forge product profile
repo: $REPO
# EDIT ME: comma-ish hints only; harvesters are heuristic
components: backend, frontend
test_command: "pytest"
# EDIT ME: path substrings that deserve paranoia (money/auth/user-visible truth)
risk_paths: "auth|login|session|token|payment|billing|subscri"
EOF
  cat > "$KB/README.md" <<'EOF'
# superdev/ — trust-graded knowledge base

Trust rules:
1. Cite or it didn't happen — every claim carries path:line @<pin>.
2. Provenance is never blurred: derived (machine) / inferred (agent
   hypothesis) / elicited (founder's words) / decision (ADR-lite).
3. Nothing becomes `ratified` except by the founder, via QUEUE.md.
4. Stale citations fail: the ship loop re-pins and flags drift each commit.

Lanes: kb/derived (machine, regenerated), kb/inferred (agent drafts,
pending-ratification), kb/normative (ratified truth), kb/decisions
(ADR-lite, append-only), ledger/ (ruled divergences), QUEUE.md (the one
adjudication queue). Agents write only QUEUE.md, kb/decisions/, kb/inferred/.
EOF
  cat > "$KB/QUEUE.md" <<'EOF'
# Adjudication queue

Ranked by citation count × execution frequency × consequence class.
Answering an item = commit the ruling to the KB; the commit is the audit
record. Nothing enters `ratified` except through here.

## Open

## Ruled
EOF
  echo "seeded superdev/ skeleton — EDIT superdev/kbforge.yaml (components, risk_paths)"
fi

# mechanical seed (safe to re-run)
python3 "$FORGE/seed0.py"   --config "$KB/kbforge.yaml"
python3 "$FORGE/assume0.py" --config "$KB/kbforge.yaml"
python3 "$FORGE/dup0.py"    --config "$KB/kbforge.yaml"
python3 "$FORGE/deps0.py"   --config "$KB/kbforge.yaml"

# wire sessions + hooks for this clone
"$FORGE/session-kit/install.sh" "$REPO"

echo ""
echo "kbforge-init complete. Next (human-paced, phase 5):"
echo "  1. Review superdev/kb/derived/ — the mechanical ground truth."
echo "  2. Run the intent interview (agent session) -> kb/normative/."
echo "  3. Run extraction passes (data sources, integrations, assumptions,"
echo "     consistency) -> kb/inferred/, then answer QUEUE batches (kb-ratify)."
echo "  4. Commit: git add superdev .claude AGENTS.md CLAUDE.md && git commit"
