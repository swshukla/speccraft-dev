# Knowledge Base (superdev/)

This repo carries a trust-graded knowledge base in `superdev/`: ratified
product truth (intent, invariants, conventions), machine-derived facts, and
an adjudication queue. **Read `superdev/KB-STATUS.md` at session start** —
it is auto-refreshed on every code commit (pin, open queue items, invariants).

- **Before modifying a module**: follow the superdev-recall procedure (Claude:
  `superdev-recall` skill; Codex/OpenCode: `/superdev-recall` command), or directly:
  `python3 ~/superdev/kb-forge/recall.py --config superdev/kbforge.yaml --files <repo-relative paths>`.
  Facts marked `ratified` and every `INV-*` invariant are constraints, not
  suggestions.
- **Making a tradeoff** (constant, threshold, tolerated failure, rejected
  alternative): superdev-decide — record it in `superdev/kb/decisions/` at decision
  time.
- **Task conflicts with a ratified fact**: superdev-diverge — append the divergence
  to `superdev/QUEUE.md` and stop that part; never silently violate, never
  self-ratify. Founder rules via superdev-ratify.
- **Before any new integration or data fetch**: read
  `superdev/kb/inferred/05-data-sources.md` and `06-integrations.md` — the
  capability or data probably already exists.
- **Write lanes for agents**: `superdev/QUEUE.md` (append),
  `superdev/kb/decisions/`, `superdev/kb/inferred/` ONLY. `kb/normative/`,
  `kb/derived/`, `ledger/` are founder/machine lanes — enforced by a git
  pre-commit hook, not just this text.
- **Write-back is automatic**: a post-commit hook re-pins the KB and flags
  drift after every code commit (`kb:`-prefixed commits). Code-only history:
  `git log -- ':(exclude)superdev'`.
