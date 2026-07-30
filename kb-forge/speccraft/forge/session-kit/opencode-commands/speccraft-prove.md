---
description: Use when someone asks you to PROVE one specific ratified INV-* invariant or normative claim against the current code — re-verifies the fact via the judge and renders a proof artifact (file:line cite card or mermaid diagram) only if it still holds; refuses and files a divergence when the code contradicts it. Pull-based, one named fact at a time; carries no measurement logic of its own.
---


# speccraft-prove — verify first, then render the proof

Pull-based, single-fact proof renderer. It never pushes proofs and never
renders a claim the code contradicts: it re-verifies ONE named fact against
current code, then renders only if the fact still holds. This command is UX
only — every verdict comes from `evals/prove.sh`; never assert SUPPORTED or
CONTRADICTED yourself, the way speccraft-eval never computes a rate.

1. **Scope gate.** Prove only a *ratified* `INV-*` invariant or a *normative*
   claim (`.speccraft/kb/normative/`). If asked to prove an inferred, derived,
   or pending-ratification claim, refuse and point the requester at
   **speccraft-ratify** first — an unratified claim is not yet provable.

2. **Measure, don't assert.** Run the engine and read its block; never judge
   the fact yourself:
   ```
   ~/.speccraft/kb-forge/session-kit/evals/prove.sh <repo-root> <FACT-ID>
   ```
   `<FACT-ID>` is `INV-<n>` or a unique substring of the claim. Read `VERDICT`,
   `EVIDENCE`, `CODEHASH`, `ANCHORS`, and `KBFILE` from its output. The exit
   code mirrors the verdict (0 SUPPORTED · 10 POSSIBLY_STALE · 20 CONTRADICTED
   · 2 the fact could not be resolved — fix the FACT-ID, never guess a fact).

3. **Branch on the verdict** — the whole point is to render nothing you cannot
   stand behind:
   - **CONTRADICTED** → do NOT render. File a divergence: append the
     **speccraft-diverge** QUEUE template to `.speccraft/QUEUE.md` (`as-is` =
     the engine's `EVIDENCE`; `to-be per KB` = the fact plus its `KBFILE`).
     Tell the requester the claim is disproven and is now queued for a ruling.
   - **POSSIBLY_STALE** → render, but stamp the staleness banner (step 5) and
     append a recall / re-ratify note to `.speccraft/QUEUE.md`.
   - **SUPPORTED** → render clean.

4. **Pick the rung by audience.** Engineer → `cite` (a `file:line` evidence
   card). PM or stakeholder → `diagram` (a mermaid map). MVP ships `cite` and
   `diagram` only; if asked for a video or voiced walkthrough, say the `clip`
   and `narrated` rungs are future work, not available yet.

5. **Render** under `.speccraft/proofs/`. Name a cite proof
   `PROOF-<FACT-ID>-<CODEHASH>.md`; a diagram proof shares that stem with a
   mermaid body (`.md` or `.svg`). Frontmatter mirrors the verdict:
   ```
   ---
   fact: <FACT-ID>
   status: <SUPPORTED|POSSIBLY_STALE>
   verdict: <same as status>
   anchors: [<ANCHORS>]
   code_hash: <CODEHASH>
   rendered_at: <UTC timestamp>
   expires_when: anchor files change past <CODEHASH>
   ---
   ```
   Cite body = the claim, then the `file:line — quote` evidence line verbatim
   from the engine. Diagram body = a mermaid graph of the fact's anchors and
   flow. For POSSIBLY_STALE, open the body with a banner:
   `> STALE: unverified against current code — re-ratify before citing.`

6. **Bind & expire.** State in the file that the proof holds ONLY while the
   anchor files' hash still equals `<CODEHASH>`. A proof whose anchors have
   moved past that hash is stale by definition — regenerate it, never trust it.

7. **Manifest.** Append one line to `.speccraft/proofs/INDEX.md`:
   `<date> · <FACT-ID> · <rung> · <verdict> · <CODEHASH>`.

8. **Never pre-render.** Prove only on an explicit request for one named fact.
   No batch proving, no proving on a schedule — pull, not push. That restraint
   is exactly what makes a rendered proof worth trusting.

**Input:** $ARGUMENTS
