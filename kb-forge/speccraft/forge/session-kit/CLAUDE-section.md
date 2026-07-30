# Knowledge Base (ratified product truth)

This product's trust-graded KB lives in `.speccraft/` (tracked in this repo;
layout and trust rules in `.speccraft/README.md`; system spec in
`~/.speccraft/kb-forge/SPEC.md`). A SessionStart hook injects the current KB
briefing; a PostToolUse hook auto-recalls facts for files you edit.

Rules for every session:

1. **Recall before you build.** Before working on a module, run:
   `python3 ~/.speccraft/kb-forge/recall.py --config .speccraft/kbforge.yaml --files <repo-relative paths>`
   Facts marked `ratified` (and every `INV-*` invariant) are constraints, not
   suggestions. "NO KB COVERAGE" on a risk path means: elicit or excavate
   before building, or record the gap in .speccraft/QUEUE.md.
2. **Never silently diverge.** If the task requires violating a ratified fact,
   stop and append a divergence item to `.speccraft/QUEUE.md`
   (as-is / to-be / why). The founder rules; sessions never self-ratify.
3. **Capture decisions at decision time.** When you fix a constant, choose a
   tradeoff, tolerate a failure, or reject an alternative, append an ADR-lite
   file to `.speccraft/kb/decisions/` (see its README template).
4. **Check before integrating.** Before adding any external dependency, data
   fetch, or cross-component call, read `.speccraft/kb/inferred/05-data-sources.md`
   and `06-integrations.md` — the capability may already exist.
5. **Write lanes.** Sessions may write ONLY to: `.speccraft/QUEUE.md` (append),
   `.speccraft/kb/decisions/`, `.speccraft/kb/inferred/`, and `.speccraft/proofs/`
   (regenerable proof renders from speccraft-prove — never hand-edited). Never
   `.speccraft/kb/normative/`, `.speccraft/kb/derived/`, or `.speccraft/ledger/` —
   founder/machine lanes (a PreToolUse hook enforces this).
6. **Write-back is automatic.** The post-commit hook runs the ship loop on
   every code commit (drift vs old pin, then re-pin + re-harvest, then a
   `kb:`-prefixed commit of .speccraft/). Commits touching only .speccraft/ don't
   re-trigger it. Don't run seed0/drift manually unless debugging.
   Code-only history view: `git log -- ':(exclude).speccraft'`.
