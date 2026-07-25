# Speccraft Design Review

**Reviewer:** Google Principal Engineer (impersonation)
**Date:** 2026-07-25
**Scope:** kb-forge / speccraft system — trust-graded KB, five procedures, session hooks, evals design (T1–T3)

---

## What's good

- **Lane guard** (pre-commit + PreToolUse hook) — a technical control enforcing policy, not just hoping the agent follows instructions. Dual-layer (edit-time + commit-time) is the right pattern.
- **Trust grading** — five explicit levels from `ratified` to `challenged`. Acknowledges knowledge exists on a spectrum. Explicit adjudication path.
- **Pin-on-code-commit** — the KB always self-describes what state of the world it understands. Prevents confusion about staleness.
- **Evals design** — T1–T3 pyramid is well-structured. Mechanical checks (anchor rot, staleness) are deterministic. LLM judge flags but never edits — same discipline as the KB.
- **Prefix anchor matching** — `recall.py` directory-based anchors sweep nested paths; coverage doesn't shrink as the codebase evolves within anchored subtrees.

---

## Weaknesses

### 1. Founder bottleneck (existential risk)

The entire ratchet stops if the founder stops ratifying. Ratification is pure overhead for the founder. The queue grows without bound. Over time the KB becomes an unratified pile of observations — indistinguishable from no KB at all.

T1 tracks queue drain rate but has **no automatic mitigation**. No auto-demote of stale items, no degraded-trust self-declaration, no session warning.

### 2. Self-policing agent problem

The workflow requires agents to self-invoke `speccraft-recall`, `speccraft-decide`, `speccraft-diverge`. There is no mechanism to detect that an agent *should have* run recall but didn't. The lane guard only blocks prohibited writes — it can't tell if the agent skipped the mandatory pre-read.

T1 tracks recall rate (via PostToolUse hook). But this only works for Claude Code — OpenCode and Codex sessions are invisible to T1 (documented blind spot). And recall rate tells you *whether* recall ran, not whether recall output was actually heeded.

### 3. Semantic drift vs mechanical drift

`drift.py` checks whether cited lines changed. This catches one class of decay but misses: a ratified fact can become false without any code change to its anchor file (e.g., a new dependency logs PII while INV-3 says "never log PII"; no line changed, but the invariant is violated).

T2's LLM judge is *designed* for this — but it's opt-in, capped at 20 samples per run, and only runs on demand. It's not a continuous guard.

### 4. External dependency black hole

The KB is scoped to a single repo. Products depend on libraries, APIs, services that evolve independently. A Stripe API change can invalidate ratified invariants without touching a line of product code. The system has no mechanism to track external drift.

### 5. Cross-harness telemetry blind spot

OpenCode and Codex sessions don't run Claude Code session hooks. T1's `session_start`, `recall_ran`, `guard_block` events are Claude Code only. Commit-side events (`ratify_used`, `guard_block`) from git hooks are harness-independent, but the denominator for recall rates is incomplete. Documented but unresolved.

---

## Not flagged (addressed or non-issues)

- **Coverage shrinkage** — Not a problem. Prefix anchor matching means `backend/` anchors sweep `backend/anything/nested/deeply`. New files in anchored subtrees are covered. Entirely new subtrees surface via "NO KB COVERAGE" — a per-repo config choice via `risk_paths`.
- **Anchor rot** — Addressed by T2 mechanical checks (dead anchor detection).
- **Semantic contradiction detection** — Addressed by T2 LLM judge (capped, opt-in).
- **Behavioral validation** — Addressed by T3 behavioral suite (per-release, manual).
