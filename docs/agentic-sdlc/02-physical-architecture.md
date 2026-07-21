# Agentic SDLC — Physical / Deployment Architecture

**Date:** 2026-07-11
**Purpose:** The *physical* view — actual services, where they run, network/trust zones, and data flows — for the agentic SDLC on your real infrastructure.

## Confirmed infrastructure (from session)

| Concern | Reality |
|---|---|
| Backend | **Azure App Service** (Node monolith API) |
| Web | Next.js on **Azure App Service** |
| Mobile | React Native → App Store / Play Store, built via **Azure Pipelines** |
| Database | **MongoDB Atlas on Azure** *(tentative)* |
| Work tracking | **JIRA** — the work-item hierarchy (Epics → Features → Stories → Tasks → Bugs); also the agent trigger / ratification / escalation surface (webhooks + REST API + automation rules) |
| SCM + CI/CD | **Azure DevOps** (Repos + Pipelines) |
| Model access | **External frontier APIs allowed** (Anthropic / OpenAI) under DPA |
| Agent workers | **Azure-native, in-tenant** (ephemeral) |
| Observability | **PostHog** + own event framework (WIP) + **Mongo change-streams → audit collection** + code-based event logging in Mongo + **custom telemetry dashboard** |
| Feature flags | **Homegrown / internal feature-flag service** |
| Compliance | **India — RBI / SEBI / DPDP**; India-region residency |

## The compliance envelope: this is a *code-development* system

**Confirmed:** agents operate on **source code and specs only — no production customer or financial data is ever sent to a model.** This is a code-development system, not a data-processing one.

That collapses the hard part of RBI/DPDP: **data-localization does not bind the model calls at all**, because no regulated data is in the model context. Regulated data (payments, PII, investor records) stays entirely inside Zone 1 in India and is never touched by the agentic planes.

What remains is lighter and different in kind:

- **Source-code confidentiality (IP), not data residency.** Code leaving the tenant for inference is an IP/confidentiality matter — handled by the model provider **DPA + zero-data-retention / no-training terms**, not by localization law.
- **Secret hygiene.** The Model Gateway scrubs credentials, API keys, and connection strings from code context before egress — standard practice, not a finance-PII burden.
- **Blast radius remains a *safety* guarantee** (agents can't reach money-movement/PII code paths), now decoupled from the data-localization argument.

> When you later want zero egress anyway (Sovereign-AI thread), the Model Gateway swaps to Azure-OpenAI-in-India or a self-hosted model — no rearchitecting. But it's an *IP/cost* choice now, not a *compliance* mandate.

---

## The isolation invariant (hard rule)

> **The agentic SDLC system shares NO runtime infrastructure with the application, at any stage.** Its brains, its stores, and its workers are its own. The two systems exchange *artifacts and signals across explicit, audited seams* — they never share a database, cluster, compute, VNet trust boundary, or secret store.

This is a security and blast-radius guarantee: a compromised or misbehaving agent cannot reach into application data or infrastructure, because there is no shared resource to reach through. Every touch is one of exactly three kinds:

| Category | Rule | Examples |
|---|---|---|
| **Shared infra** | **Forbidden** | same DB/cluster, same compute, same VNet trust, one secret vault serving both |
| **Seam** (artifact/signal exchange) | **Allowed, audited, least-privilege** | repo checkout (code *in*), CI/CD deploy service connection (artifact *out*), scoped **read-only** telemetry export (signal *in*) |
| **Deploy target** | **Inherent** | the app's staging slot is *where agent output lands* via the deploy seam — not shared operational infra |

**What this forces (and corrects earlier convenience choices):**
- The **KB semantic index, spec state, traceability links, audit ledger, episodic memory, and eval datasets** all live in the **agentic plane's own dedicated data store** (its own Atlas/Mongo cluster) — **never** the application's production Atlas cluster.
- The **KB is *derived from* the app's source code** (read via the repo seam) but **stored in the agentic plane's own infra**. Derivation across a seam, storage in isolation.
- The **Monitor** reads production telemetry through a **scoped, read-only export/API seam** — it does not query the app's primary datastore and holds no write access to Zone 1.
- **Secrets are separated:** the agentic plane has its *own* Key Vault; it never shares the application's.

**On the single subscription (A3):** one subscription is acceptable *while on credits* only because isolation is enforced at the **resource level** — dedicated resource group, VNet, data cluster, compute, and managed identities, nothing shared. A **separate subscription is the stronger enforcement** and the hardening step once past credits. Subscription-sharing ≠ infra-sharing; resource-sharing is what the invariant forbids.

---

## Trust zones (physical layout)

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│  ZONE 0 — PUBLIC EDGE                                                               │
│  Azure Front Door + WAF  →  Web (Next.js)   Mobile (React Native, via stores)       │
└───────────────────────────────┬──────────────────────────────────────────────────┘
                                 │ private
┌───────────────────────────────▼──────────────────────────────────────────────────┐
│  ZONE 1 — PRODUCTION (VNet + resource group, South India; backups only, no DR yet)   │
│  ┌───────────────┐   ┌──────────────────┐   ┌───────────────┐   ┌────────────────┐ │
│  │ App Service    │   │ App Service      │   │ Internal       │   │ Azure Key      │ │
│  │ (Node monolith │   │ slots: prod /    │   │ feature-flag   │   │ Vault          │ │
│  │  API)          │   │ staging (canary) │   │ service (own)  │   │ (secrets, MI)  │ │
│  └──────┬─────────┘   └──────────────────┘   └───────────────┘   └────────────────┘ │
│         │ private endpoint / peering                                                │
│  ┌──────▼───────────────────────────────────────────────────────────────────────┐ │
│  │ MongoDB Atlas (Azure, India region) — APPLICATION CLUSTER (agents never touch)  │ │
│  │  • app data   • app audit collection (change streams)   • event/telemetry logs │ │
│  └────────────────────────────────────────────────────────────────────────────────┘ │
│  Telemetry: PostHog (product analytics) · custom dashboard over Mongo telemetry     │
└───────────────────────────────┬──────────────────────────────────────────────────┘
              audit/telemetry read (scoped)         │ deploy via Azure DevOps service connection
                                 │                   ▲
┌───────────────────────────────▼───────────────────┴──────────────────────────────┐
│  ZONE 2 — AGENTIC CONTROL PLANE (own resource group + VNet, same sub, South India)   │
│  ┌────────────────┐  ┌───────────────┐  ┌──────────────┐  ┌───────────────────┐    │
│  │ Orchestrator   │  │ Event bus /   │  │ Own Key      │  │ JIRA webhook     │    │
│  │ (Container App,│  │ queue         │  │ Vault        │  │ ingress + Azure    │    │
│  │  Agent SDK,    │  │ Service Bus   │  │ (agentic     │  │ DevOps integration │    │
│  │  state machine)│  │               │  │  secrets)    │  │                    │    │
│  └───────┬────────┘  └───────────────┘  └──────────────┘  └───────────────────┘    │
│  ┌──────────────────────────────────────────────────────────────────────────────┐ │
│  │ DEDICATED agentic data cluster (own Atlas/Mongo — NOT the application cluster)  │ │
│  │  • KB vector index  • spec state  • spec↔code links  • audit ledger             │ │
│  │  • episodic memory  • eval datasets                                             │ │
│  └──────────────────────────────────────────────────────────────────────────────┘ │
│          │ dispatches jobs                                                          │
│  ┌───────▼──────────────────────────────────────────────────────────────────────┐ │
│  │ ZONE 3 — DATA PLANE: ephemeral sandboxed workers (ACI / Container Apps jobs)    │ │
│  │  one per stage-run · scoped managed identity · repo checkout · Z2 code-graph svc│ │
│  │  Coder = OpenHands/Cline · torn down after each run                             │ │
│  └───────────────┬────────────────────────────────────────────────────────────────┘ │
└──────────────────┼──────────────────────────────────────────────────────────────────┘
                   │ via Model Gateway (redaction + routing + budgets)
┌──────────────────▼──────────────────────────────────────────────────────────────────┐
│  ZONE 4 — EXTERNAL (egress under DPA)                                                 │
│  Anthropic API · OpenAI API   │   JIRA (SaaS)   │   Atlas control plane             │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

## Component inventory (what sits where, and why)

### Zone 0 — Public edge
- **Azure Front Door + WAF** — TLS, DDoS/WAF, routing to web and API. Mobile apps ship via App Store / Play Store and hit the same API behind Front Door.

### Zone 1 — Production (existing, unchanged by agents except as a deploy target)
- **App Service (Node monolith)** with **deployment slots** — `production` + `staging`. This is the linchpin of safe autonomous deploy: the Deployer agent pushes to the **staging slot**, runs a **canary** (slot traffic %), gates on metrics, then **slot-swaps** to production. Rollback = swap back, near-instant.
- **MongoDB Atlas (Azure, India region) — application cluster** via **private endpoint / VNet peering** — app data + the app's own **audit collection** (fed by Mongo **change streams**) + code-based **event/telemetry logs**. **The agentic system never connects to this cluster** (isolation invariant); the KB semantic index lives in the agentic plane's *own* cluster (Zone 2).
- **Internal feature-flag service (homegrown)** — dark launch + kill switch. The Deployer/Monitor agents integrate with it via its existing API; the module ships behind a flag and the kill switch is the instant-off. *(Worth confirming it exposes a programmatic API + per-flag targeting the agents can call.)*
- **Azure Key Vault** — secrets, backed by **managed identities** (no static creds in agents).
- **PostHog + custom dashboard** — product analytics and the human-facing telemetry view. The Monitor agent reads these signals through a **scoped, read-only export/API seam** — never a shared datastore connection into Zone 1.

### Zone 2 — Agentic control plane (own resource group + VNet; same subscription for now)
- **Orchestrator** — a small always-on **Azure Container App** running the Agent SDK state machine; holds no prod creds, touches no code directly.
- **Code-graph service (Serena)** — a **warm, always-on** Container App serving the structural code graph; ephemeral Zone-3 workers query it per run, it persists across them (`14` budgets it as always-on).
- **Dedicated agentic data cluster** — the agentic plane's **own Atlas/Mongo cluster** (never the application cluster) holding the **KB vector index, spec state, spec↔code traceability links, audit ledger, episodic memory, and eval datasets**. Reuses the app's *audit code-pattern*, not its *store*.
- **Event bus / queue** — **Azure Service Bus** for stage events + the dedicated cluster for pipeline state.
- **Own Key Vault** — the agentic plane holds its *own* secrets vault + managed identities; it never shares the application's Key Vault.
- **Audit ledger** — append-only collection in the dedicated cluster recording every prompt, decision, diff, deploy — the RBI/DPDP evidence trail.
- **JIRA ingress + Azure DevOps integration** — JIRA issue labeled `agent-ready` → **JIRA webhook** → orchestrator → creates **Azure DevOps** branch + PR → Pipelines run → status posted back to JIRA. This is the **JIRA↔Azure DevOps bridge**.

### Zone 3 — Data plane (ephemeral, in-tenant)
- **Sandboxed workers** — **Azure Container Instances** or **Container Apps jobs**, one per stage-run, each with a **scoped managed identity** (Coder can edit code but cannot deploy; Deployer can deploy but cannot edit). Repo checked out inside; workers query the **Serena code-graph warm service in Zone 2** — the structural graph persists across runs, only the stage-workers are ephemeral. Coder stage = **OpenHands / Cline**. Torn down after each run — nothing persists in the worker.

### Zone 4 — External (egress under DPA)
- **Anthropic / OpenAI APIs** — reached *only* through the **Model Gateway**, which **redacts** secrets/PII, enforces per-stage token budgets, and is the single seam where **foundation → Azure-OpenAI-India → sovereign** becomes a config change.
- **JIRA** (SaaS tickets), **Atlas control plane**.

## Key data flows

1. **Trigger:** JIRA `agent-ready` → webhook → Orchestrator (Zone 2).
2. **Work:** Orchestrator spins an ephemeral worker (Zone 3) per stage; worker checks out Azure DevOps repo, queries Serena + Atlas Vector KB, calls models via the Gateway (Zone 4, redacted).
3. **Gate:** each stage output hits a guardrail (tests, policy/OPA, spec-conformance, blast-radius) in Azure Pipelines; pass → advance, fail → escalate to human in JIRA.
4. **Deploy:** Deployer → Azure DevOps release → App Service **staging slot** → canary → metrics gate (PostHog + Mongo telemetry + App Insights) → **slot-swap to prod** (or swap-back = rollback).
5. **Monitor & close loop:** Monitor agent watches telemetry; regression → auto-rollback + new JIRA ticket. **KB re-synced on merge; audit ledger written throughout.**

## CI/CD path (Azure DevOps)
Repos (Azure DevOps) → Pipelines: build → test/coverage gate → policy gate (OPA/Conftest) → spec-conformance (Verifier + oasdiff) → deploy to staging slot → canary → swap. All pipeline runs and gate decisions stream to the audit ledger.

---

## Decisions — confirmed

- **A1 · Web hosting:** ✅ Next.js on **Azure App Service**.
- **A2 · Mobile CI:** ✅ React Native built via **Azure Pipelines** → App Store / Play Store.
- **A3 · Isolation:** ✅ **Single Azure subscription for now** (Azure credits). Agentic planes are isolated *logically* — separate **resource group + VNet + managed identities** — not by subscription. → *Hardening step later: split the agentic planes into their own subscription once past credits/pilot.*
- **A4 · Region:** ✅ **South India** (single region). **No production DR yet** — database backups are in place, but no multi-region failover. → *Known gap, tracked; not blocking Phase 0.*
- **A5 · Deploy path:** ✅ **Staging slot → slot-swap to prod** (with canary/kill-switch via the internal flag service).
- **A6 · Compliance stance:** ✅ Code-development system; agents receive **code + specs only, never prod/finance data**. Residual controls = provider DPA/no-train + secret scrubbing at the Gateway.

## Two flagged gaps (not blockers, but on the record)

1. **No DR** — single-region South India with DB backups only. Fine for a Phase-0 pilot; revisit before agents own production-critical modules.
2. **Single subscription** — acceptable while on credits, but the agentic control/data planes should eventually move to a dedicated subscription for hard blast-radius isolation and separate billing/quota.
