# Edit-Scope Freeze for Parallel Fan-Out (Phase 3)

**Date:** 2026-08-10
**Type:** Design / spec
**Roadmap:** Phase 3 of `docs/roadmaps/2026-08-01-drift-prevention-roadmap.md` (C+D spine — completes the **D** half)
**Builds on:** the PreToolUse hook machinery + per-session state pattern used by `kb-recall-gate.sh` / `kb-guard.sh`.
**Origin:** gstack's `/freeze` (edit-scope locking), adapted to speccraft's hook model.
**Status:** approved design → ready for writing-plans

---

## 1. Problem

The case-study drift came from **parallel development** — several agents editing at once, each free to touch anything. Phase 2 stops an agent from *cloning* a seam (it surfaces "use X, avoid Y") and from *guessing* on uncovered risk paths. But it does nothing to stop an agent from **wandering out of its task's lane** — a "build the crypto feature" agent silently modifying the India track-record surface, or two parallel agents stomping the same shared file. Phase 3 adds **blast-radius containment**: when you fan out agents, each is confined to an assigned lane, and out-of-lane edits are hard-denied.

## 2. What exists (reuse)

- **PreToolUse deny hooks** (`session-kit/settings.json`, matcher `Edit|Write|MultiEdit`): `kb-guard.sh` (denies KB-lane writes), `kb-recall-gate.sh` (denies ratified-governed / no-coverage-on-risk edits). Each reads the tool_input JSON, extracts the file path and `session_id` (`SID`), and denies via `{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:…}}`.
- **Per-session state** lives in `$TMPDIR/speccraft-*-$SID` files (e.g. the recall dedup cache). Hooks resolve forge via `FORGE="${KBFORGE_HOME:-$HOME/.speccraft/kb-forge}"` and the KB via `KB=$ROOT/.speccraft`.
- **SessionStart hook** (`kb-briefing.sh`) already runs once per session.

Freeze is a **new concept** (no existing freeze/scope code) built entirely on these primitives.

## 3. Goals / non-goals

**Goals**
- Confine each fanned-out agent to an orchestrator-assigned set of paths; **hard-deny** edits outside it.
- Make widening a **coordination decision** (orchestrator-only) — an agent can escalate but never self-widen.
- Zero friction when unused: a session with no assigned lane behaves exactly as today.

**Non-goals**
- Read restrictions (freeze gates edits only).
- Inter-agent overlap detection (the orchestrator assigns non-overlapping lanes; the hook enforces each agent's own boundary).
- KB-lane protection (already `kb-guard`'s job).
- A user-facing `/unfreeze` that an agent can self-invoke (would defeat containment).

## 4. Design

### 4.1 Scope assignment (controller → agent, at launch)
The orchestrator passes the subagent's lane as an environment variable at launch:
```
SPECCRAFT_FREEZE="backend/worker/crypto backend/app/services/crypto"
```
Space-separated, repo-relative **path prefixes**. The orchestrator assigns non-overlapping lanes when fanning out.

### 4.2 Materialize (SessionStart)
A SessionStart step (`kb-freeze-init.sh`, or folded into `kb-briefing.sh`) reads `SPECCRAFT_FREEZE`; if set, it writes the lanes (one prefix per line) to the session-keyed file:
```
$TMPDIR/speccraft-freeze-$SID
```
(The `SID` is available at SessionStart via the hook input.) If `SPECCRAFT_FREEZE` is unset/empty, no file is written → the session is **unfrozen**. The briefing prints the active lane when frozen (`🔒 edit lane: backend/worker/crypto …`).

### 4.3 Enforce (PreToolUse `kb-freeze.sh`)
Matcher `Edit|Write|MultiEdit`. For each edit:
1. Read `SID` and the target `file_path` from the tool_input JSON (as the other gate hooks do); resolve `REL` = repo-relative path.
2. If `$TMPDIR/speccraft-freeze-$SID` does **not** exist → `exit 0` (unfrozen — allow).
3. If it exists, `REL` is **in-lane** iff, for some prefix `p` in the file, `REL == p` **or** `REL` starts with `p + "/"` (proper directory boundary — so lane `.../crypto` does NOT match `.../crypto_old.py` or `.../cryptozoology/`).
4. In-lane → `exit 0` (allow). Out-of-lane → **deny**:
   > `RECALL/FREEZE GATE — <REL> is outside your assigned edit lane. Your lane: <lanes>. This edit was not applied. Do NOT work around it: widening the lane is an orchestrator/coordination decision, not a solo edit. Surface to the orchestrator that you need <REL>, or confirm it's out of scope for your task.`

Edits to `.speccraft/` are left to `kb-guard` (don't double-gate). The freeze hook is registered **before** `kb-recall-gate.sh` in `settings.json` (check the lane before the seam); any deny stops the edit.

### 4.4 Widening / lifecycle (orchestrator-owned)
- The orchestrator can widen a running agent's lane by rewriting `$TMPDIR/speccraft-freeze-$SID` (a small helper `kb-freeze.sh --set "<paths>" [--sid <sid>]` writes it; without `--sid` it targets the current session).
- The freeze file is ephemeral (`$TMPDIR`, per session) — it disappears when the session ends / TMPDIR is cleared; no explicit teardown needed. The agent has no self-unfreeze path.

### 4.5 Docs
- `session-kit/skills/speccraft-freeze/SKILL.md` (+ codex/opencode mirrors) — an **orchestrator** reference: how to assign a lane (`SPECCRAFT_FREEZE` at fan-out), that agents escalate-not-self-widen, how to widen (`--set`). Brief agent-facing note: a freeze denial means surface-to-orchestrator.
- `kb-briefing.sh` — show the active lane when the session is frozen.
- `SPEC.md` — document the freeze mechanism + the env var.

## 5. Testing

Bash, `session-kit/evals/test-freeze.sh`, wired into `self-test.sh`:
1. **Unfrozen allows** — no freeze file → hook exits 0 for any path.
2. **In-lane allows** — freeze `backend/worker/crypto`; edit `backend/worker/crypto/x.py` → allow.
3. **Out-of-lane denies** — same freeze; edit `backend/app/billing.py` → deny (message names the lane).
4. **Prefix boundary** — freeze `backend/worker/crypto`; edit `backend/worker/crypto_old.py` and `backend/worker/cryptozoology/y.py` → **deny** (not accidentally in-lane).
5. **Multiple lanes** — freeze two prefixes; an edit under either → allow; under neither → deny.
6. **Materialize** — SessionStart with `SPECCRAFT_FREEZE` set writes the `$TMPDIR/speccraft-freeze-$SID` file with the right lanes; unset → no file.
7. **`--set` widen** — after `kb-freeze.sh --set` adds a lane, a previously-denied path is allowed.
8. **`.speccraft/` not double-gated** — freeze doesn't deny KB-lane paths (kb-guard's job); pick a path form that proves freeze ignores `.speccraft/`.

## 6. Files touched

| File | Change |
|---|---|
| `session-kit/hooks/kb-freeze.sh` | **Create** — PreToolUse: deny out-of-lane edits per the session's freeze file; `--set` to write/widen |
| `session-kit/hooks/kb-freeze-init.sh` (or a few lines in `kb-briefing.sh`) | **Create/Modify** — SessionStart: materialize `SPECCRAFT_FREEZE` → `$TMPDIR/speccraft-freeze-$SID` |
| `session-kit/settings.json` | Register `kb-freeze.sh` (PreToolUse `Edit\|Write\|MultiEdit`, before `kb-recall-gate.sh`) + the SessionStart materialize if a new hook |
| `session-kit/hooks/kb-briefing.sh` | Show active lane when frozen |
| `session-kit/skills/speccraft-freeze/SKILL.md` + codex/opencode mirrors | **Create** — orchestrator lane-assignment reference |
| `SPEC.md` | Document freeze + `SPECCRAFT_FREEZE` |
| `session-kit/evals/test-freeze.sh` + `self-test.sh` | The suite + wire-in |

## 7. Risk / rollback
- Blast radius: speccraft session-kit only (a new hook + registration). No product code, no KB schema change.
- **Fully dormant unless `SPECCRAFT_FREEZE` is set** — existing solo/sequential sessions are unaffected; can't wedge normal work.
- Fail-open by construction: no freeze file → allow. A malformed freeze file should also fail open (allow) rather than block all edits — spec the hook to treat an unparseable/empty file as unfrozen.
- Rollback: unregister the hook in `settings.json`; the scripts are inert if not wired.

## 8. Out of scope → next
- **Phase 4** — executable invariants (+ the two steal-now checks: Alembic-metadata guard, raw-tier grep-ban).
- **Phase 5** — single-source cure: `dup0` fails CI on a new clone of a ratified seam (consumes Phase 2's `seam`/`avoid_pattern`). With Phase 3, the **D half (write-time prevention) is complete**: don't clone (Phase 2), don't wander (Phase 3).
