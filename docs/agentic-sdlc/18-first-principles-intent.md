# Agentic SDLC — First-Principles Intent for Undocumented Brownfield

**Date:** 2026-07-13
**Purpose:** How the system builds a clear understanding of what a product **should be** — not what the code says — when onboarding a brownfield startup product with poor design and no requirement/product docs; how that understanding confronts every repo and module to yield a **coherent spec**; and how inconsistencies are flagged for a **human expert** to resolve. The result is the **foundation KB** the system works on.

## The problem doc `04` didn't fully solve

Doc `04`'s spec archaeology is **bottom-up**: reverse-engineer specs from what the code *does*, every claim cited to evidence. That's the right anti-hallucination stance — but on a badly-designed, undocumented product it has a ceiling: **archaeology faithfully documents the mess.** If the code has the wrong abstraction, a violated domain rule, or three conflicting implementations of the same concept, bottom-up specs will be three faithful, locally-consistent descriptions of an incoherent whole. What's missing is the **top-down question: what should this system be, from first principles?** — and the discipline to hold that answer *against* the code without letting it become invented "truth."

**Approach (decided):** dual-track, hypothesis-driven. The normative model is built fast as an explicit *theory*; the repo/module scan is the *experiment* that tests and refines it; a human expert adjudicates every disagreement. (Rejected: pure top-down waterfall — the model gets built half-blind and burns expert time before evidence exists; pure bottom-up overlay — never yields a coherent system-level intent.)

---

## 1 · Two models, two truth classes

| Model | Answers | Built by | Trust basis |
|---|---|---|---|
| **Descriptive (as-is)** | what the code *does* | doc `04` archaeology — unchanged | citation + execution + adversary |
| **Normative (to-be)** | what the system *should be* | this doc | **source tags + expert ratification** |

The Normative Product Model contains: **purpose** (what the product exists to do), **users & jobs** (personas, jobs-to-be-done), a **capability map** (what the system must be able to do, hierarchical), **domain invariants** ("a wallet balance never goes negative", "every money movement is idempotent and audited", "KYC precedes first transaction"), and **quality attributes** (what must be fast/available/secure and to what degree).

**How this coexists with "cite or it didn't happen."** A normative claim *cannot* cite code — code is exactly what it must not defer to. Instead every normative element carries a **source tag**:

- `elicited` — a human said it (doc `09`'s `human-asserted`, dated) → trusted for intent.
- `observed` — the product surface implies it (UI, routes, schemas, backlog, public copy) → cited to that artifact.
- `domain-prior` — first-principles reasoning ("any lending product needs KYC") → **born a hypothesis, never self-promoting.** Only expert ratification turns a prior into trusted intent.

> **The adapted doctrine: inventing is allowed only into the hypothesis tier — and hypotheses cannot act; they can only ask.** A domain-prior may generate an interview question or a divergence flag; it may never gate, block, or specify on its own authority.

---

## 2 · Stage I — Intent Bootstrap *(product-wide · days, not weeks)*

Three feeds build the **draft** normative model:

**(a) Artifact sweep** — everything that betrays intended purpose *without trusting code internals*: UI screens & flows, route/API surface, DB schemas & indexes, test names (assertions are intent fossils), backlog/tickets, README fragments, the marketing site / app-store listing / support macros. Deterministic-to-cheap; all `observed`, all cited.

**(b) Domain priors** — the model reasons from first principles about what a product *in this domain, for these users* must have: standard capabilities, regulatory obligations, canonical invariants, known failure modes. Every output is a tagged `domain-prior` hypothesis.

**(c) One structured expert interview** — generated *from* (a)+(b), so the founder answers sharp, closed-form questions ranked by leverage ("I see refund flows but no dispute handling — out of scope, or missing?" · "Priors say lending needs cooling-off compliance — applicable in your market?") instead of giving an open-ended brain-dump. **Capture on contact** (doc `09`): every answer becomes a durable, dated `elicited` fact; ask once.

*Output:* the **draft Normative Product Model** — coherent, source-tagged, explicitly marked **theory**. It is deliberately built *before* deep code reading so the code cannot anchor it ("what the system should be, not what the code says").

---

## 3 · Stage II — Confrontation scan *(per repo → per module · theory meets reality)*

Rides doc `04` unchanged: Seed-0 deterministic ingest and Seed-1 module map run first; per-module archaeology produces the as-is spec. The net-new second pass per module: **map the module to the capabilities it serves, then diff as-is against to-be.** Disagreements land in a typed **divergence ledger**:

| Divergence type | Meaning | Typical ruling |
|---|---|---|
| **Missing capability** | model demands it; no code implements it | backlog (build) or model fix (descope) |
| **Violated invariant** | code contradicts a domain rule | fix-code ticket (often the highest-value findings) |
| **Orphan code** | code with no home in the model | dead weight (remove) or **model gap** |
| **Conflicting implementations** | ≥2 modules/repos implement one concept with different rules | consolidate (code) or split the concept (model) |
| **Model gap** | code reveals a real capability the theory missed | revise model → re-ratify |

Cross-repo coherence is driven by a product-level **concept registry**: canonical domain entities/invariants (Wallet, KYC-status, Settlement) with every implementation site mapped via the code graph. Same concept + different rules across repos = automatic `conflicting-implementations` flag — this is what makes the spec **coherent across repositories**, not just within modules.

**Nothing is auto-resolved.** The scan's job is to *surface and type* disagreement, never to pick a winner — extending doc `09`'s three-way triangulation with the normative source as a fourth voice.

---

## 4 · Stage III — Expert adjudication *(the convergence loop)*

Divergences flow to a **ranked queue** — risk class × graph centrality × confidence — surfaced in the org's tracker exactly like doc `04`'s ratification queue (dozens of decisions, not thousands). Each ruling has one of three **canonical** types:

1. **Fix the code** — the model is right; the divergence becomes a remediation ticket in the backlog. *The system's first autonomous work items are born here* — seeded with unusually crisp specs, because the spec is the ratified model itself.
2. **Fix the model** — the theory was wrong; revise the element, re-tag `elicited`/ratified.
3. **Accepted deviation** — real, known, tolerated: a documented exception with a date and an owner, revisited on staleness (same volatility rule as all intent, doc `09`).

> **The ruling taxonomy is extensible by design.** The one manual run of this pipeline needed roughly nine distinct labels to describe real rulings (`20`) — *defer*, *right-but-reword*, *true-but-out-of-scope*, and friends. So the ledger stores the ruling as an **open label set with the three above as the canonical core** — not a three-value enum baked into the schema and every downstream consumer. Adjudicators add labels on contact; labels that recur get promoted into the canonical set. Enums calcify, and the field data already shows this one would.

Every ruling is captured on contact. The model **converges monotonically**: each pass through the queue leaves it more ratified and less hypothetical.

> **Autonomy gate — scoped by blast radius, not by module:** an unresolved divergence blocks autonomous work on **the code paths and capabilities it touches** (computed from the code graph), not the whole module — a module-wide bar, at realistic deferral rates, would park the fleet on almost everything. The loop runs where theory and reality have been reconciled — or the gap is explicitly accepted. And **deferrals carry a TTL**: a divergence unruled past its TTL escalates in the queue (`09`) rather than accumulating silently; accepted-deviations already carry a revisit date. (Extends doc `04`'s trust rule: it's not enough that the spec is *evidenced*; spec and intent must be *coherent* — on the paths being touched.)

---

## 5 · The foundation KB — and who inherits the machinery

What survives all three stages is the **foundation KB**:

```
RATIFIED NORMATIVE MODEL   purpose · users/jobs · capability map · invariants · quality attrs
AS-IS SPECS                per-module, cited (doc 04, unchanged)
CONCEPT REGISTRY           canonical domain concepts → implementation sites (cross-repo)
TRACEABILITY               spec ↔ code links (doc 04)
DIVERGENCE LEDGER          every flag + its human ruling — including live accepted-deviations
```

**This pipeline is the Drift Reconciler's cold-start mode.** Confront-intent-with-code, type the disagreement, queue for a human — that is exactly what the Drift Reconciler (`03`/`13`) does continuously at steady state. Same divergence taxonomy, same ledger, same queue; seed-time runs it product-wide once, steady-state runs it per merge. One machine, two duty cycles — the moat component gets its data model from this doc.

**Fit with the cell model (`17`):** everything here runs **in-cell**; the normative model, concept registry, and divergence ledger are **product-scoped** (org-shareable only for genuinely shared domain concepts, opt-in); the Intent-Bootstrap and Confrontation agents, interview generator, and divergence taxonomy ship as **factory artifacts**. Expert adjudication surfaces through the product's own tracker adapter.

**Sequencing (amends `04`'s timeline, keeps its caution):** the Intent Bootstrap and a *shallow* confrontation pass run **product-wide, early** — a coherent system-level understanding is cheap at low resolution, and it's what picks the right Phase-0 module for the *deep* pass. Archaeology depth still follows risk-rank order, one module at a time.

```
Week 1      Stage I    Artifact sweep + priors + expert interview        → draft normative model (theory)
Week 1–2    Stage II   Shallow confrontation, product-wide               → divergence ledger v1, module risk-rank
Week 2      Stage III  First adjudication pass (top-ranked divergences)  → ratified core model + first remediation backlog
Week 2+     04 loop    Deep archaeology + confrontation, module-by-module in risk order; loop runs on reconciled modules only
```

---

## Doctrine (add to `04`/`09`/`17`'s lists)

18. **Two models, held apart** — the as-is is cited from code; the to-be is sourced from humans, artifacts, and tagged priors. Neither may masquerade as the other; coherence between them is *earned through adjudication*.
19. **Hypotheses ask; they never act** — a domain-prior can generate a question or a flag, never a gate, spec, or veto, until a human ratifies it.
20. **Confrontation over description** — on brownfield, the spec's value is in the *diff* between should-be and is; documenting the mess faithfully is not understanding it.
21. **Reconciled or ineligible — at blast-radius scope** — no autonomous work on code paths whose divergences a human hasn't ruled on; unrelated paths in the same module stay eligible, and deferrals expire into escalation, never into silence.
22. **One machine, two duty cycles** — seed-time confrontation and steady-state drift reconciliation are the same component; never build them twice.

## What this changes in earlier docs

- **`04` seeding:** gains Stage I/II/III wrapped around its phases; the trust bar rises from *evidenced* to *evidenced + coherent*; timeline amended as above.
- **`09` mixed-input:** the structured interview becomes the *third* elicitation trigger (beyond blocking questions and proactive externalization); triangulation becomes four-way (code / backlog / head / normative model).
- **`13` component view:** **+ Intent-Bootstrap agent**, **+ Confrontation scanner**, **+ concept registry** (store), **+ divergence ledger** (store, shared with Drift Reconciler); interview generator is part of the PM/Spec agent family. All Build (definitions) on the existing runtime.
- **`03`/Drift Reconciler:** its data model, divergence taxonomy, and adjudication queue are defined *here*; steady-state drift is this pipeline on a per-merge duty cycle.
- **`17` cells:** the pipeline ships as factory artifacts; all knowledge produced is product-scoped, in-cell.
