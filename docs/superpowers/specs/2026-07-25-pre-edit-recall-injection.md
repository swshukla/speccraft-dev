# Recall Gate — Deny-Once Enforcement for Normative-Anchored Files

**Date:** 2026-07-25
**Status:** Draft for review (rev 2 — restructured around deny-once; supersedes
"move recall from PostToolUse to PreToolUse")

## Problem

Recall runs *after* the edit (`kb-recall-post.sh` fires on PostToolUse). The
agent writes code, then sees the KB facts governing that file. To honor the
facts, the agent must self-correct on a subsequent turn — unreliable and
wasteful. Compliance with the `speccraft-recall` procedure is voluntary: no
layer checks whether recall actually ran before code landed (critique #2, the
self-policing agent problem).

Additionally, when recall finds nothing, the agent receives no signal. It
can't distinguish "recall wasn't run" from "recall ran and found nothing."
The agent may wrongly assume no KB facts exist.

### Why rev 1 (Pre-injection) was abandoned

Rev 1 proposed moving recall injection from PostToolUse to PreToolUse so the
agent "sees constraints before writing." This doesn't work, for a timing
reason inherent to the harness: **a PreToolUse hook fires after the model has
already authored the complete edit** — the hook's stdin contains the finished
`new_string`. And PreToolUse `additionalContext` is delivered next to the
tool result, i.e., read by the model on the turn *after* the edit executes —
the same effective timing as the existing PostToolUse hook. No injection
channel, Pre or Post, can influence code that is authored in the same model
turn as the tool call.

The only hook mechanism that gets facts in front of the agent *before the
code that lands is generated* is denial: bounce the blind first edit,
attach the facts, and let the agent re-author with the facts in context.

## Solution

Two cooperating layers — the skill makes recall-first easy; the hook makes
skipping it impossible to land on files that matter most:

1. **Skill = fast path.** The `speccraft-recall` procedure remains the
   intended workflow: recall while planning, write informed code, no
   enforcement friction. The skill pre-clears the gate by writing the same
   dedup cache the hook checks (see below), so a compliant agent never sees
   a denial.

2. **Deny-once gate (new, PreToolUse) = enforcement floor**, applied only
   where a wrong first edit is most expensive: files anchored by
   **normative facts** (ratified invariants). First touch of such a file
   with no prior recall → `permissionDecision: "deny"` with the recall
   output embedded in the reason. The agent re-issues the edit with the
   facts in context; the retry passes.

3. **Passive tier (existing PostToolUse hook, unchanged)** for files with
   only inferred/decision coverage: capture-on-contact injection as today.

4. **No-coverage disambiguation (new, in the PostToolUse hook):** when
   recall returns nothing, inject an explicit message instead of silence,
   conditioned on `risk_paths`.

The tier boundary is trust-graded, matching the system's own philosophy:
ratified truth gets a technical control; graded observations get advisory
injection.

## Design

### Tier decision

`recall.py` output already carries per-fact provenance/status. The gate needs
one bit: *does any normative-lane fact anchor this file?* Add a
`--lanes normative` filter (or `--gate-check` flag returning exit status) to
`recall.py` so the hook can ask cheaply. Files whose recall output contains
no normative facts never trigger denial.

### New hook: `kb-recall-gate.sh` (PreToolUse, matcher `Edit|Write|MultiEdit`)

```
1. Read tool_input.file_path + session_id from stdin
2. Path under .speccraft/ → exit 0 (KB files never gated; lane guard owns them)
3. Compute repo-relative path
4. Check dedup cache (/tmp/speccraft-recall-seen-$SID):
   - Already seen → exit 0 (gate passed earlier, or skill pre-cleared it)
5. Run recall.py gate check for normative facts on <rel-path>
   - No normative facts → exit 0 (passive tier handles it post-edit)
6. Normative facts found → append path to dedup cache, log telemetry
   recall_gate_block, and return:
   {
     "hookSpecificOutput": {
       "hookEventName": "PreToolUse",
       "permissionDecision": "deny",
       "permissionDecisionReason": "RECALL GATE — <rel-path> is governed by
         ratified KB facts you have not yet seen:\n<recall output>\n
         This edit was NOT applied. Re-issue the same edit now, adjusted
         where needed to honor the facts above. Do not abandon the edit;
         do not route around this file via Bash."
     }
   }
```

The deny fires **at most once per file per session** — step 6 writes the
cache, so the agent's retry passes step 4. Cost: one discarded authoring
pass per normative-anchored file per session, paid only when the agent did
not recall first.

**Deny-reason wording is load-bearing.** It must instruct the agent to
re-issue the edit (not abandon it) and must carry the full facts (it is the
injection channel). This wording is the main thing to validate empirically
(see Verification).

### Skill pre-clearing

`speccraft-recall` (skill/procedure) gains one step: after running recall for
target files, append each repo-relative path to
`/tmp/speccraft-recall-seen-$SID` (the session id is available to the skill's
shell via `$CLAUDE_SESSION_ID`; if unavailable, skip — the gate then fires
once, harmlessly, with facts the agent has already seen). Compliant agents
never hit the gate; the gate-block rate becomes a direct measure of skill
non-compliance (closes the "ran vs heeded" telemetry gap for normative files).

### Changes to `kb-recall-post.sh` (passive tier + disambiguation)

Keep capture-on-contact exactly as today for non-normative coverage, plus a
no-coverage branch:

```
If recall output is empty:
  - Read risk_paths from kbforge.yaml (grep '^risk_paths:')
  - Path matches → inject: "No KB coverage for <path> — this path is
    risk-tagged; proceed with caution."
  - No match → inject one line: "No KB coverage for <path>."
  - Log telemetry: recall_empty
```

The plain variant stays to one line — in a wide refactor over uncovered
files this fires once per file and must not become noise.

### Hook ordering in `settings.json`

PreToolUse: `kb-guard.sh` first (lane denial), then `kb-recall-gate.sh`.
No same-file interaction exists (the guard only denies `.speccraft/` writes,
which the gate skips), but guard-first keeps lane protection unconditional.
PostToolUse: `kb-recall-post.sh` unchanged.

### Telemetry

- `recall_gate_block` — new; deny-once fired (path in payload)
- `recall_ran` / `recall_empty` — existing semantics, now with the
  no-coverage branch logging `recall_empty` explicitly
- `telemetry-report.sh` surfaces gate blocks vs recall_ran: the ratio of
  gate-enforced to voluntary recall is the compliance metric critique #2
  said was missing

## Verification plan

1. **Deny-retry behavior:** stub gate in a scratch repo; confirm the agent
   re-issues the edit after denial and the retry lands. Tune the deny-reason
   wording until re-issue is reliable. This is the go/no-go test.

   **RESULT (2026-07-25): GO — after two wording iterations.** Empirical
   findings from headless runs against a stub gate:
   - v1 (facts + "re-issue" instruction): agent paused and asked the user
     whether to apply the facts. FAIL.
   - v2 (added "do not ask for confirmation, comply silently"): agent
     classified the deny reason as a **prompt-injection attempt**, re-issued
     the edit while deliberately ignoring the facts, and reported the
     "injection" to the user. FAIL — coercive language reads as attack;
     unverifiable facts read as fabricated.
   - v3 (briefing + verifiability): PASS. Agent read the cited KB file to
     verify, re-issued honoring all facts, retry landed. Load-bearing
     elements, all three required:
     1. The SessionStart briefing pre-announces the gate ("may deny your
        first edit to a governed file — expected repo machinery").
     2. The deny reason cites the actual KB file path and invites
        verification ("If you want to verify these facts, Read ...").
     3. No coercion; explicit divergence rule: "If a fact genuinely
        conflicts with the user's explicit request, follow the user and
        note the divergence."
   Consequence for implementation: `kb-briefing.sh` gains one gate-announce
   line, and the deny reason template is fixed as v3.
2. **Cache pre-clear:** run the recall skill path first; confirm no denial.
3. **MultiEdit / Write on new files:** confirm gate behavior when the target
   file doesn't exist yet (recall on a new path returns nothing → no gate).
4. Confirm `kb-guard.sh` ordering unaffected (lane denial still fires).

## Implementation plan

1. Add normative-lane gate check to `recall.py` (flag + exit status)
2. Create `kb-forge/session-kit/hooks/kb-recall-gate.sh`
3. Add no-coverage branch to `kb-recall-post.sh`
4. Register gate hook in `session-kit/settings.json` (after kb-guard)
5. Add cache pre-clear step to the `speccraft-recall` skill files
   (Claude Code skill + OpenCode/Codex prompt ports — the cache write is
   harness-portable shell even where the gate hook isn't)
6. Telemetry: `recall_gate_block` event + report extension

## Out of scope

- **Bash-mediated writes** (`sed`, heredocs, `cat >`) bypass the
  Edit/Write/MultiEdit matcher in both tiers. The deny-reason wording
  explicitly forbids routing around the gate via Bash, but that is an
  instruction, not a control. Closing it would require a Bash-matcher
  heuristic (parse write targets from commands) — deferred.
- **UserPromptSubmit proactive injection** — scanning the user's prompt for
  file/module mentions and injecting recall before the model's first turn.
  Genuine pre-generation context but heuristic (only helps when the prompt
  names files). Complement, not replacement; possible follow-up spec.
- **Gating inferred-only files** — denial cost is not justified below the
  normative lane; passive tier covers them. Revisit if telemetry shows
  ratified-fact violations originating from inferred-anchored files.
- **OpenCode/Codex gate parity** — PreToolUse hooks are Claude Code only.
  The skill pre-clear step is portable; the enforcement floor is not.
  Cross-harness enforcement remains the commit-side guards' job.
