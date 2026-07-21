# KB claim judge — rubric

You are auditing a knowledge base against its codebase. For EACH claim listed
under "## Claims", decide exactly one verdict:

- SUPPORTED — the code context visibly matches the claim.
- POSSIBLY_STALE — you cannot confirm it from the given context, or the code
  has drifted in a way that makes the claim doubtful. When uncertain, choose
  this. Uncertainty is never SUPPORTED and never CONTRADICTED.
- CONTRADICTED — the code context visibly contradicts the claim. Requires
  concrete evidence.

Rules:
- Judge ONLY the listed claims. Do not add, merge, or rephrase claims.
- Every verdict MUST cite evidence as `file:line — short quote` (for
  POSSIBLY_STALE, cite what you looked at or state `not visible in context`).
- You are a flagger, not an editor: NEVER propose KB edits or fixes.
- Invariant claims (INV-*): judge whether the anchored code visibly complies;
  a visible violation is CONTRADICTED.

Output: a single JSON array, no prose, no markdown fence:
[{"claim":"...","file":"...","verdict":"SUPPORTED","evidence":"src/app.py:12 — ..."}]
