# Agentic SDLC — Running-Cost Estimates (OpEx) · Conservative Budget

**Date:** 2026-07-12
**Purpose:** What it costs to *run* the system (build cost is `10`). **Deliberately conservative — every figure carries a ~30% contingency buffer over our engineering estimate**, so actuals should land *at or under* these numbers. The optimization levers (routing, caching, scoping) are **upside not yet priced in**. Safe to pitch.

> **Pitch line:** *Budget ~**$5–8k/month** for the pilot (near-zero cash while on Azure credits), scaling to ~**$20–40k/month** at full multi-module operation — with headroom already included and clear levers to come in under.*

## The one thing to internalise

> **Model tokens dominate; the Coder dominates the tokens; the Model Gateway is the dial.** Azure infra, storage, and SaaS are a small, roughly-fixed base. The whole curve is "runs/month × tokens/run × $/token."

## Why these numbers are conservative (say this in the pitch)

1. **+30% contingency** applied on top of the engineering estimate.
2. **Optimization levers excluded** — routing, caching, and scoped context (below) are proven multipliers we have *not* baked in. They're margin, not plan.
3. **Upper-lean ranges** — we assume more retries, more premium-model use, and lower caching hit-rates than we expect in practice.

The intent: the person you pitch should be **pleasantly surprised on the invoice**, never caught out.

---

## Pricing assumptions *(illustrative frontier tiers — replace with your contracted rates)*

| Tier | Use | ~Input /M | ~Output /M |
|---|---|---|---|
| **Premium** (Opus-class) | hardest reasoning only | ~$15 | ~$75 |
| **Strong** (Sonnet-class) | Coder, Spec, Design | ~$3 | ~$15 |
| **Cheap** (Haiku-class) | gates, simple stages, triage | ~$0.80 | ~$4 |
| **Embeddings** | KB index | ~$0.02–0.13 | — |

Agentic loops are **input-heavy** (constant context re-reads) and **prompt caching** cuts cached input ~90% — both are structural savings we've conservatively *under*-counted here.

---

## What is "1 run"?

> **1 run = one JIRA work item (a Story, Task, or Bug) taken from trigger to a merged, deployed change** — or to an escalation. It includes *every* agent stage for that item (spec → design → code → test → gates → review → deploy → monitor) **and all internal retries/iterations** (a looping Coder or a re-tried gate is *within* the run, not a new one).

- **Anchor:** 1 run ≈ **1 pull request ≈ 1 shipped change**.
- **Granularity:** per **Story/Task/Bug**, *not* per Epic — an Epic fans out into several runs.
- **"Runs/month" ≈ atomic build units/month** — the pilot's ~220/mo ≈ ~10 Stories/Tasks/Bugs/day.

> **A JIRA item isn't homogeneous — cost by *type*, not by ticket.** A Bug ≈ 1 simple run ($3–8); a Story ≈ 1 moderate run ($8–26); a **Feature/requirement = a define step + 3–15 child runs (~$50–500+)**; a **one-line problem statement = heavy elicitation → a Feature**. So `monthly ≈ Σ(atomic runs × per-run) + define overhead for Features/problems + evals + infra` — never "all items × a flat run cost." Full treatment in **`15` (Work-Item Taxonomy)**.

## Per-run cost *(one run = one ticket → prod · +30% contingency included)*

| Change type | ~Tokens/run | ~Cost/run (conservative) |
|---|---|---|
| **Simple** (small bug / enhancement) | 0.3–0.6 M | **$3–8** |
| **Moderate** (feature) | 0.8–1.5 M | **$8–26** |
| **Complex / new-system** | 2–4 M | **$32–90** |

Coder = 60–80% of run tokens; other stages split the rest; embeddings are pennies.

**Evals** (separate, lumpy): a 50-task seeded-defect + replay suite ≈ **$200–650 per full run**. Gate on change + sample on schedule — not per ticket.

---

## Monthly scenarios *(conservative)*

### Phase 0 — pilot (one module, ~10 runs/day → ~220/month)

| Line | ~Monthly (conservative) |
|---|---|
| Model tokens (runs) | $2,600–5,200 |
| Evals | $650–1,300 |
| Azure infra | $1,300–2,000 |
| **Total** | **~$5–8k/month** *(≈ near-zero cash while on Azure credits)* |

### Phase 2 — scaled (multi-module, ~50 runs/day → ~1,100/month)

| Line | ~Monthly (conservative) |
|---|---|
| Model tokens (runs) | $15,600–28,600 |
| Evals (frequent + scheduled) | $2,600–3,900 |
| Azure infra | $2,600–5,200 |
| **Total** | **~$21–38k/month** |

*Heavy volume (100+ runs/day, complex-heavy) can reach **~$45–55k/month** — which is exactly the point where self-hosted/sovereign models (Phase 3) start to pay off and cap the curve.*

---

## Azure infra breakdown *(the roughly-fixed base · +30%)*

| Component | ~Monthly | Note |
|---|---|---|
| Always-on Container Apps (Orchestrator, Gateway, bridge, code-graph warm service) | $400–1,200 | consumption / scale-to-low |
| Ephemeral ACI workers | $130–520 | ~$0.07–0.20/run — cheap vs tokens |
| Dedicated Atlas cluster (+ Vector Search) | $260–900 | isolation invariant → own instance |
| Service Bus · Key Vault · storage · egress | $130–520 | |
| Azure Pipelines (parallelism) | $50–260 | ~$40/parallel job |
| **Infra subtotal** | **~$1.5–3.5k/month** | App Service itself is *app* cost, not agentic |

Ephemeral compute is deliberately cheap — the cost is *thinking* (tokens), not containers.

---

## Cost-control levers — the upside NOT priced above *(ranked by impact)*

1. **Model routing (Gateway)** — premium only for hard reasoning; cheap tier for gates/triage. **~3–5× swing.**
2. **Prompt / context caching** — ~90%-off cached input on re-read-heavy loops. **~2–4×** on input.
3. **Scoped context** (structure-scoped retrieval + progressive disclosure, `05`/`12`) — feed the subgraph, not the repo. Compounds with caching.
4. **Per-stage token budgets (Gateway)** — hard ceiling caps runaway Coder loops (the #1 blow-out) — turns a $200 tail run into $30.
5. **Eval cadence** — gate on change + sample; don't full-eval every ticket.
6. **Incremental KB sync** — embed only changed chunks; flat as the repo grows.
7. **Right-size + spot ephemeral compute.**
8. **Sovereign/self-hosted (Phase 3)** — variable token cost → fixed GPU cost, economic above ~$25–30k/month sustained.

> Applied together, routing + caching + scoping realistically **halve-to-quarter** the naive bill — so the *real* run rate should sit meaningfully below the conservative figures above. That gap is your safety margin.

---

## The framing that matters: cost per shipped change

Even at conservative numbers, the marginal cost to ship a change is **~$3–90 + light human oversight** — tens of dollars for routine work. The pitch question isn't absolute cost, it's: **"is tens of dollars + a short review cheaper than the engineer-hours it replaces or accelerates?"** For routine, well-specified changes, dramatically yes. For novel/complex work the human stays in the loop and token cost rides alongside real engineering time rather than replacing it.

**Budget headline for the deck:**
- **Pilot:** ~$5–8k/month (near-zero on credits) to prove the per-change economics.
- **Scaled:** ~$20–40k/month for a multi-module autonomous operation.
- **Contingency:** already included (+30%); levers provide further downside protection.

## Caveats (state them — they build credibility)

- Pricing tiers are **illustrative**; contracted/committed-use rates and caching hit-rate move totals materially (usually **down**).
- **Volume is the dominant unknown** — costs scale ~linearly with run throughput.
- The **Coder's token appetite varies widely** by task/retries; ranges are wide on purpose. Phase-0 evals (`07`) will replace these estimates with *your* real per-change distribution within weeks.
- **Human oversight** (ratification/review) is a real operating cost not in the cloud figures — a fraction of an FTE at scale, shrinking per-change as autonomy climbs.
