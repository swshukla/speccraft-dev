# Pre-Edit Recall Injection — Move Recall from PostToolUse to PreToolUse

**Date:** 2026-07-25
**Status:** Draft for review

## Problem

Recall runs *after* the edit (`kb-recall-post.sh` fires on PostToolUse). The
agent writes code, then sees the KB facts governing that file. To honor the
facts, the agent must self-correct on a subsequent turn — unreliable and
wasteful. The agent should see the constraints *before* writing.

Additionally, when recall finds nothing, the agent receives no signal. It can't
distinguish "recall wasn't run" from "recall ran and found nothing." This
creates a blind trust problem: the agent may assume no KB facts exist.

## Solution

Move recall injection from PostToolUse to PreToolUse. Before any
Edit/Write/MultiEdit, inject KB facts for the target file into the
conversation context. The agent sees governing facts before writing code.

When recall returns no facts, inject a message stating so — and condition it
on whether the file path matches `risk_paths` in `kbforge.yaml`:

- If the path matches `risk_paths`: *"No KB coverage for `path` — this path is
  risk-tagged; proceed with caution."*
- Otherwise: *"No KB coverage for `path` — no KB constraints apply."*

## Design

### New hook: `kb-recall-pre.sh` (PreToolUse)

Same matcher as the guard hook (`Edit|Write|MultiEdit`). Same logic as the
current `kb-recall-post.sh` — but runs *before* the tool executes.

```
1. Read tool_input.file_path from stdin
2. If path is under .speccraft/ → exit 0 (KB files don't trigger recall)
3. Compute repo-relative path
4. Check dedup cache (/tmp/speccraft-recall-seen-$SID)
   - If already seen this session → exit 0
   - Otherwise, append to cache
5. Run: python3 recall.py --config .speccraft/kbforge.yaml --files <rel-path>
6. If output is non-empty:
   - Inject recall output as additionalContext (same format as current)
   - Log telemetry: recall_ran
7. If output is empty:
   - Read risk_paths from .speccraft/kbforge.yaml (grep for risk_paths:)
   - Check if rel-path matches any risk_paths pattern
   - If match: inject "No KB coverage for `path` — this path is risk-tagged;
     proceed with caution."
   - If no match: inject "No KB coverage for `path` — no KB constraints apply."
   - Log telemetry: recall_empty
```

### Changes to existing files

**Create:** `kb-forge/session-kit/hooks/kb-recall-pre.sh`

**Modify:** `kb-forge/session-kit/settings.json` — add PreToolUse entry for
`kb-recall-pre.sh` alongside the existing `kb-guard.sh` entry. Order matters:
guard should run first (block protected lanes), then recall injection.

**Remove or keep:** `kb-recall-post.sh` — optionally keep as PostToolUse
fallback for agents that add new files mid-edit. The dedup cache ensures it
won't re-inject if the pre-hook already fired.

### Telemetry

- `recall_ran` — existing event, same semantics
- `recall_empty` — existing event, logs the rel-path
- No new events needed

### Risk paths matching

`risk_paths` is a pipe-separated string of path substrings from
`kbforge.yaml`. Matching is simple substring match (not regex anchor):

```sh
RISK=$(grep -m1 '^risk_paths:' "$KB/kbforge.yaml" | cut -d: -f2- | tr -d ' "')
echo "$REL" | grep -qE "$RISK" 2>/dev/null && IS_RISK=1 || IS_RISK=0
```

This matches the convention already documented in the skill files.

### No-coverage injection behavior

The no-coverage message is injected as `additionalContext` — same channel as
recall output. This means:

- The agent sees it in the conversation context
- It's clearly scoped to the file being edited
- The risk-tagged variant carries a stronger caution signal
- Telemetry distinguishes `recall_ran` (had facts) from `recall_empty` (no
  facts with or without risk match)

## Implementation plan

1. Create `kb-forge/session-kit/hooks/kb-recall-pre.sh`:
   - Copy `kb-recall-post.sh` as starting template
   - Add no-coverage branch with risk_paths check
2. Add PreToolUse entry to `settings.json` (before guard or after — guard
   first so protected lanes are denied before recall runs)
3. Update telemetry-lib.sh if `recall_empty` needs additional fields
4. Verify: `kb-recall-post.sh` can remain as fallback or be removed

## Out of scope

- Blocking the edit if recall hasn't been run (approach B from discussion) —
  this spec only covers passive injection.
- OpenCode/Codex hook parity — PreToolUse hooks are Claude Code only,
  same as PostToolUse. Cross-harness recall enforcement is a separate
  concern.
