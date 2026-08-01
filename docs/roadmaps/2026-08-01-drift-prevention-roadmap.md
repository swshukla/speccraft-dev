# Speccraft Drift-Prevention Roadmap

**Date:** 2026-08-01
**Type:** Capability roadmap (brainstorm output — not yet a spec/plan)
**Scope:** Speccraft capabilities. Grounded in the SignalCue / stocktickerapp case
study (`~/stocktickerapp/docs/reviews/2026-08-01-system-discrepancy-audit.md` and
its `.speccraft` KB), cross-referenced against garrytan/gstack for borrowable ideas.

---

## 1. The reframe

Speccraft did not fail on the case study. **The 2026-08-01 discrepancy audit is proof
it worked** — a grounded, cited, invariant-anchored KB is exactly what let four
exploration passes produce that report at all.

What the case study exposes is not a *detection* gap. It is a **prevention-and-
convergence** gap. Speccraft is excellent at *cataloging* drift after it lands; almost
nothing in the loop *stops* drift at write-time or *forces* a catalogued item to
closure. The clearest single data point: audit item **B1** (Cue Watchlist "Recent
Results" shows India while Crypto is selected) was written up **2026-07-18** and was
still live on **2026-08-01**. Detected ≠ prevented ≠ fixed.

## 2. Root causes visible in the artifacts

1. **Invariants are prose, not gates.** INV-1..5 live in a markdown file. INV-5
   (cross-surface consistency) is still only *"observed,"* never ratified — so nothing
   physically blocked the crypto→India track-record leak (audit A2/B1). An invariant
   that cannot fail a build is a wish.

2. **Duplication is the drift *vector*.** Telegram send helper re-declared ×10;
   cue-band thresholds cloned ×2; Razorpay subscribe state machine forked ×2;
   tier-gating pattern wrong in ×3 worker tasks; track-record market-default wrong in
   N places. Nearly every discrepancy is a single-source-of-truth violation. Parallel
   agents *clone a pattern* instead of *importing the seam* — because they write
   without recalling. That is the mechanism of startup drift.

3. **The queue is a graveyard, so real signal drowns.** `.speccraft/QUEUE.md` is
   ~600 lines. The genuine HIGHs (Alembic autogenerate will `drop_table` the immutable
   calls ledger; lapsed users still receive paid pushes) sit buried under hundreds of
   auto-generated `spot-check celery_app.py:90 [file changed elsewhere]` lines,
   duplicated across every drift run with no dedup and no decay. `drift.py` is
   *citation-based* (a cited line moved), not *behavior-based* (the same URL serves two
   markets), so it emits volume, not meaning.

4. **No closing loop.** Speccraft has an inbox (QUEUE) but no forcing function.
   Detection and reconciliation are two disconnected steps, so caught drift rots.

## 3. Borrowed ideas (garrytan/gstack)

- **`/freeze` + `/guard`** — edit-scope locking; a parallel agent cannot touch dirs
  outside its declared task. Directly attacks parallel-dev drift.
- **`/document-release`** — the closing loop: read the diff, find what drifted across
  *all* docs, and reconcile it in the same pass. Detection + resolution as one step.
- **Codegen / typed accessors** — generate the derived surface from one source so
  clones cannot diverge.
- **Confusion Protocol + Iron Law** — stop and ask on no-coverage instead of guessing
  (i.e. instead of cloning).
- **`/learn` promote-after-3** — patterns quarantined, then promoted to convention.
- **slop-scan / deny-default allowlist** — automated "this needs explicit justification."

---

## 4. The chosen spine: C + D as one closed loop

The first bet is **C (queue convergence) + D (write-time grounding)**, delivered
together because they are the two halves of one loop speccraft is currently missing.
They are also the prerequisite for the other two bets: you cannot turn on invariant
gates (A) until the queue stops being noise (C), and you cannot collapse cloned seams
(B) until the KB actually *names* the canonical seam (D).

```
   D (write-time)                         C (converge)
┌────────────────────┐            ┌──────────────────────────┐
│ recall surfaces the│            │ DIVERGENCES lane (small,  │
│ canonical SEAM ─────┼──prevents─▶│  durable, human-adjudged)│
│ Confusion Protocol │  new clone │         │                │
│ stops-on-no-cover ─┼──files────▶│  forcing function:       │
│ /freeze contains   │  explicit  │  can't re-pin while N     │
│ blast radius       │  divergence│  HIGHs open / one aged    │
└─────────▲──────────┘            │         │                │
          │                       │  converge = fix OR ratify │
          └───────seams ratified──┴─────────┘                │
                back into KB      SIGNALS lane (dedup+decay,  │
                                  never buries DIVERGENCES)   │
```

D stops drift being *born silently*; C stops caught drift from *rotting in a
graveyard*. Today speccraft has a half-open version of each — recall exists but
surfaces intent not seams; a QUEUE exists but with no dedup, decay, severity split, or
forcing function.

---

## 5. Prioritized roadmap

Ordered by leverage-per-hour and by dependency — each phase unblocks the next.

### Phase 0 — Stop the queue bleeding — *hours · pure C*
Split `QUEUE.md` into two lanes: **DIVERGENCES** (semantic, invariant-touching,
human-adjudicated — the real HIGHs) and **SIGNALS** (machine spot-checks). Dedup the
SIGNALS lane by content-hash; add decay (drop on clean re-pin; TTL otherwise).
**Outcome:** the ledger-drop and lapsed-pay HIGHs surface out from under hundreds of
`celery_app.py:90` lines. You cannot drive to closure what you cannot see — this
unblocks everything.

### Phase 1 — Give the queue teeth — *days · C*
A **forcing function**: `speccraft-ratify` (re-pin / "ship") refuses while there are
`> N` open HIGH divergences, or any HIGH older than X days — a drift debt-ceiling.
Plus: the SessionStart briefing leads with *"N open HIGH divergences, oldest 14d: B1."*
**Outcome:** drift now costs something at commit time, and every session opens staring
at the debt.

### Phase 2 — Seam-aware recall + Confusion Protocol — *days · D, bridge to B*
Add a KB surface (`kb/normative/seams.md` or extend inventory) that **names canonical
seams**: `effective_tier()`, the Telegram send helper, cue-band thresholds, the
track-record market-default. Recall-on-contact then surfaces the *relevant seam* when a
file is touched ("tier gating has a canonical seam; raw `User.tier` is ratified defect
C-01"). Confusion Protocol: on no KB coverage, the agent **stops and files a
DIVERGENCE** instead of guessing-and-cloning.
**Outcome:** most of B's *preventive* value (no **new** clones) without yet doing B's
big refactor.

### Phase 3 — Edit-scope freeze for parallel fan-out — *week · D*
gstack-style `/freeze` as a PreToolUse lane hook: each parallel agent declares a scope;
out-of-scope edits are denied. **Outcome:** blast-radius containment — the specific
hazard of the parallel development that caused the case-study drift. Only needed once
agents are fanning out again, hence Phase 3.

### Phase 4 — Executable invariants — *ongoing · A (steal 2 now)*
The program: convert mechanically-checkable INVs into build-failing checks. Two are so
cheap-vs-catastrophic they should be stolen immediately, regardless of order:
- **Alembic metadata guard** — a test asserting every model (esp. `call`) is in
  `env.py` `target_metadata`, so autogenerate can never `drop_table` the immutable
  ledger (audit D2). ~15 lines.
- **Raw-tier grep-ban** — CI fails if a worker task references `User.tier` instead of
  `effective_tier()` (audit E1). One grep.

The rest of A (market-param on track-record links, etc.) follows once the queue (C)
won't turn new gates into new noise.

### Phase 5 — Single-source cure — *as capacity · B*
Collapse the seams *named in Phase 2* (Telegram ×10, tier-gate ×3, cue-band ×2,
Razorpay ×2) and wire `dup0` to **fail on new clones of a ratified seam**. De-risked by
Phase 2: the seams are already named and recall already points at them, so this is
mechanical consolidation rather than archaeology.

---

## 6. The through-line

- **Phase 0–1** recover signal and add teeth (C).
- **Phase 2–3** stop new drift at the source (D).
- **Phase 4–5** are the durable enforcement (A) and structural cure (B) that C+D made
  safe to attempt.

The four bets in one sentence each:

| Bet | Move | Kills root cause | Effort |
|---|---|---|---|
| **A** Executable invariants | checkable INVs → build-failing gates | #1 prose-not-gates | Low (per check) |
| **B** Single-source cure | collapse cloned seams; dup0 fails new clones | #2 duplication vector | High |
| **C** Queue convergence | two-lane queue, dedup+decay, forcing function | #3 graveyard, #4 no loop | Medium |
| **D** Write-time grounding | seam-aware recall, Confusion Protocol, freeze | root behavioral cause of #2 | Medium |

## 7. Next step

Deep-dive **Phase 0** — the two-lane queue design (DIVERGENCES vs SIGNALS, the
content-hash dedup key, the decay rule) — as the concrete first unblock, then promote it
from roadmap to a spec via the brainstorming → writing-plans flow.
