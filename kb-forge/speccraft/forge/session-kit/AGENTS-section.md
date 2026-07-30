# Knowledge Base (.speccraft/)

This repo carries a trust-graded knowledge base in `.speccraft/`: ratified
product truth (intent, invariants, conventions), machine-derived facts, and
an adjudication queue. **Read `.speccraft/KB-STATUS.md` at session start** —
it is auto-refreshed on every code commit (pin, open queue items, invariants).

- **Before modifying a module**: follow the speccraft-recall procedure (Claude:
  `speccraft-recall` skill; Codex/OpenCode: `/speccraft-recall` command), or directly:
  `python3 ~/.speccraft/kb-forge/recall.py --config .speccraft/kbforge.yaml --files <repo-relative paths>`.
  Facts marked `ratified` and every `INV-*` invariant are constraints, not
  suggestions.
- **Making a tradeoff** (constant, threshold, tolerated failure, rejected
  alternative): speccraft-decide — record it in `.speccraft/kb/decisions/` at decision
  time.
- **Task conflicts with a ratified fact**: speccraft-diverge — append the divergence
   to `.speccraft/QUEUE.md` and stop that part; never silently violate, never
   self-ratify. Founder rules via speccraft-ratify.
- **Proving a fact to someone** (stakeholder demo, PR evidence): speccraft-prove
  — re-verifies ONE named ratified fact or `INV-*` against current code and
  renders a proof (`cite` card or mermaid `diagram`) only if it still holds; a
  contradicted claim is refused and queued via speccraft-diverge, never rendered.
- **Before any new integration or data fetch**: read
  `.speccraft/kb/inferred/05-data-sources.md` and `06-integrations.md` — the
  capability or data probably already exists.
- **Write lanes for agents**: `.speccraft/QUEUE.md` (append),
  `.speccraft/kb/decisions/`, `.speccraft/kb/inferred/`, and `.speccraft/proofs/`
  (regenerable proof renders — never hand-edited) ONLY. `kb/normative/`,
  `kb/derived/`, `ledger/` are founder/machine lanes — enforced by a git
  pre-commit hook, not just this text.
- **Write-back is automatic**: a post-commit hook re-pins the KB and flags
  drift after every code commit (`kb:`-prefixed commits). Code-only history:
  `git log -- ':(exclude).speccraft'`.
