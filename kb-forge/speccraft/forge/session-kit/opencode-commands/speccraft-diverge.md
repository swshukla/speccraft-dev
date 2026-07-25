---
description: Use when the task at hand requires violating or contradicting a ratified KB fact or INV-* invariant in this repo, or when you find code that already does. Files the divergence for founder ruling instead of silently proceeding.
---


# speccraft-diverge — never silently diverge

1. STOP implementing the conflicting part. Sessions never self-ratify and
   never "temporarily" violate an invariant.
2. Append to `.speccraft/QUEUE.md` under `## Open` (next number):

   ```
   N. **Divergence: <short title>** — as-is: <what code does / what the task
      wants, with path:line evidence>. To-be per KB: <the ratified fact or
      INV-* it conflicts with, with its KB file>. Why it surfaced: <one
      line>. Proposed ruling: fix-code | fix-model | accepted-deviation.
   ```

3. If the divergence is a defect (crash, data loss, security, wrong behaviour,
   ledger-integrity), also append a `proposed` BUG-NNN row to
   `.speccraft/findings/FINDINGS.md` (severity + evidence `path:line` + source),
   so it appears on the consolidated worklist. `proposed` ≠ confirmed — the
   founder confirms via `speccraft-ratify`.
4. If parts of the task don't depend on the ruling, continue those; leave the
   conflicting part unimplemented with a `TODO(speccraft-diverge #N)` marker.
4. The founder rules via **speccraft-ratify**; fix-model updates the KB, fix-code
   becomes a work item, accepted-deviation gets a revisit trigger and lands
   in `.speccraft/ledger/`.
5. Discovered-in-code divergences (existing code contradicting the KB) follow
   the same path — evidence, queue item, no silent "fixing" of either side.

**Input:** $ARGUMENTS
