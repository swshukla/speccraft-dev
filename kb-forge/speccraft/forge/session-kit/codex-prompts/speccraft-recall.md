---
description: Pull trust-graded KB facts governing the code you are about to touch (.speccraft KB repos). Run at task start, before writing code.
argument-hint: <repo-relative paths and/or topic slug>
---

Task / paths under consideration: $ARGUMENTS

# speccraft-recall — ground the task in ratified truth

(Applies to repos with the .speccraft KB layout, e.g. stocktickerapp. The
canonical procedure also lives at `.agents/skills/speccraft-recall/SKILL.md`.)

1. List the repo-relative paths you expect to touch (and/or a topic slug —
   the anchor vocabulary is in the KB files' frontmatter; common ones:
   `product-intent`, `monetization`, `compliance`, `data-sources`,
   `integrations`, `assumptions`, `conventions`).
2. Run:
   `python3 ~/.speccraft/kb-forge/recall.py --config .speccraft/kbforge.yaml --files <paths> --harness codex`
   (add `--topic <slug>` for topics; both may be combined)
3. Interpret by trust class, in order:
   - `ratified` / `INV-*` invariants → **constraints**. Restate the relevant
     ones in your plan; your change must satisfy them or you must invoke
     **speccraft-diverge** — never silently violate.
   - `ratified-partial` / `observed` → binding unless your evidence
     contradicts; a contradiction is a QUEUE item, not a free pass.
   - `pending-ratification` → context, not law; do not cite as ground truth.
   - `challenged` → actively distrust; verify against code before relying.
4. If the output says **NO KB COVERAGE** and any target path matches the
   `risk_paths` in `.speccraft/kbforge.yaml`: stop. Check
   `.speccraft/kb/inferred/05-data-sources.md` and `06-integrations.md` for
   existing capability, then append a coverage-gap note to `.speccraft/QUEUE.md`
   before proceeding.
5. Before ANY new external dependency, data fetch, or cross-component call:
   read 05-data-sources.md and 06-integrations.md — the capability or the
   data probably already exists; reuse beats reinvention.
