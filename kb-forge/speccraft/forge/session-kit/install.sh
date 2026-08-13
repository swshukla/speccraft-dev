#!/bin/bash
# kb-forge session-kit installer — arms ONE CLONE of a repo that has a
# .speccraft/ KB. Idempotent; warns instead of clobbering. Tracked artifacts
# (skills, AGENTS.md section, commands) install once per repo and travel
# with clones; hooks + settings.local.json must be re-run per clone/machine.
#
# Usage: install.sh [/path/to/repo]   (default: git toplevel of cwd)
set -e
REPO="${1:-$(git rev-parse --show-toplevel)}"
KIT="$(cd "$(dirname "$0")" && pwd)"
[ -f "$REPO/.speccraft/kbforge.yaml" ] || { echo "no .speccraft/kbforge.yaml in $REPO — run kbforge-init.sh first"; exit 1; }

chmod +x "$KIT"/hooks/*.sh "$KIT/post-commit" "$KIT/pre-commit"

# 1. AGENTS.md — shared cross-agent rules (Codex/OpenCode read it natively)
if [ -f "$REPO/AGENTS.md" ] && grep -q "Knowledge Base (.speccraft/)" "$REPO/AGENTS.md"; then
  echo "AGENTS.md: KB section already present"
else
  printf '\n' >> "$REPO/AGENTS.md" 2>/dev/null || true
  cat "$KIT/AGENTS-section.md" >> "$REPO/AGENTS.md"
  echo "AGENTS.md: KB section appended"
fi

# 2. CLAUDE.md — Claude Code does not read AGENTS.md natively; ensure import
if [ -f "$REPO/CLAUDE.md" ]; then
  grep -q "@AGENTS.md" "$REPO/CLAUDE.md" || { printf '@AGENTS.md\n' | cat - "$REPO/CLAUDE.md" > "$REPO/CLAUDE.md.tmp" && mv "$REPO/CLAUDE.md.tmp" "$REPO/CLAUDE.md"; }
  echo "CLAUDE.md: @AGENTS.md import ensured"
else
  printf '@AGENTS.md\n' > "$REPO/CLAUDE.md"
  echo "CLAUDE.md: created with @AGENTS.md import"
fi

# 3. Skills (tracked, per repo). One source, three registries:
#    .claude/skills (Claude Code) + .agents/skills (Codex & OpenCode both
#    read the Agent Skills standard natively) + .opencode/commands (explicit
#    /speccraft-* invocation in OpenCode).
for d in "$KIT/skills/"speccraft-*; do
  s=$(basename "$d")
  mkdir -p "$REPO/.claude/skills/$s" "$REPO/.agents/skills/$s"
  cp "$KIT/skills/$s/SKILL.md" "$REPO/.claude/skills/$s/SKILL.md"
  cp "$KIT/skills/$s/SKILL.md" "$REPO/.agents/skills/$s/SKILL.md"
done
mkdir -p "$REPO/.opencode/commands"
cp "$KIT/opencode-commands/"speccraft-*.md "$REPO/.opencode/commands/" 2>/dev/null || true
echo "skills: installed to .claude/skills/ + .agents/skills/ (+ .opencode/commands)"

# 3c. Evals (tier-1 telemetry + audits run FROM the kit; repo only needs state)
grep -qx '.speccraft/evals/telemetry.jsonl' "$REPO/.gitignore" 2>/dev/null \
  || echo '.speccraft/evals/telemetry.jsonl' >> "$REPO/.gitignore"
mkdir -p "$REPO/.speccraft/evals/reports"
touch "$REPO/.speccraft/evals/reports/.gitkeep"
if ! grep -q '^evals:' "$REPO/.speccraft/kbforge.yaml"; then
  cat >> "$REPO/.speccraft/kbforge.yaml" <<'EOF'
evals:
  report_window_days: 14
  telemetry_retention_days: 90
  min_recall_rate: 0.70
  min_precision: 0.80
  judge_sample_size: 20
EOF
fi
echo "evals: gitignore + kbforge.yaml evals block + reports dir ensured"

# 3b. Codex explicit /speccraft-* prompts (user-global, once per machine; Codex has
#     no repo-level prompts — its native path is .agents/skills above)
mkdir -p "$HOME/.codex/prompts"
for p in "$KIT/codex-prompts/"speccraft-*.md; do
  [ -f "$HOME/.codex/prompts/$(basename "$p")" ] || cp "$p" "$HOME/.codex/prompts/"
done
echo "codex prompts: ensured in ~/.codex/prompts/"

# 4. .claude/settings.local.json — hooks + per-machine settings (untracked)
mkdir -p "$REPO/.claude"
SL="$REPO/.claude/settings.local.json"
if [ -f "$SL" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    # no jq (common on Windows/Git Bash) — never guess at a JSON merge, and
    # never abort the install this late over it
    if grep -q "kb-briefing.sh" "$SL"; then
      echo "settings.local.json: KB hooks already present"
    else
      echo "settings.local.json: jq not installed — merge $KIT/settings.json into $SL by hand"
    fi
  elif jq -e '.hooks' "$SL" >/dev/null 2>&1; then
    if grep -q "kb-briefing.sh" "$SL"; then
      echo "settings.local.json: KB hooks already present"
    else
      echo "settings.local.json: existing hooks found — merge $KIT/settings.json by hand"
    fi
  else
    jq -s '.[0] * .[1]' "$SL" "$KIT/settings.json" > "$SL.tmp" && mv "$SL.tmp" "$SL"
    echo "settings.local.json: merged"
  fi
else
  cp "$KIT/settings.json" "$SL"
  echo "settings.local.json: installed"
fi

# 5. Git hooks (per clone — git does not version hooks)
for h in post-commit pre-commit; do
  DEST="$REPO/.git/hooks/$h"
  if [ -f "$DEST" ] && ! grep -q "kb-forge" "$DEST"; then
    echo "$h: EXISTS with other content — append $KIT/$h by hand"
  else
    cp "$KIT/$h" "$DEST" && chmod +x "$DEST"
    echo "$h: installed"
  fi
done

# 6. First status file
# must run INSIDE the target repo: kb-status.sh resolves its root from the
# cwd's git toplevel, and exits 0 (silently) when that repo has no KB — so a
# bare call from elsewhere "succeeds" without writing anything.
(cd "$REPO" && "$KIT/hooks/kb-status.sh") || true
echo "KB-STATUS.md: generated"

echo "Done. New agent sessions in $REPO see the KB; commits run the ship loop."
