# Harness-Agnostic Recall Proxy — Cross-Harness Telemetry via Git Hooks

**Date:** 2026-07-25
**Status:** Draft for review

## Problem

T1 compliance telemetry draws session-level events (`session_start`,
`recall_ran`, `guard_block`) from Claude Code hooks. OpenCode and Codex
sessions don't run these hooks. Commit-side events (`ratify_used`,
`guard_block` from git hooks) are harness-independent, but the recall rate
denominator is Claude Code only — the rate is unrepresentative.

The evals design documents this blind spot but does not mitigate it.

## Solution

Two parts:

**A. Document the blind spot** in `KB-STATUS.md` and telemetry reports.
The recall rate is labeled *"Claude Code recall rate"* — it only measures
what it can measure.

**B. Add a harness-agnostic recall proxy** via the pre-commit hook. Before
every code commit, check which staged files have KB facts anchored to them.
Log `recall_eligible` — a count of files that *should* have had recall run.
Compare against actual Claude Code `recall_ran` events over the same window
to estimate the blind-sessions fraction.

## Design — Part B

### Pre-commit hook addition

After the existing lane guard and stale check, before allowing the commit:

```
1. Collect staged file paths (git diff --cached --name-only)
2. Filter out paths under .speccraft/
3. For each staged file, call recall.py --config .speccraft/kbforge.yaml --files <path>
   and check if output is non-empty
4. Count: N = number of files with KB coverage
5. If N > 0, log telemetry event:
   recall_eligible  { "n_files": N, "n_with_coverage": M, "session_id": "" }
```

The `session_id` is empty because git hooks don't have session context. This
is intentional — the event is explicitly harness-agnostic.

### Telemetry report extension

`telemetry-report.sh` gains a new computed metric:

```
Recall coverage ratio:
  Claude Code recall_ran events:  47  (from session hooks)
  Git-hook recall_eligible files: 183  (from pre-commit)
  Estimated blind rate:           74%  (1 - 47/183)

  Note: blind rate includes OpenCode, Codex, and any sessions where the
  Claude Code hook didn't fire. Not all 183 files necessarily needed recall
  — recall_eligible is a proxy, not ground truth.
```

### Reporting in KB-STATUS.md

The Health block in `KB-STATUS.md` gains a line:

```
- Claude Code recall rate: 71% (47/66 sessions)
- Recall proxy (all harnesses): 47 recall_ran events vs 183 recall_eligible files
- Estimated blind-session fraction: 74%
```

### Caveats (documented in the output)

- `recall_eligible` is a proxy — it counts files with KB coverage at commit
  time, not sessions where recall was actually needed.
- A single commit touching 10 covered files counts as 10 `recall_eligible`
  events. A `recall_ran` event counts once per file per session. These are
  different units — the ratio is directional, not precise.
- The proxy cannot distinguish "recall wasn't run" from "recall ran outside
  Claude Code hooks" (e.g., manual `python3 recall.py` call).

## Implementation plan

1. Add recall_eligible logging to `kb-forge/session-kit/pre-commit`:
   - Call `python3 recall.py --config .speccraft/kbforge.yaml --files <path>`
     for each staged file (batch: pass all files in one call)
   - Log event via `kb_telemetry recall_eligible <n_with_coverage>/<n_files>`
2. Extend `telemetry-report.sh` to compute the proxy ratio
3. Add the proxy line to the Health block in `kb-status.sh`
4. Label existing recall rate as "Claude Code recall rate" in all output

## Out of scope

- OpenCode/Codex hook parity — building native hooks for each harness is
  deferred. The proxy is a pragmatic substitute.
- Per-session attribution — the proxy is aggregate, not per-session. This is
  intentional.
