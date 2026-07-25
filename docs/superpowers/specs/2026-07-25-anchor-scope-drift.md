# Anchor Scope Drift — Detect New Files Under Existing KB Anchors

**Date:** 2026-07-25
**Status:** Draft for review

## Problem

`drift.py` checks subtractive drift (cited lines changed) and additive drift
(new integration/assumption surface in the diff). Both are file-content-based.

It misses: **new files added within a fact's anchor scope.** A fact anchored to
`backend/` means it governs *all files under `backend/`* — present and future.
When someone adds `backend/workers/notify-webhook.py`, that file is implicitly
governed by the same invariant. If the KB fact says "all API calls go through
the client" and the new file makes raw HTTP calls, it violates the invariant.
`drift.py` reports nothing — no cited lines changed, no new URLs in the diff
line scan (the import might not match the additive patterns).

## Solution

Add a third drift direction to `drift.py`: **anchor scope drift.** After
computing subtractive and additive drift, check whether any files added since
the pin fall under existing KB facts' anchor scopes. If so, report them as
coverage candidates that the KB may not account for.

## Design

### Detection

```python
1. Collect added files since pin: 
   git diff --name-only --diff-filter=A pin..HEAD -- . ':(exclude).speccraft'

2. For each KB fact (normative/, inferred/, decisions/) that has anchors:
   - For each path anchor:
     - If anchor is a directory prefix (ends with / or maps to a dir):
       - Check if any added file starts with the anchor
     - If anchor is a specific file:
       - Check if it was deleted (already covered by subtractive)
       - No new scope check needed

3. Report matches as:
   ANCHOR SCOPE — new file(s) in scope of existing fact
     <kb_file>  (anchor: <anchor>):
       + backend/workers/notify-webhook.py
```

### Output format

Added after the existing ADDITIVE and DEPENDENCY sections:

```
ANCHOR SCOPE drift — new files added under anchored paths since pin:

  kb/inferred/06-integrations.md  (anchor: backend/):
    + backend/workers/notify-webhook.py
    + backend/tasks/healthcheck.py

  kb/normative/01-invariants.md  (anchor: backend/middleware/auth.py):
    (file still exists — no scope change)
```

### Integration with --queue flag

When `--queue` is passed and anchor scope drift is found, append items:

```
- [ ] anchor scope drift: `kb/inferred/06-integrations.md` — new file(s) in
  scope of `backend/`: `backend/workers/notify-webhook.py`. Verify whether
  the fact applies to these new files or needs its anchor narrowed.
```

### Implementation

This is purely mechanical (git diff + prefix matching). No LLM, no new config.
The anchor prefix matching reuses the same logic as `recall.py` (line 79).

Add a new function `anchor_scope_drift(kbroot, repo, pin, head)` that:

- Calls `git diff --name-only --diff-filter=A pin..HEAD -- . ':(exclude).speccraft'`
- Walks KB files (same `collect()` pattern as `recall.py`)
- For each fact's path anchors, checks against the added set
- Returns a dict: `{kb_file: [(anchor, [added_file, ...]), ...]}`

### File count

This is intentionally a report-only finding. It doesn't block anything. The
founder sees it and decides whether to narrow anchors or add new facts. Over
time, projects develop a sense of which scopes need tightening — the output
trains the founder's judgment.

## Telemetry

No new telemetry. This runs as part of `drift.py` which is called by the
post-commit ship loop — same as existing drift checks.

## Out of scope

- Automatically updating anchors — this is a detection-only mechanism. Narrowing
  or widening anchors requires human judgment.
- Detecting semantic contradiction in new files (e.g., "this new file actually
  violates INV-3") — that's the T2 LLM judge's role.
- Anchor scope drift for deleted files — already covered by subtractive
  drift (cited-file-DELETED).
