# Stale Commit Guard — Pre-Commit Warning on Unratified Coverage

**Date:** 2026-07-25
**Status:** Draft for review (rev 2 — narrowed blocking condition)

## Problem

The founder has no incentive to run `speccraft-ratify`. It's pure overhead — they
gain nothing personally from sitting through a ratify session. The KB accumulates
open QUEUE.md items and `pending-ratification` facts. Over time the trust ratio
degrades; the KB becomes an unratified pile of observations.

The system currently has no mechanism to make *not ratifying* visible or costly
at the moment it matters most.

## Solution

Add a check to the existing pre-commit hook with **two tiers**:

- **Blocking tier (precise):** the commit is blocked when a staged file is
  governed by something unresolved — a `pending-ratification` fact whose anchor
  matches the file, or an open QUEUE.md item that names the file. The warning
  lists exactly which items govern which staged files. Bypass with
  `KB_ACK_STALE=1` (analogous to `KB_RATIFY=1` for the lane guard).
- **Warning tier (broad):** open queue items that name no staged file produce a
  one-line count + oldest-item-age warning and the commit proceeds. Visibility
  without blocking.

This ties the cost of an unratified KB to the moment the founder is already
engaged — committing code — while keeping every *block* precise enough that a
block is always legitimate. The rest of the system (drift runs, divergence
capture, anchor-scope and dep-diff findings) is designed to keep QUEUE.md
non-empty in steady state; a guard that blocked on *any* open item would fire
on essentially every commit, train `KB_ACK_STALE=1` as a reflex, and erode the
credibility of the lane guard along with it. Guards earn blocking rights by
precision.

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

4. Collect blocking matches, from two sources:

   a. PENDING FACTS: scan KB normative/ + inferred/ files for
      status: pending-ratification. For each, collect its anchors:
      (frontmatter list). Prefix-match each staged path against each
      anchor (same bidirectional prefix matching as recall.py).

   b. PATH-BEARING QUEUE ITEMS: for each open item in .speccraft/QUEUE.md,
      extract backtick-wrapped tokens containing "/" (drift.py already
      writes queue items with backticked repo paths — no format change
      needed). Strip any :line-range suffix. Prefix-match staged paths
      against the extracted paths.

5. If any match → print blocking warning (below), log stale_guard_block,
   exit 1.

6. Otherwise, count remaining open queue items (those that named no staged
   file). If count > 0 → print one-line warning with count and oldest item
   age, log stale_warn, exit 0. If count == 0 → exit 0 silently.
```

### Blocking warning format

```
═══════════════════════════════════════════════════════
KB STALE GUARD: staged files are governed by unresolved KB items
  - <staged-path> → <kb-file> (pending-ratification, anchor: <anchor>)
  - <staged-path> → QUEUE.md item N: "<item excerpt>"
The KB cannot vouch for this code. Run speccraft-ratify
to resolve pending items, or bypass with:
  KB_ACK_STALE=1 git commit ...
═══════════════════════════════════════════════════════
```

Every line names a specific staged file and the specific unresolved item
governing it. A block never fires because "some uncertainty exists somewhere."

### Warning tier format

```
KB stale guard: 7 open QUEUE.md item(s) unrelated to this commit (oldest: 12d).
Run speccraft-ratify when convenient.
```

### Anchor matching

Same prefix logic as `recall.py` (bidirectional prefix match):

```
f.startswith(a.rstrip("/")) or a.startswith(f.rstrip("/"))
```

Queue-item path extraction is a `grep -o` for backtick-wrapped tokens
containing `/`, with trailing `:<line>` or `:<start>-<end>` ranges stripped.
Items that mention no path fall through to the warning tier — the correct
default for genuinely cross-cutting items.

### Where it lives

Inline in the existing `kb-forge/session-kit/pre-commit` hook, after the lane
guard block. No new files. The check is fast (grep + prefix matching in shell)
— no python invocation needed.

### Behavioral contract

- **Blocks are precise.** Exit 1 only when a staged file matches a pending
  fact's anchor or an open queue item's extracted path. Everything else is
  warn-and-proceed.
- **Warn, don't silently pass.** Unrelated open items still produce the
  one-line warning tier — staleness stays visible on every commit.
- **Bypass is explicit.** `KB_ACK_STALE=1` is a conscious choice, not a learned
  reflex. The telemetry hook records `stale_ack` when used. If telemetry shows
  `stale_ack` trending toward 100% of blocks, the blocking condition is too
  broad — that ratio is the guard's own health metric.
- **Initial commits (no HEAD) skip.** Same as lane guard.
- **KB-only commits skip.** Commits touching only `.speccraft/` are never
  blocked — the founder already tends the KB at that point.

### Telemetry

Three events in the existing telemetry-lib.sh schema:

- `stale_guard_block` — commit blocked by stale check (blocking tier)
- `stale_warn` — warning tier fired (open items, none matching staged files)
- `stale_ack` — `KB_ACK_STALE=1` used to bypass

All added to `kb-status.sh` (as `kb_telemetry` calls in the pre-commit).
`telemetry-report.sh` should surface the `stale_ack / stale_guard_block`
ratio — a rising ratio means blocks are being reflex-bypassed and the
matching needs tightening.

## Implementation plan

1. Add the stale check logic to `kb-forge/session-kit/pre-commit`:
   - Implement `speccraft_pending_facts()` (scan KB files for
     `pending-ratification` + collect anchors)
   - Implement `speccraft_queue_paths()` (extract backticked repo paths from
     open QUEUE.md items, strip line ranges)
   - Implement prefix matching of staged paths against both sources
   - Implement warning-tier fallback (open-item count + oldest age)
   - Wire into existing hook flow after lane guard

2. Add telemetry calls for `stale_guard_block`, `stale_warn`, and `stale_ack`

3. Add `KB_ACK_STALE=1` to the existing bypass documentation in the hook output

4. Extend `telemetry-report.sh` with the ack/block ratio

## Future knob (deliberately not in v1)

**Threshold escalation:** upgrade the warning tier to blocking when the queue
shows sustained neglect — e.g. open items > N or oldest item > D days. This
prices *sustained* neglect rather than the normal steady-state of a working
system. Deferred until real `stale_warn` telemetry shows what N and D should
be; guessing them now risks re-introducing the reflex-bypass failure mode.

## Out of scope

- Structured queue metadata (formal per-item anchors) — path extraction from
  backticked tokens covers the current QUEUE.md format that drift.py writes;
  a structured format can replace extraction later without changing the
  matching logic.
- Session-level warning (PreToolUse hook) — could be added later but the
  commit-level check is simpler and reaches the founder at the right moment.
- Auto-demotion of stale facts — separate concern, addressed in the design
  review as "founder bottleneck mitigation." Note: this remains the actual
  release valve for queue growth; the guard makes neglect visible but does
  not bound the queue.
