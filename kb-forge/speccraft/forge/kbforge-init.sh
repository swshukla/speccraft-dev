#!/bin/bash
# kbforge-init — scaffold a .speccraft/ KB in a product repo (phases 1-4 of the
# install story; phase 5, the judgment bootstrap, is human-paced).
#
# Usage: kbforge-init.sh /path/to/repo
set -e
REPO="${1:?usage: kbforge-init.sh /path/to/repo}"
REPO="$(cd "$REPO" && pwd)"
# On Git Bash (MSYS), plain `pwd` reports the MSYS-style path (/c/Users/x/...)
# even when $REPO was handed in as a Windows path. That form only gets
# auto-translated to a real Windows path when it is passed directly as an
# argv to a native (non-MSYS) executable — e.g. `git`, or `python.exe` when
# named on the command line. It is NOT translated when it is written as text
# into a file, which is exactly what happens a few lines down (`repo: $REPO`
# in kbforge.yaml): that file is later read back by python.exe as plain data,
# and native Windows Python cannot resolve "/c/Users/x/proj" (it treats the
# leading "/" as drive-relative on the *current* drive, not as an MSYS root).
# So convert REPO to a Windows-resolvable form here, once, before it is ever
# written anywhere. Prefer `cygpath -m` (mixed form, C:/Users/x/proj):
# forward slashes are accepted uniformly by native Windows Python AND by
# every bash/MSYS command $REPO still flows through below (cd, git -C, the
# session-kit/install.sh call). `cygpath -w` (C:\Users\x\proj, backslashes)
# would also satisfy Python, but backslashes are a needless risk in the bash
# contexts here (escaping/glob edge cases) for zero benefit over -m — there
# is no consumer downstream that requires backslashes specifically.
# No-op on macOS/Linux: neither `cygpath` nor `pwd -W` exist there.
if command -v cygpath >/dev/null 2>&1; then
  REPO="$(cygpath -m "$REPO")"
elif (cd "$REPO" && pwd -W) >/dev/null 2>&1; then
  # Fallback for a Git-Bash-like shell with `pwd -W` but no cygpath binary.
  # Deliberately re-`cd`s into $REPO (already an absolute path at this point)
  # rather than calling bare `pwd -W`, which reports the CALLER's cwd, not
  # $REPO — silently mis-resolving to the wrong directory whenever
  # `speccraft init` is run against a repo other than the current one.
  REPO="$(cd "$REPO" && pwd -W)"
fi
FORGE="$(cd "$(dirname "$0")" && pwd)"
git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "ERROR: $REPO is not a git repo. speccraft is git-native (the KB pins"
  echo "to a commit; drift and guards ride git). Initialize first:"
  echo "  git init && git add -A && git commit -m 'init: snapshot before speccraft'"
  exit 1
}
# The KB pins to a commit; a repo with zero commits can't be pinned. On a brand
# new repo, make one commit of your starter code first (even a stub).
git -C "$REPO" rev-parse HEAD >/dev/null 2>&1 || {
  echo "ERROR: $REPO has no commits yet. Make an initial commit of your"
  echo "starter code first (e.g. 'git add -A && git commit -m init'), then re-run."
  exit 1
}
KB="$REPO/.speccraft"

# Migrate a pre-rename KB: repos initialized before the superdev → speccraft
# rename keep their KB at repo-root superdev/. Rename it (preserving ratified
# facts, ledger, queue) instead of scaffolding a fresh empty .speccraft/
# beside it. If BOTH exist, never guess — the human reconciles.
OLD="$REPO/superdev"
if [ -d "$OLD" ] && { [ -f "$OLD/kbforge.yaml" ] || [ -d "$OLD/kb" ]; }; then
  if [ -d "$KB" ]; then
    echo "WARNING: both superdev/ (pre-rename KB) and .speccraft/ exist in $REPO." >&2
    echo "         Not migrating — reconcile manually (likely: merge superdev/ facts" >&2
    echo "         into .speccraft/, then delete superdev/)." >&2
  else
    if [ -n "$(git -C "$REPO" ls-files superdev)" ]; then
      git -C "$REPO" mv superdev .speccraft
      echo "migrated: superdev/ → .speccraft/ (git mv — staged; commit the rename)"
    else
      mv "$OLD" "$KB"
      echo "migrated: superdev/ → .speccraft/"
    fi
    # retire pre-rename procedure files; the installer below lays down the
    # speccraft-* versions
    rm -rf "$REPO/.claude/skills/superdev-"* \
           "$REPO/.codex/prompts/superdev-"*.md \
           "$REPO/.opencode/command/superdev-"*.md 2>/dev/null || true
    echo "note: grep AGENTS.md/CLAUDE.md for stale 'superdev' mentions — the"
    echo "      installer wires the new speccraft sections but does not edit old text."
  fi
fi

if [ -f "$KB/kbforge.yaml" ]; then
  echo ".speccraft/ already exists in $REPO — running installer only."
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
# .speccraft/ — trust-graded knowledge base

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
  echo "seeded .speccraft/ skeleton — EDIT .speccraft/kbforge.yaml (components, risk_paths)"
fi

# speccraft's skills (kb-ratify, etc.) assume superpowers-style workflow
# discipline (brainstorming, TDD, systematic-debugging) is available. We
# don't vendor it — just nudge installation if it's missing from either the
# user or project plugin config.
if ! grep -qE '"superpowers@[^"]*"[[:space:]]*:[[:space:]]*true' \
       "$HOME/.claude/settings.json" "$REPO/.claude/settings.json" 2>/dev/null; then
  echo "NOTE: superpowers plugin not detected — speccraft's skills assume its"
  echo "      workflow discipline (brainstorming, TDD, systematic-debugging)."
  echo "      Install: /plugin marketplace add anthropics/claude-plugins-official"
  echo "               /plugin install superpowers@claude-plugins-official"
fi

# mechanical seed (safe to re-run). The CLI pins SPECCRAFT_PYTHON to its own
# interpreter — on Windows bare `python3` is usually absent or a Store stub.
PY="${SPECCRAFT_PYTHON:-python3}"
"$PY" "$FORGE/seed0.py"   --config "$KB/kbforge.yaml"
"$PY" "$FORGE/assume0.py" --config "$KB/kbforge.yaml"
"$PY" "$FORGE/dup0.py"    --config "$KB/kbforge.yaml"
"$PY" "$FORGE/deps0.py"   --config "$KB/kbforge.yaml"

# wire sessions + hooks for this clone
"$FORGE/session-kit/install.sh" "$REPO"

echo ""
echo "kbforge-init complete. Setup is NOT finished — next (human-paced, phase 5):"
echo "  1. Review .speccraft/kb/derived/ — the mechanical ground truth."
echo "  2. Run 'speccraft-interview' in an agent session -> kb/normative/."
echo "     REQUIRED first-time step: it elicits intent no code scan can."
echo "  3. Run extraction passes (data sources, integrations, assumptions,"
echo "     consistency) -> kb/inferred/, then answer QUEUE batches (kb-ratify)."
echo "  4. Commit: git add .speccraft .claude AGENTS.md CLAUDE.md && git commit"
