---
name: speccraft-recall
description: Use before modifying any module in this repo, and before adding any integration or data fetch — pulls the trust-graded KB facts governing the code you are about to touch. Invoke at task start, before writing code.
---

# speccraft-recall — ground the task in ratified truth

1. List the repo-relative paths you expect to touch (and/or a topic slug —
   the anchor vocabulary is in the KB files' frontmatter; common ones:
   `product-intent`, `monetization`, `compliance`, `data-sources`,
   `integrations`, `assumptions`, `conventions`).
2. Run:
   `python3 ~/.speccraft/kb-forge/recall.py --config .speccraft/kbforge.yaml --files <paths> --harness claude-skill`
   (add `--topic <slug>` for topics; both may be combined)
   Then pre-clear the recall gate for those paths so your first edit isn't
   bounced (skip harmlessly if the session variable is unset):
   `for p in <paths>; do echo "$p" >> "${TMPDIR:-/tmp}/speccraft-recall-seen-${CLAUDE_SESSION_ID:-nosession}"; done`
3. Interpret by trust class, in order:
   - `ratified` / `INV-*` invariants → **constraints**. Restate the relevant
     ones in your plan; your change must satisfy them or you must invoke
     **speccraft-diverge** — never silently violate.
   - `ratified-partial` / `observed` → binding unless your evidence
     contradicts; a contradiction is a QUEUE item, not a free pass.
   - `pending-ratification` → context, not law; do not cite as ground truth.
   - `challenged` → actively distrust; verify against code before relying.
4. If a matched fact carries a seam, recall renders it as `→ USE: <seam>` /
   `→ AVOID: <avoid>` under the fact. That is a canonical seam: import/use
   the named symbol, don't clone or reinvent it. Treat `avoid` as a defect
   pattern — code matching it is a **speccraft-diverge** candidate, not
   something to imitate.
5. If the output says **NO KB COVERAGE** and any target path matches the
   `risk_paths` in `.speccraft/kbforge.yaml`: stop — this is the Confusion
   Protocol. The recall gate (`kb-recall-gate.sh`) denies-once on exactly
   this condition (risk-tagged path, no coverage in any lane), because a
   canonical seam may exist that isn't visible from here. Don't
   guess-and-clone. Instead: re-run this procedure, elicit the intent from
   the user, or file a coverage-gap divergence (**speccraft-diverge**)
   naming the path — then re-issue the edit; the gate clears after the
   first denial.
6. Before ANY new external dependency, data fetch, or cross-component call:
   read 05-data-sources.md and 06-integrations.md — the capability or the
   data probably already exists; reuse beats reinvention.
