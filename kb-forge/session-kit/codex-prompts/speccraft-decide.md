---
description: Record a coding tradeoff at decision time (.speccraft KB repos) — constants, thresholds, approach choices, library picks.
argument-hint: <one-line summary of the decision>
---

Decision being made: $ARGUMENTS

# speccraft-decide — capture the tradeoff at decision time

(Applies to repos with the .speccraft KB layout, e.g. stocktickerapp. The
canonical procedure also lives at `.agents/skills/speccraft-decide/SKILL.md`.)

1. Create `.speccraft/kb/decisions/YYYY-MM-DD-<short-slug>.md` (today's date;
   never edit or delete an existing decision — a reversal is a NEW file citing
   the old one).
2. Use exactly this shape:

   ```
   ---
   name: <slug>
   provenance: decision
   status: pending-ratification
   decided: <date>
   anchors:
     - <module path the decision governs>
   ---
   **Decision:** one sentence.
   **Alternatives considered:** one line each, why rejected.
   **Why:** the constraint that forced the choice (rate limit, cost, time,
   taste). If arbitrary, write "arbitrary — revisit trigger: <event>".
   **Cost if wrong:** one line.
   ```

3. Honesty rules: "arbitrary" is a valid and useful answer — never invent a
   rationale. Numeric choices (thresholds, cadences, retries, TTLs) ALWAYS
   deserve a decision file; they are exactly what gets lost.
4. If the decision conflicts with a ratified fact, this is not a decision —
   invoke **speccraft-diverge** instead.
