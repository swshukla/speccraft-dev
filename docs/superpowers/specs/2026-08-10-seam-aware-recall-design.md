# Seam-Aware Recall + Confusion Protocol (Phase 2)

**Date:** 2026-08-10
**Type:** Design / spec
**Roadmap:** Phase 2 of `docs/roadmaps/2026-08-01-drift-prevention-roadmap.md` (C+D spine — begins the **D** half)
**Builds on:** Phase 0 (two-lane queue), Phase 1 (forcing function). Reuses the existing
recall engine, hooks, and conventions pipeline.
**Status:** approved design → ready for writing-plans

---

## 1. Problem

Phases 0–1 (the **C** half) made drift converge. But nearly every discrepancy in the
SignalCue audit was a *single-source-of-truth violation introduced at write-time* — a
parallel agent cloned a pattern (Telegram send ×10, tier-gate ×3, cue-band ×2, Razorpay
×2) instead of importing the canonical seam, because it edited without knowing the seam
existed. Phase 2 (the **D** half) stops **new** clones at write-time: surface the canonical
seam when an agent touches a governed file, and make agents **stop-and-file** instead of
guess-and-clone when the KB has no coverage for a risky path.

## 2. What already exists (grounding — reuse, don't rebuild)

- **`recall.py`** matches a touched file to KB facts via frontmatter `anchors:` (bidirectional
  path-prefix + `topic:` slugs, `recall.py:101-112`), ranks by trust (`RANK`, `:30`), and
  has an exit-code gate (`--gate-check` → exit 3 on a ratified match, `:172-177`), a
  `--coverage-count`, and prints `NO KB COVERAGE …` when nothing matches (`:163-164`).
- **Hooks** (`session-kit/settings.json`): `kb-recall-gate.sh` (PreToolUse) **denies the
  first edit** to a ratified-normative-governed file once per file per session;
  `kb-recall-post.sh` (PostToolUse) injects matched facts as `additionalContext`, and on
  no-coverage escalates a warning **for risk-tagged paths** (`risk_paths` regex from
  `kbforge.yaml`) — but only advisory, never a stop.
- **Conventions pipeline**: `dup0.py` detects duplicate-function clusters (`samename`) and
  clones → `kb/derived/dup-residue.md` → proposed in `kb/inferred/08-consistency.md` →
  ruled in `speccraft-ratify` → accepted conventions land in `kb/normative/03-conventions.md`
  (scoped). *This is the "seam" concept already — just prose, single-file, and not rendered
  by recall as "use X not Y."*
- `speccraft-diverge` files a divergence to `QUEUE.md ## Open` (prose skill, no code).

## 3. Goals / non-goals

**Goals**
- Make a ratified **seam** (canonical symbol + anti-pattern, scoped to paths) surface at
  write-time as an actionable "USE `x` · AVOID `y`" when an agent touches a governed file.
- **Confusion Protocol:** a hard stop-once when an agent edits a **risk-tagged path with no
  KB coverage**, forcing elicit-or-file instead of guess-and-clone.

**Non-goals (later phases)**
- *Enforcing* the anti-pattern — grep-banning `avoid:` occurrences / `dup0` failing on new
  clones — is **Phase 4/5**. Phase 2 defines the `avoid:` grep pattern but does not enforce it.
- Gating non-risk no-coverage edits (most code legitimately has no fact — too noisy).
- Auto-authoring seams; `dup0` continues to feed *candidates*, humans ratify them.

## 4. Design

### 4.1 Seams as per-convention files
Conventions become one ratified file each (they have no template today):
```
kb/normative/conventions/CONV-NN-<slug>.md
```
Frontmatter:
```yaml
---
status: ratified
anchors: [backend/app/services, backend/worker, topic:entitlement]
seam: "effective_tier(user) — import from backend.app.services.tiers"
avoid: "raw User.tier for gating"
avoid_pattern: "\\.tier\\b(?!.*effective_tier)"   # optional; consumed by Phase 4/5, NOT enforced here
ruling: "DIV-011 / 2026-08-10 (fix-code C-01)"
---
## CONV-11 — one entitlement seam
Tier gating goes through `effective_tier()` … (scope: money/entitlement paths;
tolerated nowhere else). Raw `User.tier` is defect pattern C-01.
```
- `seam:` / `avoid:` are optional — a convention that isn't a canonical-symbol seam (e.g.
  "bare `except` banned on money paths") omits them and is still a normal convention.
- **`kb/normative/03-conventions.md` becomes a generated human index** — one line per CONV
  (id, title, anchors, seam). recall reads the per-convention files (per-file anchors →
  per-file matching); the index is for humans.
- **Provenance unchanged:** normative lane (human-ratified, `KB_RATIFY`). `dup0` `samename`
  candidates → `08-consistency.md` proposals → `ratify` writes the CONV file + index line.
- Phase 2 ships a **scaffold**: the `conventions/` dir, an index header, and one worked
  example CONV file (as a template + eval fixture).

### 4.2 Seam-aware recall rendering
`recall.py` learns the `seam:`/`avoid:` frontmatter fields and renders a matched convention
with them appended, e.g.:
```
[ratified            ] kb/normative/conventions/CONV-11-entitlement.md  <- backend/worker
        → USE: effective_tier(user) — import from backend.app.services.tiers
        → AVOID: raw User.tier for gating
```
- Parsing: extend `frontmatter()`/`collect()` to capture `seam`/`avoid` scalars alongside
  `anchors`/`status`. Rendering: in `main()`'s matched-fact loop, if the fact has `seam`,
  print the USE/AVOID lines under it.
- **Flows through both existing hooks unchanged in wiring:** the PreToolUse
  `kb-recall-gate.sh` already denies-once on a ratified match (a seam is ratified → the
  agent must acknowledge USE/AVOID before editing a governed file); the PostToolUse
  `kb-recall-post.sh` injects the rendered seam as context. No new hook for surfacing —
  only better rendering + the schema.

### 4.3 Confusion Protocol — stop-on-no-coverage (risk paths)
- **`recall.py --no-coverage-check`** — a new exit-code mode mirroring `--gate-check`:
  exit **3** if NO fact (any lane) covers any of the `--files`, else 0. (Reuses the
  `match()`/coverage logic; distinct from `--gate-check` which fires on ratified *matches*.)
- **`kb-recall-gate.sh`** gains a second branch: for a **risk-tagged** path (test `REL`
  against the `risk_paths` regex, as `kb-recall-post.sh` already does) that has **no
  coverage** (`--no-coverage-check` → exit 3), **deny the edit once** (same dedup cache and
  once-per-file-per-session as the ratified branch) with:
  > "No KB coverage for this risk-tagged path (`<rel>`). Don't guess-and-clone. Run
  > `speccraft-recall`, elicit intent, or file a coverage-gap divergence
  > (`speccraft-diverge`), then re-issue the edit."
- Order: the existing ratified-match deny takes precedence; the no-coverage deny is the
  fallback when there's no ratified fact *and* the path is risk-tagged *and* uncovered.
- Non-risk no-coverage and covered paths are never denied (only the existing advisory
  post-hook behavior applies).

### 4.4 SKILL + mirror updates
- **`speccraft-recall`**: document the seam USE/AVOID rendering and the Confusion-Protocol
  stop (what a no-coverage risk-path denial means and the two ways out: elicit/recall, or
  file a coverage-gap divergence).
- **`speccraft-ratify`**: "Convention accepted → write `kb/normative/conventions/CONV-NN-<slug>.md`
  with `anchors`/`seam`/`avoid`/`ruling`, and add its index line to `03-conventions.md`."
- **`speccraft-diverge`**: the coverage-gap divergence variant (a `## Open` item noting the
  risk-tagged path with no coverage, for elicitation).
- **Mirror** all three to `codex-prompts/` + `opencode-commands/` (the Phase 1 final review
  taught us these drift — sync them in the same task).

## 5. Testing

Bash, `session-kit/evals/test-seams.sh`, wired into `self-test.sh`:
1. **Seam rendering** — a CONV file with `seam`/`avoid` anchored to a path; `recall.py --files <that path>`
   prints the USE and AVOID lines.
2. **Non-seam convention** — a convention without `seam`/`avoid` renders normally (no USE/AVOID), no crash.
3. **`--no-coverage-check` exit codes** — covered file → 0; uncovered file → 3.
4. **Confusion Protocol gate** — copy `kb-recall-gate.sh`; a risk-tagged path with no coverage →
   deny (permissionDecision deny, once); a covered risk path → allow; a non-risk uncovered path → allow;
   second touch of the same denied file → not denied again (dedup).
5. **Ratified-seam gate precedence** — a risk path governed by a ratified seam → the ratified deny
   fires (with USE/AVOID), not the no-coverage branch.
6. **Frontmatter parse** — `seam`/`avoid` scalars (quoted, with special chars) parse without breaking
   the existing `anchors` parsing.

## 6. Files touched

| File | Change |
|---|---|
| `recall.py` | Parse `seam`/`avoid` frontmatter; render USE/AVOID; add `--no-coverage-check` exit-code mode |
| `session-kit/hooks/kb-recall-gate.sh` | Second deny branch: risk-tagged + no-coverage → deny-once (Confusion Protocol) |
| `kb/normative/conventions/` (scaffold) | New dir + `03-conventions.md` index header + one worked CONV example (template/fixture) |
| `session-kit/skills/speccraft-recall/SKILL.md` | Seam rendering + Confusion-Protocol stop |
| `session-kit/skills/speccraft-ratify/SKILL.md` | Convention-accepted → write CONV file + index line |
| `session-kit/skills/speccraft-diverge/SKILL.md` | Coverage-gap divergence variant |
| `session-kit/codex-prompts/`, `opencode-commands/` | Mirror the 3 SKILL updates |
| `session-kit/evals/test-seams.sh` + `self-test.sh` | The suite above |
| `SPEC.md` | Document the seam fields + the Confusion Protocol |

## 7. Risk / rollback
- Blast radius: speccraft tooling + a new normative sub-lane (`conventions/`). No product code.
- The Confusion-Protocol deny is scoped (risk-tagged + no-coverage + once) so it can't wedge
  ordinary development; a KB with no CONV files behaves exactly as today.
- Rollback: revert the code; `seam`/`avoid` fields are additive and inert to old recall; the
  `conventions/` dir is just more normative files.

## 8. Out of scope → next
- **Phase 3** — edit-scope freeze for parallel fan-out (the other half of D).
- **Phase 4** — executable invariants (incl. the two steal-now checks); can consume `avoid_pattern`.
- **Phase 5** — single-source cure: `dup0` fails CI on a NEW clone of a ratified seam (consumes
  `seam`/`avoid_pattern`). Phase 2's schema is the substrate for that enforcement.
