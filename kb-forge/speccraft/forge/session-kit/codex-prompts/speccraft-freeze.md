---
description: Confine a fanned-out agent's edits to an assigned lane of the repo (.speccraft KB repos). Orchestrator sets the lane at launch; agents self-apply the boundary.
argument-hint: <space-separated repo-relative path prefixes for the lane>
---

Lane for this session: $ARGUMENTS

# speccraft-freeze — confine a fanned-out agent to its lane

(Applies to repos with the .speccraft KB layout, e.g. stocktickerapp. The
canonical procedure also lives at `.agents/skills/speccraft-freeze/SKILL.md`.)

1. Before launching a sub-agent whose edits must stay inside a slice of the
   repo, the orchestrator sets `SPECCRAFT_FREEZE="<space-separated
   repo-relative path prefixes>"` in that agent's launch environment.
   Example: `SPECCRAFT_FREEZE="backend/worker/crypto
   backend/app/services/crypto"`.
2. Under Claude Code, SessionStart materializes `SPECCRAFT_FREEZE` into a
   session lane file and an automatic PreToolUse hook (`kb-freeze.sh`)
   hard-denies any Edit/Write outside the lane. **Codex sessions don't get
   that hook** — there is no automatic enforcement here. Treat the lane as
   binding anyway and self-apply it: before every edit, check the target
   path against your assigned lane and stop if it's outside.
3. In-lane boundary rule: a target path is in-lane iff it equals a lane
   prefix exactly, or starts with `<prefix>/`. No globbing. Lanes assigned
   to parallel agents should be non-overlapping so two agents never
   contend for the same file.
4. To widen a *running* session's lane (orchestrator decision), the
   canonical mechanism is:
   `kb-freeze.sh --set --sid <session-id> <paths…>`
   Under Codex, the orchestrator can instead just restate the new lane in
   this prompt's `$ARGUMENTS` for a fresh invocation — pass the full
   desired lane, not just the addition.
5. The freeze is **dormant unless assigned**: no `$ARGUMENTS`/no lane means
   there is no boundary to enforce — proceed normally.
6. Agent-facing note: if a target path falls outside your lane, that is not
   a bug to route around. Do not retarget the edit to a workaround path, do
   not attempt broader edits to "fix" it, and do not invent your own copy
   of the file inside your lane. Surface it to the orchestrator plainly —
   "I need `<path>`, which is outside my lane" — and let the orchestrator
   decide whether to widen your lane (step 4) or confirm the path is out
   of scope for your task.
