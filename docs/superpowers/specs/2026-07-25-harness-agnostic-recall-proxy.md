# Harness-Agnostic Recall Telemetry — Direct Measurement + Commit-Side Bound

**Date:** 2026-07-25
**Status:** Draft for review (rev 2 — adds Part C direct instrumentation;
reframes the proxy as an upper bound)

## Problem

T1 compliance telemetry draws session-level events (`session_start`,
`recall_ran`, `guard_block`) from Claude Code hooks. OpenCode and Codex
sessions don't run these hooks. Commit-side events (`ratify_used`,
`guard_block` from git hooks) are harness-independent, but the recall rate
denominator is Claude Code only — the rate is unrepresentative.

The evals design documents this blind spot but does not mitigate it.

## Solution

Three parts, in value order:

**C. Instrument recall.py directly (new in rev 2 — highest value).**
recall.py owns all `recall_ran` logging, tagged by harness. The
OpenCode/Codex prompt ports already instruct agents to run
`python3 recall.py ...` — those invocations become directly measured, not
estimated. The untracked remainder shrinks to "sessions that never ran
recall at all."

**B. Commit-side eligibility bound.** The pre-commit hook counts staged
files with KB coverage (`recall_eligible`). Compared against tracked
`recall_ran` events over a defined window, this yields an **upper bound on
the untracked fraction** — a bound, never a point estimate (see Framing).

**A. Honest labeling.** Every surfaced rate names what it measures
("tracked recall rate", "upper bound"), with the measurement window
printed alongside.

## Design — Part C: recall.py self-instrumentation

### Logging ownership flip

Today `kb-recall-post.sh:24` calls recall.py and then logs `recall_ran`
itself. If recall.py also self-logged, every hook invocation would
double-count. Resolution: **recall.py owns the `recall_ran` event**;
callers identify themselves:

```
recall.py --harness <name>    name ∈ claude-hook | claude-skill |
                                     opencode | codex | cli (default)
```

- `kb-recall-post.sh` (and the spec-2 gate hook) pass `--harness
  claude-hook` and STOP logging `recall_ran` themselves. They keep logging
  their hook-specific events (`recall_empty`, `recall_gate_block`).
- The `speccraft-recall` skill and the OpenCode/Codex prompt ports are
  updated to pass their harness name. A bare `python3 recall.py` call logs
  as `cli` — still counted, just unattributed.

recall.py appends the same JSONL schema telemetry-lib.sh writes (path,
rotation, and size-guard rules match telemetry-lib; implement in python
rather than shelling out). Session id is included when available
(`$CLAUDE_SESSION_ID` / hook stdin) and empty otherwise — cross-harness
events aggregate rather than attribute per-session. Telemetry stays
fail-open: logging errors never break recall output.

### What this buys

A per-harness recall breakdown in `telemetry-report.sh`:

```
recall_ran by harness (last 30d):
  claude-hook   47
  claude-skill  12
  opencode       9
  codex          3
  cli            5
```

This directly answers critique #5's numerator problem for every harness
whose prompts are followed. What it cannot see: sessions that never ran
recall at all — that residual is what Part B bounds.

## Design — Part B: commit-side eligibility bound

### Pre-commit hook addition

After the existing lane guard and stale check, before allowing the commit:

```
1. Collect staged file paths (git diff --cached --name-only)
2. Filter out paths under .speccraft/
3. Batch-check coverage: one recall.py call with all staged files, using
   the per-file coverage-check mode added by the recall-gate spec (reuse
   that flag — do NOT parse recall's human-readable output)
4. Count: M = files with KB coverage, N = staged files checked
5. If M > 0, log: recall_eligible { "n_files": N, "n_with_coverage": M }
```

Empty session id — git hooks have no session context; the event is
explicitly harness-agnostic.

### Framing — why this is a bound, not a rate

Two known distortions, both inflating the same direction:

- **Unit mismatch:** `recall_ran` fires once per file per *session*;
  `recall_eligible` once per file per *commit*. One compliant session
  landing a file across three commits scores 1 vs 3.
- **Human commits count:** the founder hand-editing covered files with no
  agent involved inflates the denominator. The metric measures
  "coverage-touching commits not attributable to a tracked recall,"
  which includes legitimate human work.

Because both errors overestimate, the honest claim is an **upper bound on
the untracked fraction** — and that is the only claim any output surface
makes. No output may present it as a blind-session rate or point estimate.

### Measurement window

All ratios are computed over a **rolling 30-day window**, printed in every
output surface. Without a defined window the ratio drifts meaninglessly as
history accumulates.

### Telemetry report extension

```
Recall telemetry (rolling 30d):
  Tracked recall_ran events:        76   (by harness: claude-hook 47,
                                          claude-skill 12, opencode 9,
                                          codex 3, cli 5)
  Commit-side eligible file-touches: 183
  Untracked fraction:               ≤ 58%  (upper bound — see caveats)

  Caveats: eligible counts are per-commit and include human commits;
  tracked counts are per-session. The bound only tightens with better
  instrumentation; it never measures blindness directly.
```

### Reporting in KB-STATUS.md

The Health block gains raw counts with the bound label — no headline
percentage:

```
- Tracked recalls (30d): 76 across 5 harness sources
- Eligible file-touches at commit (30d): 183
- Untracked fraction: ≤ 58% (upper bound; includes human commits)
```

## Design — Part A: labeling

- Rename "recall rate" to **"tracked recall rate"** in all output
  (`telemetry-report.sh`, `kb-status.sh`, KB-STATUS.md health block).
- Every rate/bound prints its window (30d) and its source
  (session hooks / recall.py / git hooks).

## Implementation plan

1. **Part C first (smallest, highest value):**
   - Add `--harness` flag + JSONL self-logging to recall.py
   - Update `kb-recall-post.sh` (and spec-2 gate hook): pass
     `--harness claude-hook`, remove their own `recall_ran` logging
   - Update `speccraft-recall` skill + OpenCode/Codex prompt ports to pass
     their harness names
2. **Part B:**
   - Add batch coverage check to `kb-forge/session-kit/pre-commit` using
     the recall-gate coverage flag; log `recall_eligible`
3. **Parts A + reporting:**
   - `telemetry-report.sh`: per-harness breakdown, 30d window, bound
     computation with caveats block
   - `kb-status.sh`: raw counts + bound line in Health block
   - Relabel existing rate as "tracked recall rate"

## What remains honestly unsolved

The denominator for other harnesses — sessions that never ran recall and
never committed — is unknowable without native hooks in those harnesses.
Part C measures compliant sessions directly; Part B bounds the rest at
commit time; the gap between them is irreducible from this side. It is,
however, a much smaller gap than pre-rev-2: the numerator is now solved
for every harness that follows the prompts.

## Out of scope

- Native OpenCode plugin / Codex hook parity — deferred. OpenCode's plugin
  system could emit the same telemetry events natively; that closes the
  session-count denominator and is the eventual fix. The proxy + direct
  instrumentation are the pragmatic interim.
- Per-session attribution for cross-harness events — recall.py logs
  aggregate events without session ids outside Claude Code. Intentional.
