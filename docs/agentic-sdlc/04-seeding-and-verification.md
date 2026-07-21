# Agentic SDLC — Seeding the System & Trusting the Specs

**Date:** 2026-07-11
**Purpose:** How the system cold-starts on the existing brownfield monolith — building the knowledge base, generating the first specs, and (the crux) *knowing the specs are right and the system isn't hallucinating.*

## The cold-start problem

On day one the system is blind: real code exists, but there are **no machine-readable specs, no traceability links, no KB.** You cannot run the autonomous loop until the KB exists *and is trusted*. So seeding = building the initial knowledge **and establishing warranted trust in it.**

The governing principle for the whole seed:

> **Seed in layers of increasing inference and decreasing certainty.** What can be *derived* from code (deterministic, cannot hallucinate) comes first and needs no verification. What must be *inferred* by a model (specs, intent) comes last and gets heavy verification. Never let an inferred claim enter the trusted KB unearned.

And the corollary that bounds cost and risk:

> **Seed the deterministic layer globally; seed the inferred layer incrementally, module by module, starting with the low-risk Phase-0 slice.** You do NOT reverse-engineer the whole monolith before starting.

---

## Seeding phases

### Seed-Phase 0 — Deterministic ingestion · *zero hallucination risk*
Pure machine derivation, no LLM judgment:
- **Code graph** (Serena / LSP / tree-sitter): symbols, call graph, imports, routes→handlers, Mongo collection shapes, dependency graph. 100% derived from code — **cannot hallucinate.** This is the skeleton every later layer hangs on.
- **Semantic index**: embed code, READMEs, comments, commit history, PRs, JIRA tickets, incident write-ups → the fuzzy-discovery layer (Atlas Vector Search).
- **Harvest ground-truth signals** — the gold: existing **tests** (their assertions are executable spec fragments), **type definitions**, any **OpenAPI/JSON schemas**, config, DB indexes. These are machine-checkable truth and become the anchors for verifying inferred specs later.

*Output:* a queryable KB skeleton. Fast (days). Nothing here can be wrong in a way a model caused.

### Seed-Phase 1 — Map & stratify · *understand structure before meaning*
- **Cluster** code into modules/domains (by directory, call-graph community detection, and git **co-change** history).
- **Rank** every module by change frequency (git), blast radius (graph centrality), test coverage, and **risk class** (auth / payments / PII / money-movement vs peripheral).
- This tells you two things: **where to start** (low-risk, well-tested, peripheral = the Phase-0 candidate) and **where to be careful** (never let early autonomy near high-risk modules).

*Output:* a risk-ranked module map. Mostly deterministic; LLM only labels clusters, and labels are human-glanceable.

### Seed-Phase 2 — Spec archaeology · *inference begins; hallucination risk begins*
Now — and only for the **one Phase-0 target module first**, not the whole codebase — an LLM **Spec Archaeologist** agent reads code + tests + docs and **reverse-engineers candidate specs**: what the module does, acceptance criteria, invariants, API contracts, domain rules.

The non-negotiable rule that keeps this honest:

> **Cite or it didn't happen.** Every spec statement must link to the specific evidence it came from — Serena symbols, test names, routes. A spec claim with no code citation is rejected on sight. Archaeology *reverse-engineers from evidence*; it does not *invent*.

*Output:* candidate specs — **untrusted** until Seed-Phase 3 clears them.

### Seed-Phase 3 — Verify & ratify · *how we know the specs are right*
Candidate specs pass through layered, independent checks (details in the next section). Survivors — tagged with confidence and provenance — enter the **trusted** KB with traceability links. Only now can the loop run on that module.

*Output:* first trusted spec set + spec↔code links. Then **widen archaeology module-by-module**, in risk-rank order.

---

## How we know the specs are right (and it's not hallucinating)

Not one check — **defense in depth.** A hallucinated spec claim has to survive *all* of these to be trusted, and any single failure flags it:

**1 · Grounding by citation.** Every claim links to concrete code/tests. Uncited → rejected. This makes hallucination *visible and checkable* instead of hidden in prose.

**2 · Verify by execution, not opinion — the strongest signal.** Anything a spec asserts that can be *run*, gets run against the real code:
- Spec says "endpoint X returns Y on Z" → there's a test, or one is generated and **executed**. Passes against real code → the claim is grounded in reality.
- **oasdiff** vs the actual route graph, **Pact** contracts, type-checking.
> **Running code cannot be fooled by a persuasive hallucination.** Prefer execution over any amount of model confidence.

**3 · Adversarial second opinion.** An *independent* agent (different model/prompt) tries to **refute** each claim — "find code that contradicts this invariant." Generator ≠ critic. Claim is accepted only if the refuter fails to break it (same 2-of-3-refutes-kills pattern the research phase used).

**4 · Triangulation against the deterministic layer.** Inferred claims must agree with what's *derived*: claimed API vs actual routes, claimed data model vs actual Mongo shapes, claimed deps vs the import graph. Divergence = the spec is wrong (or the code is surprising) → flag either way.

**5 · Confidence score + human ratification — auto-accept is *earned*, never granted.** Each claim scores on the signals above (cited? execution-verified? survived adversary? consistent with graph?). But model self-confidence cannot catch **confident errors** — the failure mode that matters is a claim that is wrong *and sure of itself*. So the gate is calibrated against outcomes, not assumed:
- **At seed time, every claim category is human-ratified.** No auto-accept on day one.
- **Auto-accept is earned per claim category** — once a category's measured error rate (human corrections ÷ claims reviewed) stays under threshold over a trailing window, it may auto-accept; a category that regresses loses the privilege.
- **High-risk (auth/payments/PII) never earns auto-accept** — a human always ratifies.
- Humans review a **ranked queue**, prioritized by *citation count × execution frequency × consequence class* — you review the load-bearing dozens, not thousands.

**6 · Provenance & staleness on every fact.** Each KB entry carries: *derived vs inferred*, evidence links, confidence, last-verified. Downstream agents **calibrate trust** — they never treat an unverified inference as ground truth.

**7 · Post-ratification immunity — ratified is not forever.** A canonical KB inverts a property human teams get for free: a team's errors are *decorrelated* (different heads disagree, and the disagreement surfaces mistakes), while a KB error is *perfectly correlated* — every agent cites the same wrong entry, and the citation discipline actively suppresses re-derivation. Since gate coverage is never total, a subtly wrong claim will eventually be ratified; trust must therefore be able to move **both ways** after ratification — sampled re-verification, telemetry contradiction detection, and a demotion path (mechanisms in `05`). The target is a **stationary** KB error rate — mistakes leak in, channels flush them out — not a perfect one.

---

## What builds the spec — two modes

"The Spec Agent" builds specs, but in two distinct moments, and the second is *much* easier to trust than the first:

| Mode | When | Trust basis |
|---|---|---|
| **Archaeology** (reverse) | Seed-time: infer specs from *existing* code | Hard — all six checks above; human ratifies the risky/uncertain |
| **Forward** (spec-first) | Run-time: write a spec for a *new* JIRA ticket *before* code exists | Easier — a **human wrote/approved the ticket intent**; the spec is checked against acceptance criteria the human confirms, and the code is then built *to* the spec and verified against it |

Both run on the Agent SDK; both must cite evidence and clear verification gates. The forward mode is the steady state; archaeology is the one-time (then incremental) bootstrap.

---

## Why run-time hallucination is also contained (not just at seed)

Trust isn't "established once at seed then assumed forever." **Every loop iteration re-grounds:**
- The **Coder** works on a *live checkout* — it cannot hallucinate the current code; it's reading reality.
- The **Verifier** runs tests — execution truth, every time — and its oracle is the **acceptance tests instantiated from the ratified spec *before* the Coder built** (gate 4, `06`). Coder-authored tests supplement that oracle, never replace it: the loop is never closed on tests written by the same agent whose work they judge.
- The **Critic** is KB-anchored: it refutes the diff against the *ratified spec clauses and invariants* it claims to satisfy — an independent reading of the contract, not a review of the Coder's own narrative.
- The **Drift Reconciler** continuously re-checks spec↔code coherence on every merge.
- A bad output must still pass **citation → execution → adversarial → policy gate → canary → monitor** before it reaches users.

> A hallucination has to defeat *defense in depth at every stage*, continuously — not fool a one-time trust decision. That's what makes autonomous-to-prod defensible.

---

## The anti-hallucination doctrine (memorize these)

1. **Derive → elicit → infer, never invent** — deterministic layers first; then *ask the human* for intent that was never written (`09`); let a model infer only as a last resort, tagged as a hypothesis.
2. **Cite or it didn't happen** — every inferred claim links to evidence.
3. **Verify by execution, not opinion** — run tests/contracts/types against real code.
4. **Adversarial second opinion** — independent refuter must fail; generator ≠ critic.
5. **Triangulate against the graph** — inferred claims must agree with derived structure.
6. **Earn auto-accept; rank for humans** — every claim category starts human-ratified; auto-accept is earned by a measured low error rate and revoked on regression; high-risk never earns it. Queues rank by citation count × execution frequency × consequence class.
7. **Provenance everywhere — and revocable** — tag derived/inferred, evidence, confidence, freshness; trust is calibrated, never blind, and ratified entries can be challenged and demoted (`05`).
8. **Seed low-risk first** — prove the process on peripheral, well-tested modules before auth/payments.

## Concrete seeding timeline

```
Days 1–3    Seed-0  Deterministic ingest (code graph + index + harvest tests/types)   → KB skeleton, no risk
Days 3–5    Seed-1  Cluster + risk-rank modules                                         → know where to start
Week 2      Seed-2  Spec archaeology on the ONE Phase-0 module only                     → candidate specs
Week 2–3    Seed-3  Verify (execution + adversarial + triangulate) + human ratify       → first trusted specs
Week 3+             Run the Phase-0 loop; then widen archaeology module-by-module, risk-ranked
```

*You reach a running, trusted slice in ~3 weeks without ever bulk-trusting an un-verified spec, and without reverse-engineering the whole monolith up front.*
