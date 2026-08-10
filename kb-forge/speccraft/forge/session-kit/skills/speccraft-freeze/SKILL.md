---
name: speccraft-freeze
description: Use when fanning out parallel sub-agents/orchestrated tasks and you need to confine each agent's edits to its own slice of the repo — assigns and enforces a per-session edit lane. Invoke at agent-launch time (orchestrator) or mid-session to widen a lane.
---

# speccraft-freeze — confine a fanned-out agent to its lane

1. Before launching a sub-agent whose edits must stay inside a slice of the
   repo, set `SPECCRAFT_FREEZE="<space-separated repo-relative path prefixes>"`
   in that agent's launch environment. Example:
   `SPECCRAFT_FREEZE="backend/worker/crypto backend/app/services/crypto"`.
2. On SessionStart, `kb-briefing.sh` materializes `SPECCRAFT_FREEZE` into that
   session's lane file (`${TMPDIR:-/tmp}/speccraft-freeze-<session-id>`) and
   the briefing shows `🔒 edit lane (this session is frozen): <lanes>` when
   frozen. From then on, `kb-freeze.sh` (PreToolUse) hard-denies any
   Edit/Write/MultiEdit outside the lane — this is enforced, not advisory,
   under Claude Code.
3. In-lane boundary rule: a target path is in-lane iff it equals a lane
   prefix exactly, or starts with `<prefix>/`. Prefixes are directory or
   file scoped; there is no globbing. Assign **non-overlapping** lanes
   across parallel agents so two agents can never contend for the same
   file.
4. To widen a *running* session's lane (e.g. the orchestrator decides the
   agent legitimately needs a path outside its original assignment), run:
   `kb-freeze.sh --set --sid <session-id> <paths…>`
   (or `--set` alone with `SPECCRAFT_SID` exported). This overwrites the
   lane file with the new path list — pass the full desired lane, not just
   the addition.
5. The freeze is **dormant unless assigned**: no `SPECCRAFT_FREEZE` env and
   no lane file for the session means `kb-freeze.sh` fails open and allows
   all edits, exactly like an unfrozen session. Freezing is opt-in, per
   session, orchestrator-controlled.
6. Agent-facing note: if your edit is denied by the freeze gate, that is
   not a bug to route around. Do not retarget the edit to a workaround
   path, do not attempt broader edits to "fix" the block, and do not
   invent your own copy of the file inside your lane. Surface it to the
   orchestrator plainly — "I need `<path>`, which is outside my lane" —
   and let the orchestrator decide whether to widen your lane (step 4) or
   confirm the path is out of scope for your task.
