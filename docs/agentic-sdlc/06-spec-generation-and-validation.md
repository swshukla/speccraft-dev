# Agentic SDLC — Spec Generation & Validation

**Date:** 2026-07-11
**Purpose:** The keystone system. It turns a fuzzy human **problem statement** into a **machine-checkable spec** — the contract the Coder builds to and the Verifier tests against. If this is weak, everything downstream inherits the weakness; if it's strong, autonomy is safe.

## The reframe: a spec must align in three directions

A spec is not a document — it's the point where three things are forced into agreement:

```
        PROBLEM  (what the human wants, in prose)
           │  ⟵ spec ⟷ problem : "does this solve it?"      ← permanent HUMAN gate
         SPEC  (machine-checkable contract)
           │  ⟵ spec ⟷ current system : "is it grounded & consistent?"   ← automatable (KB)
     CURRENT SYSTEM  (the KB — code graph, contracts, invariants)
           │  ⟵ spec ⟷ code : "does the build satisfy it?"   ← Verifier, doc 04
         CODE
```

> **This system owns the top two alignments.** The Verifier (doc `04`) owns the third. Keeping them separate is the whole design: *"does it solve the problem" is a judgment humans keep; "is it grounded / consistent / testable" is machine work.*

---

## Two classes of problem statement (they flow differently)

| | **Enhancement** | **New system, integrating** |
|---|---|---|
| Touches | an *existing* module (live code) | a *new* module + integration seams |
| KB role | load the target's **current spec + contracts**; must preserve them | load the **seam contracts** it consumes/emits |
| Primary risk | **regression** — breaking existing behavior | **integration mismatch** — wrong assumptions at the boundary |
| Spec form | a **delta spec** (what changes vs current) | a **full spec** + an **integration contract** |
| Blast radius | potentially high, inside live module | contained module, but boundary is the danger |
| Key extra gate | **non-breaking check** on existing contracts/tests | **contract conformance** (Pact) at every seam |

Same pipeline, same validation gauntlet — these two just weight different gates.

---

## What a spec *is* here (the artifact)

Spec-as-code in the repo (consistent with `03`/`05`), one file per unit, structured so parts are machine-checkable:

1. **Intent & problem link** — what, why, and the JIRA problem statement it descends from.
2. **Scope & non-goals** — explicitly in, explicitly out. Non-goals are as load-bearing as goals — they bound the blast radius.
3. **Acceptance criteria** — *executable* (Gherkin/BDD-style): each one must be convertible to a failing test. If you can't write a red test for it, it isn't a criterion.
4. **Interface contracts** — APIs, data models, events — especially at integration seams. Typed. This is what Pact/oasdiff check.
5. **Invariants & constraints** — security, compliance (auth/payments/PII), performance budgets, data-shape rules that must always hold.
6. **Impact / blast radius** — which existing modules, contracts, and tests are affected; which changes are breaking (explicitly flagged).
7. **Traceability anchors** — links to the KB entities it grounds in (Serena symbols, existing specs). Every claim about the current system cites one.
8. **Provenance** — derived-vs-asserted, confidence, human-ratified-by, freshness (per `05`).

---

## Generation — a pipeline, not one shot

> **Governing principle: resolve ambiguity *up* (to the human) before committing *down* (to a spec).** The system never guesses on anything that changes behavior. Karpathy's rule restated — the spec is the source of truth, so the human must settle intent *before* code exists.

1. **Triage** — classify (enhancement vs new-integrating), size, risk-rank (touches auth/payments/PII?), route. Cheap, mostly deterministic. High-risk classes get stricter downstream gates from the start.
2. **Ground** — resolve the problem statement against the KB: which modules, contracts, data models, invariants are in play. Enhancement → pull the target's current spec. New → pull the seam contracts. *Nothing about the current system is asserted without a KB citation.* This step also computes **KB coverage of the touched surface** — what fraction of the modules/contracts/invariants in play have ratified KB entries. Low coverage doesn't fail the spec; it routes it to Clarify: **elicit before you validate** (`09`), because a gate cannot judge what the KB has no opinion on.
3. **Clarify** — detect gaps/ambiguity/contradiction and ask the human **targeted, closed questions** (not "tell me more"). "Should recurring orders retry on failure, or fail silently? [retry / fail / escalate]." This is the requirements-elicitation loop and it is where the human stays in the loop, cheaply.
4. **Draft** — produce the candidate spec with citations for every current-system claim and executable acceptance criteria for every behavior.
5. **Decompose** — if large, split epic → units, each with its own criteria and contracts, each independently buildable and verifiable.
6. **Impact analysis** — compute blast radius from the code graph: affected contracts, tests, modules; surface breaking changes explicitly.

Output: a **candidate spec** — untrusted until it clears validation.

---

## Validation — the gauntlet (this is the "validation system")

A spec can be wrong in ways code-tests never catch. Defense in depth, deterministic-first, mirroring `04`'s doctrine. Any single failure flags the spec:

| # | Check | What it catches | How | Determinism |
|---|---|---|---|---|
| 1 | **Well-formed** | missing sections, criteria not in testable form, untyped contracts | schema validation | deterministic — zero hallucination risk |
| 2 | **Grounded** | invented endpoints/fields/behavior of the current system; grounding in rotten knowledge | every current-system claim must cite a KB entity that exists **and is current** — stale, demoted, or superseded entries fail (freshness per `05`) | deterministic triangulation vs KB |
| 3 | **Consistent** | contradicts an existing spec or invariant ("orders can be negative" vs `amount > 0`) | conflict-detection against the Intent KB | mostly deterministic |
| 4 | **Testable by construction** | vague criteria that can't be verified | generate the acceptance test per criterion; it must **compile and run red** against current code | **execution — the strongest signal** |
| 5 | **Complete** | unspecified edge cases, missing error paths | adversarial completeness critic: "what behavior in scope is undefined?" | LLM critic |
| 6 | **Non-breaking / conforming** | silent breakage (enhancement) or seam mismatch (new) | oasdiff vs current API surface; Pact at seams; run existing tests against the *contract delta* | execution |
| 7 | **Adversarial refute** | letter-satisfies-but-violates-intent readings, hidden ambiguity | independent Critic agent (different model/prompt) tries to break it; generator ≠ critic; 2-of-3 refutes kills | LLM adversary |
| 8 | **Policy / compliance** | auth/payments/PII/migration without the required controls | OPA/Rego over the spec's impact + invariants | deterministic |
| 9 | **Human ratification** | *spec ⟷ problem* — "does this actually solve it?" | human confirms intent + acceptance criteria; **the only gate for the top alignment** | human |

> **Gate 4 is the bridge to doc `04`.** A spec you can't turn into a runnable red test is not a spec — it's a wish. Making the acceptance test *first* means the Coder has a concrete target and the Verifier has its oracle, both born from the same artifact. It also keeps the loop honest: the acceptance tests exist **before the Coder does**, instantiated from the ratified criteria — the Coder may *add* tests but is never the author of its own oracle.

Confidence-gate the human step (per `05`/`04`) — but auto-advance is **earned, not granted**: a spec class auto-advances on gates 1–8 with only a light intent confirmation once its measured human-correction rate has stayed under threshold (the same calibration rule as `04` check 5). **Low-confidence, low-KB-coverage, or high-risk** (auth/payments/PII) specs require full human ratification before the spec becomes active. Every verdict **carries its KB-coverage number** — a pass against thin coverage is a weaker claim than a pass against dense coverage and must not wear the same green checkmark. Humans review a *ranked queue* (citation count × execution frequency × consequence class), not everything.

---

## The spec lifecycle (state machine)

```
DRAFT ─► GROUNDED ─► CLARIFIED ─► VALIDATED ─► RATIFIED ─► ACTIVE ─┬─► SUPERSEDED (new spec replaces)
         (KB cited)  (human Q&A) (gates 1-8)  (human, g9)  (contract)└─► DRIFTED  (Reconciler flags code≠spec)
```

`ACTIVE` = the contract is live: the Coder builds to it, the Verifier tests against it, and the **Drift Reconciler** (doc `03`) watches for `code ≠ spec`. A drift finding sends it back toward a new spec cycle. This closes the loop with the memory architecture — the spec *is* the Intent layer of the KB.

**Write-back-on-ship (Phase 0, not deferred):** the merge that ships a spec also updates the KB entries it touched — the spec flips to `ACTIVE`, traceability links refresh, superseded claims demote. The full Drift Reconciler can wait for Phase 1; **KB currency cannot**, because gate 2 of every subsequent spec grounds in it.

---

## How the JIRA hierarchy maps to altitudes

The JIRA work-item types line up naturally with the two spec altitudes and the PM layer — the tracker's own hierarchy *is* the altitude ladder:

| JIRA type | Altitude | Owner / gate |
|---|---|---|
| **Idea (one-line problem statement)** | raw ask → framed **problem** | PM Agent (`08`) frames + elicits; becomes an Epic/Feature (path per `15`) |
| **Epic / Feature** | product intent → **epic-spec** | PM Agent (`08`) drafts, human ratifies *intent* (gate 9) |
| **Story / Task** | technical unit → **unit-spec** | Spec Agent validates *correctness* (gates 1–8), builds to it |
| **Bug** | a regression/defect **problem statement** | enters as a problem (`08`) or a Drift/Monitor finding (`03`) |

So "ratify the epic" happens on the JIRA Epic/Feature; "validate and build the unit" happens on the Story/Task; a Bug is just a problem statement with a defect flavor. No new concepts — the existing JIRA structure carries the altitudes.

---

## Where it runs

Same physical model as everything else (`02`/`03`):
- **Spec Agent** and **Critic Agent** — ephemeral sandboxed **stage-workers** (Zone 3), one per run, dispatched by the **Orchestrator** (Zone 2).
- They **read** the KB (Serena code graph, Atlas Vector, spec store) and **write** the candidate spec to the repo **as a PR** (spec-as-code) — never directly to `ACTIVE`.
- **Clarification** questions and **ratification** happen in **JIRA / the PR** — the human-in-the-loop surface.
- Model calls go through the **Model Gateway** (redaction, budgets) — and note: only the *problem statement + code/specs* ever leave the tenant, never regulated data (`02`).

**Net-new to build:** the Spec Agent + Critic definitions (prompts/tools/schema on the Agent SDK), the validation gauntlet (gates 1–3, 8 are deterministic scripts + OPA; 4/6 reuse the test runner + oasdiff/Pact; 5/7 are agent critics), and the spec lifecycle state (an extension of the Orchestrator). Modest glue — most of the hard gates *reuse* the Verifier's execution machinery.

---

## Doctrine

1. **Three alignments, three owners** — spec⟷problem is human; spec⟷system is the KB; spec⟷code is the Verifier. Don't blur them.
2. **Resolve up before committing down** — never guess on behavior-affecting ambiguity; ask a closed question.
3. **Cite or it isn't true** — every claim about the current system links to a KB entity that exists (or the claim is rejected).
4. **Testable by construction** — a criterion that can't become a red test is not a criterion.
5. **Non-goals bound the blast radius** — spec what it will *not* do, explicitly.
6. **Generator ≠ critic** — an independent adversary must fail to break the spec before it advances.
7. **The human keeps the top gate** — "does this solve the problem" is never auto-approved.
8. **The spec is the Intent KB** — an active spec is a first-class, drift-watched KB entry, not a throwaway ticket.

---

## Design decisions

**Decided:**

1. **Acceptance-criteria format — Gherkin/BDD.** ✅ Markdown spec + Given/When/Then criteria. Maps 1:1 to executable tests, human-readable, well-tooled. This is what makes gate 4 (testable-by-construction) clean and deterministic — each `Then` becomes a red test.
2. **Spec altitude — two altitudes.** ✅ A product **epic-spec** humans ratify for *intent* (once), decomposed into technical **unit-specs** the machine validates for *correctness* (many). Humans ratify intent once; the machine validates every unit. This maps the two altitudes directly onto the two human/machine alignments: epic-spec ⟷ problem (human, gate 9), unit-spec ⟷ system (machine, gates 1–8).

**Still open (lower stakes):**

3. **Elicitation autonomy** — how hard Clarify pushes. *Recommended:* block on any *behavior-affecting* ambiguity, auto-resolve only cosmetic/naming gaps with a logged assumption the human can veto.
4. **Product-intent validation** — can "does this solve the problem" ever be automated? *Recommended:* **no, permanently human** — the deliberate seam that keeps the system honest, and cheap (one ratification per epic-spec).

## Phase 0 scope

For the thin slice: **manual triage** (a human picks the module and writes the problem statement), Spec Agent + one Critic, gates **1–4 + 8 + 9** (defer the full completeness critic and Pact-seam conformance to Phase 1), Gherkin criteria, human ratifies every spec, plus **write-back-on-ship** so the KB is current from the first merge. Prove the *problem → grounded → testable → ratified → build* loop on one low-risk enhancement before widening.
