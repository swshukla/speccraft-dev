# Anchor Scope Drift — Detect New Files Under Existing KB Anchors

**Date:** 2026-07-25
**Status:** Draft for review (rev 2 — normative-only queueing, rename
coverage, judge targeting)

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

### Where this sits relative to session recall

Session-side mechanisms already cover part of this: capture-on-contact
injects anchored facts when an agent Edits/Writes a new file, and the recall
gate (spec: recall-gate) bounces blind edits on normative-anchored paths.
Anchor scope drift is the **harness-independent backstop** for everything
those can't see: files created via Bash, by humans, or in OpenCode/Codex
sessions (no hooks), and sessions where injected facts were ignored. Like
the commit-side guards, it works from git history alone — the founder-facing
report is the primary artifact, not a supplement.

## Solution

Add a third drift direction to `drift.py`: **anchor scope drift.** After
computing subtractive and additive drift, check whether any files added since
the pin fall under existing KB facts' anchor scopes. If so, report them as
coverage candidates that the KB may not account for.

## Design

### Detection

```python
1. Collect added files since pin:
   git diff --name-only --no-renames --diff-filter=A pin..HEAD -- . ':(exclude).speccraft'

   --no-renames is load-bearing: a file MOVED into an anchored scope
   (backend/experiments/foo.py → backend/payments/charge.py) is exactly the
   event to catch, but with rename detection git reports it as R and
   --diff-filter=A misses it. --no-renames decomposes moves into delete+add;
   the add side gets scope-checked here, the delete side is already
   subtractive drift's job.

2. For each KB fact (normative/, inferred/, decisions/) that has anchors:
   - For each path anchor:
     - If anchor is a directory prefix (ends with / or maps to a dir):
       - Check if any added file starts with the anchor
     - If anchor is a specific file:
       - No scope check needed (deletion is covered by subtractive drift)

3. Report matches, deepest anchor first (see Signal ordering below)
```

### Signal ordering and caps

Signal strength is inversely proportional to anchor breadth: a new file
under `backend/payments/` is a pointed finding; a new file under `backend/`
is close to a tautology. Broad anchors are NOT suppressed (invariants are
often deliberately broad), but the report:

- sorts anchors deepest-first (most path segments first), so the pointed
  findings lead
- caps the per-anchor file list at `ADD_CAP` (reuse the existing constant,
  drift.py:51), printing the overflow count — same no-silent-truncation
  discipline as the additive section

### Output format

Added after the existing ADDITIVE and DEPENDENCY sections. Findings only —
anchors with no new files in scope print nothing.

```
ANCHOR SCOPE drift — new files added under anchored paths since pin:

  kb/normative/01-invariants.md  (anchor: backend/payments/):
    + backend/payments/refund-worker.py

  kb/inferred/06-integrations.md  (anchor: backend/):
    + backend/workers/notify-webhook.py
    + backend/tasks/healthcheck.py
```

### Queueing — trust-graded (--queue flag)

Only **normative-anchored** findings become queue items; inferred/decision
findings stay report-only. Rationale: a new file under a ratified
invariant's scope is a genuine "verify the invariant still holds" task for
the founder; a new file under an inferred fact's scope is context, not
work. Queueing everything would feed the founder-bottleneck queue
(critique #1) with low-grade items. One item per (fact, anchor) pair:

```
- [ ] anchor scope drift: `kb/normative/01-invariants.md` — new file(s) in
  scope of `backend/payments/`: `backend/payments/refund-worker.py`. Verify
  whether the fact applies to these new files or needs its anchor narrowed.
```

### Judge targeting (connects to critique #3)

Anchor-scope findings are the highest-yield targets for the T2 LLM judge:
"new file X entered the scope of ratified fact Y" is a ready-made, focused
judge question, and the judge's 20-sample cap makes prioritization the
binding constraint. Add a machine-readable emission:

```
drift.py --judge-targets  →  one line per normative-anchored finding:
  <kb_file>\t<anchor>\t<added_file>
```

`kb-audit.sh` consumes this to seed its sample set before falling back to
random sampling. This turns anchor scope drift from pure detection into the
targeting system for the semantic guard — the capped judge budget spends
itself where violations are most likely.

### Implementation

This is purely mechanical (git diff + prefix matching). No LLM, no new config.
The anchor prefix matching reuses the same logic as `recall.py` (line 79).

Add a new function `anchor_scope_drift(kbroot, repo, pin, head)` that:

- Calls `git diff --name-only --no-renames --diff-filter=A pin..HEAD -- . ':(exclude).speccraft'`
- Walks KB files (same `collect()` pattern as `recall.py`), tracking each
  fact's lane (normative / inferred / decisions) for queue + judge tiering
- For each fact's path anchors, checks against the added set
- Returns a dict: `{kb_file: [(anchor, lane, [added_file, ...]), ...]}`

### Report-only contract

This is intentionally a report-only finding. It doesn't block anything. The
founder sees it and decides whether to narrow anchors or add new facts. Over
time, projects develop a sense of which scopes need tightening — the output
trains the founder's judgment. (The ship loop re-pins on every commit, so
the pin→HEAD window is typically one commit: findings arrive in small
increments, not avalanches. Repos without a regular ship loop get the
ADD_CAP protection above.)

## Telemetry

No new telemetry. This runs as part of `drift.py` which is called by the
post-commit ship loop — same as existing drift checks.

## Out of scope

- Automatically updating anchors — this is a detection-only mechanism. Narrowing
  or widening anchors requires human judgment.
- Detecting semantic contradiction in new files (e.g., "this new file actually
  violates INV-3") — that's the T2 LLM judge's role; this spec feeds the
  judge its targets (see Judge targeting) but never renders the verdict.
- Anchor scope drift for deleted files — already covered by subtractive
  drift (cited-file-DELETED).
