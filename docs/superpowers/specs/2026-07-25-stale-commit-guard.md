# Stale Commit Guard — Pre-Commit Warning on Unratified Coverage

**Date:** 2026-07-25
**Status:** Draft for review

## Problem

The founder has no incentive to run `speccraft-ratify`. It's pure overhead — they
gain nothing personally from sitting through a ratify session. The KB accumulates
open QUEUE.md items and `pending-ratification` facts. Over time the trust ratio
degrades; the KB becomes an unratified pile of observations.

The system currently has no mechanism to make *not ratifying* visible or costly
at the moment it matters most.

## Solution

Add a check to the existing pre-commit hook: if you are committing code that is
governed by unratified facts or open QUEUE.md items, the commit is blocked with
a warning listing what is stale. The founder may bypass with `KB_ACK_STALE=1`
(analogous to `KB_RATIFY=1` for the lane guard).

This ties the cost of an unratified KB to the moment the founder is already
engaged — committing code. The warning fires when it hurts most.

## Design

### Trigger

The check runs after the lane guard (normative/derived/ledger write protection)
in the pre-commit hook. It is skipped if any bypass flag is set:

| Flag | Reason to skip |
|---|---|
| `KB_SHIPLOOP=1` | Ship loop — automated, no human |
| `KB_RATIFY=1` | Founder is actively ratifying this commit |
| `KB_ACK_STALE=1` | Founder acknowledges staleness and proceeds |

### Check logic

```
1. Collect staged file paths (git diff --cached --name-only)
2. Filter out paths under .speccraft/ (KB-only commits aren't the target)
3. If nothing remains after filter → exit 0 (KB-only or empty commit)

4. Count open items in .speccraft/QUEUE.md (lines under "## Open")
5. If OPEN == 0 → exit 0 (no unresolved items)

6. Scan KB normative/ + inferred/ files for status: pending-ratification
   For each such file, collect its anchors: (frontmatter list)
7. For each staged code path, check prefix match against each pending fact's anchors
   (same bidirectional prefix matching as recall.py)
8. If no match → exit 0 (staged code is not governed by anything pending)

9. Print warning:
   ═══════════════════════════════════════════════════════
   KB STALE GUARD: .speccraft/QUEUE.md has N open item(s)
   pending-ratification facts govern files in this commit:
     - <path> → <kb-file> (anchor: <path>)
   The KB cannot vouch for this code. Run speccraft-ratify
   to resolve pending items, or bypass with:
     KB_ACK_STALE=1 git commit ...
   ═══════════════════════════════════════════════════════

10. Exit 1 (block the commit)
```

### Anchor matching

Same prefix logic as `recall.py` (bidirectional prefix match):

```
f.startswith(a.rstrip("/")) or a.startswith(f.rstrip("/"))
```

For QUEUE.md items (which don't have formal anchors), the check is simpler:
any open item blocks any code commit. The rationale: queue items are
cross-cutting — they may not declare file paths but they represent unresolved
questions about the product's truth. More precise anchoring for queue items is
deferred until the QUEUE format gains structured metadata.

### Where it lives

Inline in the existing `kb-forge/session-kit/pre-commit` hook, after the lane
guard block. No new files. The check is fast (grep + prefix matching in shell)
— no python invocation needed.

### Behavioral contract

- **Warn, don't silently pass.** The hook prints the warning and exits 1.
- **Bypass is explicit.** `KB_ACK_STALE=1` is a conscious choice, not a learned
  reflex. The telemetry hook records `stale_ack` when used.
- **Initial commits (no HEAD) skip.** Same as lane guard.
- **KB-only commits skip.** Commits touching only `.speccraft/` are never
  blocked — the founder already tends the KB at that point.

### Telemetry

One new event in the existing telemetry-lib.sh schema:

- `stale_guard_block` — commit blocked by stale check
- `stale_ack` — `KB_ACK_STALE=1` used to bypass

Both added to `kb-status.sh` (as `kb_telemetry` calls in the pre-commit).

## Implementation plan

1. Add the stale check logic to `kb-forge/session-kit/pre-commit`:
   - Implement `speccraft_queue_open_count()` (grep QUEUE.md for open items)
   - Implement `speccraft_pending_facts()` (scan KB files for `pending-ratification`)
   - Implement prefix matching against staged paths
   - Wire into existing hook flow after lane guard

2. Add telemetry calls for `stale_guard_block` and `stale_ack`

3. Add `KB_ACK_STALE=1` to the existing bypass documentation in the hook output

## Out of scope

- Anchored QUEUE.md items (items with per-file scope) — the QUEUE format would
  need structured metadata first. Currently all open items block all code commits.
- Session-level warning (PreToolUse hook) — could be added later but the
  commit-level check is simpler and reaches the founder at the right moment.
- Auto-demotion of stale facts — separate concern, addressed in the design
  review as "founder bottleneck mitigation."
