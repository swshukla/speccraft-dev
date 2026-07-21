# Agentic SDLC — Component View

**Date:** 2026-07-12
**Purpose:** The authoritative catalog of every component — what it does, where it runs, its lifecycle, and whether we build or adopt it. Consolidates docs `00`–`12`. (Logical diagram = relationships, physical = deployment, execution = motion; **this = the parts list.**)

## How to read it

**Zones** (`02`): **Z0** public edge · **Z1** production (app; agents never enter except as deploy target) · **Z2** agentic control plane (persistent “brain”) · **Z3** ephemeral data plane (per-run “hands”) · **Z4/ext** external seams.
**Lifecycle:** *Persistent* = always-on · *Ephemeral* = spawned per run, torn down · *Store* = durable data · *Scheduled* = cron/merge-triggered.
**Origin:** **Build** (ours) · **Adopt** (OSS/SaaS, configured) · **Rails** (existing, untouched).

> One-line mental model: **persistent brain in Z2, ephemeral hands in Z3, all agentic data in one dedicated cluster, rails in Z1 untouched — and every cross-boundary touch is a seam, never shared infra.**

---

## 1 · Orchestration & control  *(Z2 · persistent · the conductor + plumbing)*

| Component | What it does | Where it runs | Origin |
|---|---|---|---|
| **Orchestrator** | The SDLC state machine — advances stages (PM→…→Monitor), calls gates between them, routes escalations, admits/aborts runs. | Z2 · Azure Container App + Agent SDK · persistent | **Build** |
| **Model Gateway** | The single egress seam to models — redacts secrets, routes by stage, enforces token budgets, records spend, the one place foundation→sovereign is a config flip. | Z2→Z4 boundary · Container App · persistent | **Build** |
| **JIRA ⇄ Azure DevOps bridge** | Webhook/automation ingress from JIRA (“Ready for Agent”), kicks off runs, creates branches/PRs, posts status/escalations back. | Z2 · Container App / Function · persistent | **Build** (glue) |
| **Event bus / queue** | Carries stage events + pipeline state between orchestrator and workers. | Z2 · Azure Service Bus · persistent | **Adopt** |

---

## 2 · Stage agents  *(Z3 · ephemeral · one worker per stage-run — definitions are ours, runtime/intelligence adopted)*

| Component | What it does | Where it runs | Origin |
|---|---|---|---|
| **PM Agent** (`08`) | Frames a problem, grounds it in evidence, proposes priority + success metric. Autonomy L0–L1. | Z3 · ephemeral worker | **Build** (def) |
| **Spec Agent** (`06`) | Generates the product spec + Gherkin criteria, runs the validation gauntlet. | Z3 · ephemeral | **Build** (def) |
| **Plan/Design Agent** (`11` A3) | Turns the spec (WHAT) into system design (HOW) — components, data model, seam contracts. | Z3 · ephemeral | **Build** (def) |
| **Coder** | Writes code + tests to satisfy spec+design inside the sandbox. | Z3 · ephemeral · **wraps OpenHands/Cline** | **Adopt**+wrap |
| **Verifier** | Runs tests (oracle = the spec-born acceptance tests from gate 4, `06` — never Coder-authored), checks spec-conformance, drives adversarial verification. | Z3 · ephemeral | **Build** (def)+adopt runner |
| **Reviewer** | Reviews the diff (quality/security) before merge; mounts review skills. | Z3 · ephemeral | **Build** (def) |
| **Deployer** | Pushes to staging slot, runs canary, flips the feature flag, rolls back. | Z3 · ephemeral | **Build** (def) |
| **Monitor** | Watches production telemetry (read-only seam), detects regressions, closes the outcome loop. | Z3/Z2 · ephemeral + scheduled | **Build** (def) |
| **Critic (adversarial)** | Independent refuter reused by Spec/Verify — generator ≠ critic, and **KB-anchored**: refutations ground in the ratified spec clauses / KB invariants the artifact claims to satisfy, cited like any other claim — never the generating agent's own framing. | Z3 · ephemeral | **Build** (def) |

---

## 3 · Gates & guardrails  *(Z3 / Azure Pipelines · ephemeral · the pass/fail deciders)*

| Component | What it does | Where it runs | Origin |
|---|---|---|---|
| **Spec-gauntlet scripts** | Deterministic spec checks — gates 1–3 of the 9-gate gauntlet (`06`): well-formed (schema), grounded (KB citation + freshness), consistent (conflict-detection vs the Intent KB). | Z3 / Pipelines · ephemeral | **Build** |
| **Blast-radius check** | Fails if the diff leaves the module’s allowed scope. | Z3 / Pipelines · ephemeral | **Build** |
| **Policy engine** | Escalates on auth/payments/PII/migrations/deps/oversized diffs. | Z3 · **OPA/Rego** (policies-as-code) | **Adopt**+write policies |
| **Spec-conformance gate** | Acceptance tests pass + API surface matches. | Z3 · bespoke + **oasdiff** | **Build**+adopt |
| **Contract tests** | Seam/integration conformance for new-system work. | Z3 · **Pact** | **Adopt** |
| **Canary + rollback** | Gates a slot on live metrics; swaps or reverts. | Z1 · App Service slots + thresholds | **Build** config |
| **Design review gate** | Human architecture sign-off for risky/new-system designs. | JIRA · human | **Build** process |
| **Code review gate** | *Optional* human PR approval (risk/confidence-driven). | ADO/JIRA · human | **Build** process |

> **Mapping to `06`'s 9-gate spec gauntlet** (the gauntlet numbering is the canonical vocabulary; these components implement it): gates **1–3** → Spec-gauntlet scripts · gates **4 + 6** (testable-by-construction, non-breaking/conforming) → Spec-conformance gate + Contract tests (test runner + oasdiff + Pact) · gates **5 + 7** (complete, adversarial refute) → the Critic agent (§2) · gate **8** (policy) → Policy engine · gate **9** (human ratification) → surfaced in the tracker, distinct from the Design/Code review gates. **Blast-radius, Canary + rollback, and the Design/Code review gates are diff-and-deploy gates, not spec gates** — they act on the built change after the gauntlet has validated the spec.

---

## 4 · Knowledge & memory  *(Z2 stores + a warm service — the three memory types)*

| Component | What it does | Where it runs | Origin |
|---|---|---|---|
| **Code-graph service** (structural / semantic memory) | Derives + serves the code graph (symbols/calls/refs). Warm indexer keeps it hot; materialized graph in the dedicated cluster; live view recomputed per-run in the sandbox. | Z2 warm service + dedicated cluster · Z3 live view · **Serena/LSP** | **Adopt** |
| **Semantic index** | Embeddings over code/docs/tickets for structure-scoped retrieval. | Z2 · **Atlas Vector Search** (dedicated cluster) | **Adopt** |
| **Intent KB** | Spec-as-code + bidirectional spec↔code traceability links. | repo + dedicated cluster | **Build** (links) |
| **Episodic memory** (`05`) | Lessons — what was tried, what failed, what’s fragile; check-before-act. | Z2 · dedicated cluster + vector | **Build** |
| **Skill Library** (procedural memory, `12`) | Versioned skills-as-code mounted per stage agent; vetted + eval-gated. | repo · loaded in Z3 workers | **Adopt**+curate |
| **KB-sync / indexer** | Incremental re-index on merge (∝ change) + periodic full rebuild backstop. | Z2/Pipelines · scheduled + on-merge | **Build** (glue) |
| **Drift Reconciler** (the moat) | Maintains spec↔code coherence (bi-temporal), detects drift, opens JIRA tickets. | Z2 · Container Apps job · scheduled/on-merge | **Build** |

---

## 5 · Evals  *(Z2 · batch + CI · protects competence over time)*

| Component | What it does | Where it runs | Origin |
|---|---|---|---|
| **Eval harness** (`07`) | Runs offline benchmarks (Coder replay, seeded-defect suite), regression-gates any prompt/model/gate/skill change. | Z2 · batch job + agentic CI | **Build** |
| **Eval datasets** | Golden specs, replayed PRs, seeded defects, judge-calibration labels. | Z2 · dedicated cluster (never app data) | **Build**/curate |
| **Online eval metrics** | Escalation/override/rollback/drift rates; gate-pass-then-fail-later. | Z2 · from audit ledger + telemetry seam | **Build** |

---

## 6 · Data stores & security  *(Z2 · the agentic plane’s OWN infra — isolation invariant)*

| Component | What it does | Where it runs | Origin |
|---|---|---|---|
| **Dedicated agentic cluster** | One store, agentic-owned, holds: materialized code graph, vector index, spec state, traceability links, audit ledger, episodic memory, eval datasets. **Never the app cluster.** | Z2 · own Atlas/Mongo | **Adopt** (own instance) |
| **Audit ledger** | Append-only record of every prompt/decision/diff/deploy — the RBI/DPDP evidence trail; source of truth for memory/evals. | Z2 · dedicated cluster | **Build** (writer) |
| **Own Key Vault** | Agentic secrets + managed identities; never shares the app’s vault. | Z2 · Azure Key Vault | **Adopt** |
| **Sandbox worker runtime** | Spawns per-run isolated containers (checkout, scoped MI, torn down). | Z3 · **ACI / Container Apps Jobs** | **Adopt**+config |

---

## 7 · Rails & external  *(Z0/Z1/Z4 — existing; agents reach them only via seams)*

| Component | Role | Where | Touch |
|---|---|---|---|
| **App Service** (monolith + slots) | Deploy target; canary via staging→prod slot swap. | Z1 | deploy seam |
| **Application Mongo Atlas** | App/customer/financial data. | Z1 | **none — agents never connect** |
| **Homegrown feature flags** | Dark launch + kill switch (needs programmatic API). | Z1 | Deployer via API |
| **PostHog / telemetry** | Product + system signals. | Z1→Z2 | **read-only** seam |
| **JIRA** | Work items (Epics→Bugs — taxonomy canonical in `15`) + trigger + human ratification surface. | ext | webhook/API seam |
| **Azure DevOps** (Repos + Pipelines) | SCM + CI/CD. | Z2→Z1 | repo + deploy seams |
| **Foundation models** (Claude/GPT) | The rented intelligence. | Z4 | via Model Gateway (code+spec only) |

---

## What’s actually ours to build (the short list)

Genuinely novel: **Orchestrator · Drift Reconciler · Spec-validation gauntlet · Model Gateway.** Everything else is **modest glue** (gates, bridge, audit writer, KB-sync, agent definitions, eval harness, skill curation) or **adopted** (Serena, OpenHands/Cline, OPA, oasdiff, Pact, Atlas, ACI, JIRA, Azure DevOps). That ratio is why this is a weeks-to-months build (`10`).

## Persistent vs ephemeral, at a glance

```
PERSISTENT (Z2 · brain · always-on, no code/prod-data access)
  Orchestrator · Model Gateway · JIRA⇄ADO bridge · Event bus · Code-graph warm service

EPHEMERAL  (Z3 · hands · per-run, sandboxed, torn down)
  All stage agents (PM→Monitor) · Gates · KB re-index (on merge) · Drift runs (merge+cron)

STORE      (Z2 · dedicated agentic cluster — never the app DB)
  Code graph · vector index · spec state · traceability links · audit ledger · episodic memory · eval datasets

RAILS      (Z1 / ext · untouched except via seams)
  App Service (+slots) · app Mongo · feature flags · telemetry · JIRA · Azure DevOps · foundation models
```
