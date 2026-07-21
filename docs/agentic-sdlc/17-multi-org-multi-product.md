# Agentic SDLC — Multi-Org, Multi-Product (Cells)

**Date:** 2026-07-13
**Purpose:** How the platform runs across **multiple organizations**, each with **multiple products** — the cell model, cloud portability, the platform factory, and per-product resolution of everything docs `00`–`16` previously assumed to be a singleton.

## The requirement, precisely

1. **Trust spectrum** — internal business units first, then partner orgs, then external customer orgs. An org boundary must therefore be a *security and compliance boundary by construction*, not a label.
2. **BYO, heterogeneous within an org** — every org brings its own tool estate (tracker, SCM, cloud, telemetry, model endpoints), **and** products within one org may differ from each other. Nothing binds at the org level that can vary per product.
3. **Multi-cloud** — orgs live on different clouds (Azure, AWS, GCP, on-prem). The agentic plane deploys into *the org's* cloud.
4. **Few orgs now, self-serve later** — a central platform team onboards orgs today; the tenancy model must admit a self-serve console later **without migration**.

## The decision: one org = one cell, totally disconnected

A **cell** is the *entire* agentic plane of docs `02`/`13` — Orchestrator, Model Gateway, event bus, stage agents, gates, all five memory layers, audit ledger, eval harness, dedicated store — deployed as one self-contained unit **into the org's own cloud**. One cell per org. A cell holds exactly one org's data, credentials, and model keys.

> **The tenancy invariant:** there is **no network path between cells** and no shared runtime component. Blast radius, data residency, and the compliance boundary are settled by construction, not by policy. The only thing that ever crosses an org boundary is a **signed release artifact** (see the factory, below).

Internal-BU, partner, and external-customer cells run **identical software** — they differ only in *placement* (which cloud/subscription) and *policy pack*. That is what makes the trust spectrum a configuration axis instead of three architectures.

Zones survive unchanged *inside* each cell: Z0–Z1 are the org's rails, Z2 the cell's persistent brain, Z3 its per-run hands, Z4 its external seams. The isolation invariant of `02` (agentic plane never touches the app cluster) now holds **per cell**.

```
                 PLATFORM FACTORY  (build & sign — never a runtime)
                 images · agent defs · skill packs · policy baselines · eval suites
                        │ pull (GitOps, pinned versions) — nothing dials home
      ┌─────────────────┼──────────────────────┬─────────────────────┐
      ▼                 ▼                      ▼                     ▼
 CELL org-A (Azure)  CELL org-B (AWS)     CELL org-C (Azure)    CELL org-D (on-prem)
 internal BU         partner              external customer      external customer
 [Z2 brain·Z3 hands  [same software,      [same software,        [same software,
  stores·gates]       different cloud]     stricter policy pack]  their iron]
  ├ product P1        ├ product P1         ├ product P1           └ product P1
  ├ product P2        └ product P2         ├ product P2
  └ product P3                             └ product P3
      ×───────────────×──────────────────────×─────────────────────×
                     NO network path between cells
```

## Cloud portability — Kubernetes substrate, portable dependencies

The same cell must run on any cloud, so the Azure-native picks of `02`/`13` stop being load-bearing:

| Concern | Was (Azure-native) | Becomes (portable) |
|---|---|---|
| Z2 persistent services | Container Apps | **Kubernetes Deployments** (AKS/EKS/GKE/on-prem) |
| Z3 ephemeral sandboxes | ACI / Container Apps Jobs | **Kubernetes Jobs** — per-run pod, scoped ServiceAccount, torn down |
| Event bus | Azure Service Bus | **NATS (or Redis Streams) in-cell** — no cloud dependency |
| Dedicated store + vector | Atlas/Mongo | **MongoDB Atlas** (already multi-cloud) or self-managed Mongo — unchanged choice, portable by luck of the draw |
| Secrets | Azure Key Vault | **`SecretStore` interface** — drivers for Key Vault / AWS Secrets Manager / HashiCorp Vault |
| CI for the cell itself | Azure Pipelines | Org's CI via GitOps (Argo/Flux) pulling factory releases |

Cloud-nativeness is allowed to survive in exactly **one** place: the org's **deploy targets** (their actual app infrastructure) — which were always reached through the deploy seam, now a deploy *adapter* (below).

## The platform factory — the only shared plane, and it ships artifacts, not connections

What replaces a shared control plane is a **build-and-distribution pipeline** owned by the platform team. It produces **signed, versioned release artifacts**:

- container images (orchestrator, gateway, workers, gates)
- **agent definitions** (`08`, `06`, `11`) and **skill packs** (the vetted procedural memory, `12`)
- **OPA policy baselines** (the non-negotiable platform guardrails)
- **eval suites** (`07`) — platform benchmarks shipped in; run *in-cell* against the org's own golden sets
- connector adapters (below)

Cells **pull** pinned releases through their own CI. Nothing dials home; fleet-health telemetry back to the platform team is **opt-in and ops-metadata only**. Skills and policies are the only knowledge that crosses org boundaries — they are code, centrally curated, and **eval-gated inside each cell before activation**. Episodic memory, code graphs, specs, and audit ledgers **never leave the cell**.

**Upgrades are org-paced:** a cell pulls a release, runs the shipped eval suite against its own datasets, promotes on pass. The platform team operates a fleet of *versions*, not a fleet of *tenants*.

## Inside a cell — org → products, nothing assumed uniform

Net-new component: the **Org Registry** (Z2 · store + small API · **Build**) — the in-cell root of resolution. For the org it holds the product list; **per product** it holds:

1. **Connector bindings** — which tracker/SCM/deploy/telemetry adapter + credential reference (in the cell's own `SecretStore`).
2. **Product profile** — stack, build/test commands, deploy recipe, environments. This replaces the hard-wired Node-monolith assumptions in Coder/Verifier/Deployer (`13` §2): stage agents read the profile, not a constant.
3. **Policy pack** — layered **platform baseline → org → product** (OPA composes this naturally). Baseline rules (auth/payments/PII escalation, blast-radius) cannot be weakened downstream, only tightened.
4. **Budgets** — per-product token/spend caps enforced at the Model Gateway; per-product queues at the orchestrator so one product cannot starve another.

**Memory is namespaced by product.** Code graph, semantic index, intent KB, episodic memory, and audit-ledger partitions all key on `product`. This *strengthens* `05`'s structure-scoped retrieval: product is simply the outermost scope (product → module → file → symbol). Episodic lessons are **product-scoped by default, org-shareable opt-in** (a lesson about a shared internal library is org-useful; a lesson about product internals is noise elsewhere) — and **never cross the cell boundary**.

**One orchestrator, many products.** Runs are tagged `(product, work-item)`; gates resolve their configuration through the registry; the audit ledger records the product on every entry so the compliance trail is per-product separable.

## Connectors — the bridge becomes an adapter family, bound per product

The JIRA⇄ADO bridge (`13` §1) generalizes to four adapter interfaces, shipped by the factory, **bound per product** in the registry:

| Adapter | Implementations (initial) | Seam it owns |
|---|---|---|
| **Tracker** | JIRA · ADO Boards · Linear · GitHub Issues | work-item ingress, status/escalation egress |
| **SCM** | ADO Repos · GitHub · GitLab · Bitbucket | branch/PR create, checkout into Z3 |
| **Deploy** | App Service slots · ECS · Kubernetes · serverless | staging push, canary, flag flip, rollback |
| **Telemetry** | PostHog · Datadog · CloudWatch | read-only production signals for Monitor |

The **Model Gateway** stays per-cell and speaks to *the org's own* model endpoints and keys (Azure OpenAI in their tenant, Bedrock on AWS, sovereign models later — the `00` foundation→sovereign flip is now per-org). It meters spend per product — which is the **billing meter, ready-made** for the self-serve future.

## Lifecycle — runbook now, console later

- **Now:** the platform team provisions a cell from **Terraform + Helm per cloud** (a runbook): cluster, store, vault wiring, registry seeded, connectors bound, seeding pipeline (`04`) run per product.
- **Later (self-serve):** the *same artifacts* driven by an onboarding console that generates cell config. The Org Registry schema is the contract that makes this a UI problem, not a migration.
- **Offboarding:** destroy the cell; hand the org its audit ledger and spec state (their compliance property). Nothing to scrub from shared infra — there is none.

## Cell bootstrap — cold-starting a new product

The factory ships **process, not trust**. Agents, taxonomies, gate definitions, prompts, and skill packs travel across cells as signed artifacts. **Golden sets, judge calibrations, and earned auto-accept categories do not** — a judge calibrated on product A's labels is *uncalibrated* on product B. Trust is **cell-local**, re-earned per product, every time.

A new cell therefore starts in **reduced autonomy** — the Crawl/Walk tiers of `16` — and climbs by accumulating its own eval assets as a *byproduct* of dev-driven work, not as a prerequisite project.

**Graduation checklist to full autonomy (Run tier):**

1. **Golden spec set** curated from *this* product.
2. **Seeded-defect suite** covering every gate the cell ships.
3. **LLM-judge calibrated** against human labels from *this* product.
4. At least one claim category that has **earned auto-accept** via measured error rate (`04`).
5. **KB seeded and reconciled** on the target modules (`18`).

## The trade-off being accepted

Versus a shared control plane: per-org infrastructure cost (each cell carries its own brain and store), a real **fleet-upgrade discipline**, and **no cross-org learning from content** — only curated skills cross, as code, through the factory. That is the price of *totally disconnected*, and for a trust spectrum that ends at external customers on foreign clouds, it is the right price. Mitigation of the cost: a cell's persistent footprint is small (`14`) — the expensive part (Z3 runs, model spend) scales with usage, not with cell count.

## Doctrine (add to `04`/`05`'s list)

14. **One org, one cell, no wires** — org isolation is by construction; the only cross-org artifact is a signed release.
15. **Bind at the product, default at the org** — connectors, profiles, policies, and budgets resolve per product; org level only supplies defaults.
16. **Same software everywhere** — trust tiers and clouds change placement and policy packs, never the codebase.
17. **Learning crosses as code or not at all** — skills and policies travel through the factory, eval-gated in-cell; content memory never leaves.
18. **Trust is cell-local** — factory artifacts carry process across cells, never trust; every cell earns autonomy through its own eval assets.

## What this changes in earlier docs

- **`02` physical:** zones now instantiate per cell; Azure-native services get the portable substitutions above.
- **`03`/`13` build list:** **+ Org Registry** (build), **+ adapter family** (build interfaces, adopt SDKs), **+ platform factory** (build, mostly CI); JIRA⇄ADO bridge is subsumed by Tracker+SCM adapters.
- **`05` memory:** all layers namespaced by product; product becomes the outermost retrieval scope.
- **`07` evals:** suites are factory-shipped, run in-cell; release promotion is eval-gated per cell.
- **`12` skills:** skill packs become the factory's flagship cross-org artifact — versioned, signed, eval-gated in-cell.
- **`14` costs:** cost model becomes *per cell* (small persistent floor) + *per run* (dominant, usage-driven); Model Gateway metering is per product.
