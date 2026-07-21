---
description: Use to elicit and record product intent and invariants from the founder/creator — the knowledge no code scan can produce. Run when bootstrapping a repo's KB (before the extraction passes), and again whenever direction shifts. Grounds every downstream fact.
---


# superdev-interview — capture the intent the code can't reveal

Intent and invariants are `elicited` truth: they come from the person, in their
own words, and code changes never invalidate them. This is the SEED of the
grounded ratchet — every other fact validates against what you capture here.
Run it BEFORE the extraction passes so their hypotheses can be checked against
real intent, not the other way round.

## 1. Ground yourself first — never interview blind
Read the derived layer so questions are specific and evidence-anchored:
`superdev/kb/derived/inventory.md`, `modules.md`, `routes-*.md`,
`data-model.md`; skim the repo README / docs / AGENTS.md.
Generic questions ("what's your vision?") waste the founder's time. Anchored
ones ("I see a `twitter_content_service` and a `calls` ledger — what are those
*for*?") surface real intent fast.

## 2. Interview in short rounds, one theme at a time
Ask 3–5 concrete questions per round; prefer multiple-choice with a recommended
option over open prompts (faster, sharper). Capture answers in the founder's
OWN words. One theme per round — don't dump everything at once. Anything
unanswered stays open (queue it); never guess.

**Intent (→ `kb/normative/00-product-intent.md`):**
- Identity — what it is in one line; and what it is NOT.
- Target user — who, and the edge it gives them.
- Stage — age, users, is it live / ready.
- Monetization — how it earns now, and the intended path.
- Direction — the differentiation; what's legacy vs future.
- Explicit non-goals — what you are deliberately not doing.

**Invariants (→ `kb/normative/01-invariants.md`, each an `INV-N`):**
The rules that must ALWAYS hold — violating one is a bug by definition. Probe:
- Data integrity (append-only? immutable? consistent across surfaces?)
- Legal / compliance stance (what you will and won't claim or do)
- Canonical facts (the one true domain / source of truth)
- Contracts (latency, delivery, availability promises)
Distinguish an INVARIANT (always true, non-negotiable) from a preference
(usually true). Only invariants get INV-ids.

## 3. Record with provenance
Each file: frontmatter `status: ratified`, `elicited_by: interview <date>`,
`anchors:` (a topic + the modules it governs). Tag each claim `elicited`.
Anything you inferred from code/docs but the founder has NOT confirmed → mark
`observed` and queue it for ratification; do not assert it as elicited.

## 4. Close the loop
- Contradictions you spot between stated intent and observed code → divergence
  candidates; file via **superdev-diverge** (they become `ledger/` entries).
- Deferred questions → `superdev/QUEUE.md`.
- Commit with `KB_RATIFY=1` (you are writing ratified normative truth, with the
  founder present and answering).

Re-run when direction shifts — intent is versioned, not frozen; a changed
answer supersedes the old, and git keeps the history.

_Scope: the superdev/ KB in the current repo._
