# Agentic SDLC — Mission Control

**Date:** 2026-07-14
**Purpose:** The org's cockpit — a **bespoke, per-cell dashboard** where roadmap inputs (one-line problem statements, product docs, design docs, enhancements) enter the system, and where every work item can be watched and audited: type, time to build and ship, tokens burnt, cost, human touches, and production state — with drill-down from roadmap item to individual agent step.

**Decisions taken:** org-level scope, in-cell (one Mission Control per org, all its products, per-product filter — no cross-cell view, per `17`'s no-wires invariant) · both jobs on one surface (live ops + roadmap/economics) · **fully bespoke** app (rejected: BI/observability adoption — roadmap drill-down and intake are not a BI shape; rejected: hybrid Grafana embed — org metric stacks vary too much to standardize on one charting layer) · **metrics vary per org** — orgs bring different observability/analytics solutions, so org-specific metrics arrive through an adapter + catalog layer, and per-org integration work is an expected, contained cost.

---

## 1 · Position and scope

Mission Control is **read-only over projections, with exactly one write path: intake.** Submitting a problem statement / product doc / design doc / enhancement creates work items **through the tracker adapter** — the org's tracker remains the source of truth for work; Mission Control never becomes a second backlog. Everything else it shows is materialized from stores the architecture already mandates.

Two lenses, one surface:

- **Live ops** — what is running right now, what is **waiting on a human** (the org's daily to-do), what failed or escalated.
- **Roadmap & economics** — what shipped, how long it took, what it cost, and how it is doing in production.

## 2 · Data architecture — projections, never a new source of truth

A **Mission read-model projector** (Z2, persistent) subscribes to what already exists and materializes query-shaped views in the cell's store:

| Feed | Source (already designed) | Yields |
|---|---|---|
| Run/stage events | Orchestrator via event bus (`02`) | live state, stage timelines, retries |
| Token metering | Model Gateway (`02`/`17`) | tokens + spend, per run/stage/product |
| Decisions & artifacts | Audit ledger (`02`) | gate outcomes, human touches, artifact links |
| Work-item state | Tracker adapter (`17`) | ticket type/status/assignee |
| Deploy/flag state | Deploy adapter (`17`) | staged / canary / live / flag-off / rolled back |
| Production signals | **Metric-source adapters** (new, §4) | org-specific product & ops metrics |

Per the *framework-as-index, ledger-as-truth* doctrine (`05`): every projection is disposable and rebuildable from the ledger. Nothing writes metrics *into* Mission Control.

## 3 · The drill-down hierarchy

```
ROADMAP ITEM   (intake artifact: problem statement / design doc / enhancement)
  └─ WORK ITEM   (ticket · type: feature | bug | enhancement | debt | remediation-from-18)
       └─ RUN   (one orchestrated attempt)
            └─ STAGE EXECUTION   (PM → Spec → Design → Code → Verify → Review → Deploy → Monitor)
                 └─ AGENT STEP   (individual agent invocation, ledger-linked)
```

**Every level rolls up the same core facts:**

- **Time**, split **queued / active / waiting-on-human** — the split that shows where cycle time actually goes.
- **Tokens and cost** (currency, from gateway metering).
- **Gate outcomes and retry loops** (which gate failed, how many attempts).
- **Human touches** — escalations, ratifications, review rejections, manual edits.
- **Production state** — staged / canary / live / flag-off / rolled back.

So "this ticket took 6 h and $14" decomposes into "spec 20 min / $1.10 · coding took 3 runs because the verify gate failed twice · deploy waited 4 h on human review" — and each of those links to its ledger entries and artifacts (spec, diff, PR, deploy record).

## 4 · The metric framework — intrinsic vs org-specific

Two metric classes, deliberately held apart:

**Intrinsic metrics** — produced by the cell itself, **identical for every org, zero integration work**: tokens, spend, cycle time and stage breakdowns, gate pass rates, retry counts, rollback rate, cost-per-shipped-item, waiting-on-human time, adjudication-queue depth and ruling latency (`09`). Day-one metrics in every cell.

> **The headline metric is human leverage, not autonomy.** The goal is continuous build-and-monitor under a trust model whose top gate is *permanently* human (`06`) — so "% of items shipped with no human touch" is the wrong thing to maximize: it rewards the system for routing around the very touches that create its ground truth. Human touches split into two kinds, and the dashboard holds them apart:
> - **Intent touches** — ratifications, adjudication rulings, elicitation answers. The system's *fuel*: each becomes a durable KB fact (`09` capture-on-contact). Not overhead to eliminate — an input to make maximally productive.
> - **Failure touches** — correcting agent mistakes, re-explaining, unblocking, reworking rejected output. *Waste*; drive it down.
>
> Headline: **human-leverage ratio** — verified shipped work per human hour — with **failure-touch rate** as its quality counterpart. Autonomy rate stays available as a *diagnostic* (where does the fleet still lean on people?), never a target: rising leverage with stable intent touches and falling failure touches means the system is getting better; a rising autonomy rate alone might just mean it's asking less than it should.

**Org-specific metrics** — production and product signals from whatever the org already runs: Datadog, CloudWatch, Prometheus/Grafana, PostHog, Amplitude, homegrown. These arrive through **metric-source adapters** — the same pattern as `17`'s connector family (Tracker/SCM/Deploy/Telemetry), **bound per product**, shipped as factory artifacts. A per-org **metric catalog** (Org Registry extension) declares each metric: name, source adapter + query, unit, polarity (up-is-good/down-is-good), and which product/capability or roadmap item it attaches to (capability mapping via `18`'s concept registry where available).

> **Contained variability:** per-org integration work is expected — and it lands *only* in adapters and catalog entries. The app, the read model, and the intrinsic metrics never change per org. A new org with an exotic stack costs one adapter, not a fork.

The same adapters double as the **Monitor agent's** regression feed — one integration pays twice (dashboard + outcome loop).

## 5 · Screens

| Screen | Contents |
|---|---|
| **Roadmap board** | All roadmap items across the org's products; status, production state, cost/time to date; filter by product/type/state. |
| **Ticket drill-down** | Stage timeline with per-stage time/tokens/cost; artifact links (spec, diff, PR, deploy); gate history and retries; human touches; live production state; attached org-specific metrics. |
| **Live ops** | Stages running now; **waiting-on-human queue** front and center; recent failures/escalations; per-product queue depth. |
| **Economics** | Spend per product/period; cost per shipped item; trends; **budget-vs-actual** against per-product budgets in the Org Registry (`17`). |
| **Intake** | Submit problem statement / docs / enhancements; watch them decompose into tickets (via tracker adapter) and enter the pipeline. |

## 6 · Component fit

Net-new, in `13`'s terms — all in-cell, all factory-shipped (`17`):

| Component | Zone | Kind | Build/Adopt |
|---|---|---|---|
| Mission read-model projector | Z2 persistent | event consumer → store | **Build** (thin) |
| Mission Control app | Z2 persistent | web app + API | **Build** |
| Metric-source adapter family | Z2 persistent | per-product connectors | Build interface, **adopt SDKs** |
| Metric catalog | Org Registry extension | config/schema | **Build** (schema only) |

Auth rides the org's IdP (cell's Z0 rails). Nothing crosses the cell boundary; the platform team sees an org's Mission Control only inside that org's cell. The opt-in fleet telemetry of `17` remains ops-metadata aggregates and is *not* fed from this read model's content.

## Doctrine (add to the running list)

23. **One write path** — Mission Control ingests intent (intake) and displays truth (projections); it never becomes a second source of truth for work or metrics.
24. **Intrinsic everywhere, specific by adapter** — metrics every org gets for free are computed in-cell from the ledger; org-varying metrics enter only through cataloged adapters, so variability never touches the app.
25. **Every number drills to the ledger** — any figure on the dashboard must decompose, level by level, down to auditable ledger entries; no unexplainable aggregates.

## What this changes in earlier docs

- **`13` component view:** + the four components above.
- **`17` cells:** adapter family gains **metric-source adapters**; Org Registry gains the **metric catalog**; factory ships app + projector + adapters; onboarding runbook gains a "wire the org's metrics" step (the expected integration work).
- **`14` costs:** intrinsic metrics operationalize the cost model — spend is now visible per org/product/ticket/stage in real time.
- **`18` intent:** remediation tickets born from divergence rulings appear on the roadmap board typed `remediation`, so the founder watches archaeology debt burn down on the same surface as new features.
