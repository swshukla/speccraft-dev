---
name: speccraft-ratify
description: Founder-only — use when the founder wants to answer adjudication queue items, confrontation batches, or rule on divergences in this repo's KB. Walks the queue, records rulings in the proper lanes, commits with the ratification flag.
---

# speccraft-ratify — the founder ruling session

1. Read `.speccraft/QUEUE.md` `## Open` (and any confrontation batches it
   points into, e.g. `kb/inferred/07-assumptions.md`, `08-consistency.md`).
2. Present items ONE at a time, highest consequence first. Capture the
   founder's ruling in their own words; ask one clarifying question at most.
   Unanswered or deferred = stays Open — never guess or batch-assume.
3. Apply each ruling to the right lane:
   - **Fact ratified** → update the claim's file: `status: ratified`,
     `ruled: <date>`; if it lives in `kb/inferred/`, move or promote the
     content into `kb/normative/` as appropriate.
   - **Divergence ruled** → `.speccraft/ledger/DIV-NNN-<slug>.md` with ruling
     `fix-code | fix-model | accepted-deviation` (+ revisit trigger for
     accepted-deviation).
   - **Any `fix-code` ruling (bug, divergence, contradiction, gotcha-violation)**
     → set its row in `.speccraft/findings/FINDINGS.md` to `confirmed` (or append
     a new BUG-NNN row if the finding isn't there yet), with severity, evidence
     `path:line`, and the source. This is the ONE place `confirmed` may be set,
     and only in this ratify commit (`KB_RATIFY=1`) — so the worklist's audit
     trail shows a human stood behind each bug. Preserve the existing `Raised`
     value unchanged when flipping `Status` (proposed → confirmed/dismissed);
     only `Status` changes.
   - **`accepted-deviation` / not-a-bug** → set the FINDINGS row to `dismissed`
     (the reasoning lives in `ledger/`).
   - **Convention accepted** → add to `kb/normative/03-conventions.md` with
     its scope ("banned on money paths, tolerated in pollers").
   - **Hypothesis killed** → mark it killed in place with a one-line reason
     (do not delete — the kill is part of the record).
4. Move each answered item to `## Ruled — <date>` in QUEUE.md with a one-line
   summary and where the ruling landed. Before advancing the pin, run the
   HIGH-debt gate:

   ```
   python3 <forge>/gate.py --config <kbroot>/kbforge.yaml
   ```

   If it exits 0, advance the pin as usual. If it BLOCKS (open HIGH findings over
   the ceiling or aged past the limit), either fix those HIGH findings first, or —
   if you are deliberately deferring — record a logged waiver, which authorizes this
   one pin advance:

   ```
   python3 <forge>/gate.py --config <kbroot>/kbforge.yaml --waive "why you're deferring"
   ```

   The waiver is appended to `ledger/DEBT-WAIVERS.md` (committed in this same
   `KB_RATIFY=1` commit) and names the new pin + the deferred BUG ids — the audit
   trail. The pre-commit hook enforces this: a pin advance under HIGH debt without a
   matching waiver is refused. After advancing the `source_commit` pin
   in `kb/derived/inventory.md`, re-run the drift projection so `SIGNALS.md`
   reflects the new pin:

   ```
   python3 <forge>/drift.py --config <kbroot>/kbforge.yaml --queue
   ```

   This is the existing drift command — no new mechanism. Findings resolved by
   the new pin drop out of `SIGNALS.md` automatically and are recorded in
   `QUEUE-ARCHIVE.md`.

5. Commit: `KB_RATIFY=1 git commit -m "kb: rulings <date>" -- .speccraft`
   (the pre-commit lane guard requires the flag for normative/ledger writes).
