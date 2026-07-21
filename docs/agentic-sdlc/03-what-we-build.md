# Agentic SDLC — What We Actually Build (and Where It Runs)

**Date:** 2026-07-11
**Purpose:** A durable way to reason about the system, and a precise inventory of the *net-new* components — how each runs and where.

## How to reason about the whole system

Every part of this system is exactly one of three things. When you're unsure where something belongs or whether to build it, sort it into this bucket first:

| Bucket | What it is | Do you build it? |
|---|---|---|
| **Rails** | Your existing production — monolith, MongoDB, flag service, telemetry, Azure DevOps | **No.** Agents deploy *onto* it; untouched otherwise. |
| **Rented brains & tools** | Foundation models + OSS: OpenHands/Cline (Coder), Serena (code graph), OPA (policy), sandbox runtime | **No.** You *configure/wrap* them. |
| **Your harness** | The glue that turns rented brains into a safe, autonomous pipeline on your rails | **Yes.** This is the whole job. |

And your harness is itself only **three kinds of thing** — this is the mental model to keep:

> **① A conductor** — decides what runs next (the orchestrator).
> **② Gates** — decide pass / fail / escalate (the guardrails).
> **③ Memory-keepers** — keep truth coherent (audit ledger, KB sync, drift reconciler).
> Everything else is *plumbing* between these and the outside world (JIRA bridge, model gateway).

If a proposed component isn't a conductor, a gate, a memory-keeper, or plumbing — question whether you need it.

The second axis that tells you **where** a thing runs:

> **Brain vs hands.** The *brain* (deciding, remembering) is **persistent and trusted** — it holds state but never touches code or prod data. The *hands* (writing code, running tests, deploying) are **ephemeral and sandboxed** — spun up per task, least privilege, torn down. Nothing is both.

---

## The net-new build list

Only these are genuinely ours to build. Everything else is Rails or Rented.

### ① The conductor

**Orchestrator** — the SDLC state machine.
- **What:** advances stages (Spec→…→Monitor), calls gates between them, routes escalations. Built *on* the Claude Agent SDK, but the SDLC-specific state machine is yours.
- **How it runs:** a long-running Node/TS service.
- **Where:** **Zone 2**, as an **Azure Container App** (always-on, scales low). Holds no code, no prod creds.
- **Lifecycle:** persistent.

### ② The gates (guardrails)

These are small, independent checks. Most run as **Azure Pipelines steps** (ephemeral, per-run); the orchestrator also calls some as a library.

| Gate | What it decides | Built on |
|---|---|---|
| **Blast-radius check** | Diff stays inside the module dir, else hard-fail | bespoke script |
| **Policy engine** | Escalate on auth/payments/PII/migrations/deps/oversized diff | **OPA/Rego** — *you write the policies* |
| **Spec-conformance gate** | Diff satisfies the spec's acceptance criteria | bespoke + **oasdiff** for API surface |
| **Canary + rollback** | Staging-slot metrics healthy → swap; else swap back | App Service slots + your metric thresholds |

- **Where:** **Zone 3 / Azure Pipelines** (ephemeral). Rego policies live in the repo as code.
- **Lifecycle:** ephemeral (run per stage/deploy).

### ③ The memory-keepers

**Audit ledger** — the regulatory evidence trail.
- **What:** append-only record of every prompt, decision, diff, deploy. A thin writer library each stage calls + the store.
- **How/where:** an **append-only collection in the agentic plane's dedicated cluster** (reuses the app's audit *code-pattern*, not its store — isolation invariant, `02`) in **Zone 2**; the writer lib is imported by orchestrator + workers.
- **Lifecycle:** persistent data; the lib runs wherever a stage runs.

**Drift Reconciler** — the moat.
- **What:** maintains bidirectional spec↔code traceability links; on every merge (and on a cron) detects divergence (orphan code, stale spec, unverified criteria) and opens JIRA tickets.
- **How it runs:** a job that reads the **Serena** graph + spec store + **oasdiff/Pact**, computes links, writes drift findings.
- **Where:** **Zone 2**, as a **Container Apps job** — triggered on merge (from Pipelines) and on a schedule.
- **Lifecycle:** ephemeral runs, persistent link store (in Mongo).

**KB immune-system jobs** — keep ratified knowledge honest (`05`).
- **What:** two small siblings of the Reconciler: **sampled re-verification** (re-run archaeology on a random sample of ratified KB entries each cycle) and a **telemetry-contradiction watcher** (prod behavior disagreeing with a KB claim auto-demotes the entry to hypothesis).
- **When:** land with the Reconciler in **Phase 1**; the demotion lifecycle field + write-back-on-ship are **Phase 0**.
- **Lifecycle:** ephemeral runs.

**KB sync (indexer)** — keeps the code knowledge current.
- **What:** on every merge, incrementally re-parse changed files (Serena) and re-embed changed chunks into the vector index.
- **How/where:** a **Pipelines job on merge** (ephemeral); writes to the **agentic plane's own Atlas Vector Search cluster** (Zone 2, dedicated — *not* the application DB; isolation invariant, `02`). The code is read across the repo seam; the index is stored in isolation.
- **Note:** mostly *wiring* around adopted tools — Serena does the parsing, Atlas does the vectors. You build the incremental-sync trigger.

### Plumbing (integration glue)

**Model Gateway** — the single seam to external models.
- **What:** every agent model call goes through it — scrubs secrets from context, routes by stage, enforces token budgets, records spend. The one place foundation→sovereign is a config change.
- **How/where:** a small proxy service, **Azure Container App**, sitting at the **Zone 3 → Zone 4** boundary.
- **Lifecycle:** persistent.

**JIRA ⇄ Azure DevOps bridge** — the trigger + escalation path.
- **What:** JIRA `agent-ready` webhook → orchestrator kicks off a loop → creates branch + PR in Azure DevOps → posts status/escalations back to JIRA.
- **How/where:** a webhook listener + API client, part of the orchestrator (or a small **Container App / Function**) in **Zone 2**.
- **Lifecycle:** persistent (listener).

**Stage agent definitions** — the prompts/tools/schema per stage.
- **What:** PM, Spec, Plan, Verifier, Reviewer, Deployer, Monitor — each a configured agent (prompt + tools + output schema) on the Agent SDK. The **Coder** stage *wraps* OpenHands/Cline (adopted). The **PM** agent (`08`) prepends the pipeline (raw signal → problem statement) and runs at the lowest autonomy (L0–L1, human-ratified); the **Spec** agent (`06`) takes its ratified output.
- **How/where:** run as **ephemeral sandboxed workers** (ACI / Container Apps jobs) in **Zone 3**, dispatched by the orchestrator. The *definitions* are yours; the *runtime + coding intelligence* are adopted.
- **Lifecycle:** ephemeral (one worker per stage-run).

---

## Persistent vs ephemeral, at a glance

```
PERSISTENT  (Zone 2 · brain · Azure Container Apps — always-on, no code/prod-data access)
  • Orchestrator          • Model Gateway         • JIRA⇄ADO bridge

EPHEMERAL   (Zone 3 / Pipelines · hands · spun up per run, sandboxed, torn down)
  • Stage-agent workers   • Guardrail gates       • KB re-index (on merge)
  • Drift-reconciler runs (on merge + cron)

DATA        (persistent stores — agentic plane's OWN dedicated cluster, never the app DB)
  • Audit ledger + traceability links + episodic memory + eval datasets → dedicated cluster (Zone 2)
  • KB vector index → dedicated Atlas Vector Search cluster (Zone 2)   [derived from code via repo seam]
  • Spec-as-code + Rego policies → Azure DevOps repo
```

## What this means for scope

Of the net-new list, **only these are truly novel engineering**: the **Orchestrator** (conductor), the **Drift Reconciler** (moat), and the **Model Gateway** (seam). The rest — gates, audit writer, KB sync, JIRA bridge, stage definitions — are **modest glue** around adopted tools. That's the whole reason this is a *weeks-to-months* build, not a *rebuild-an-AI-platform* build.

**For Phase 0 (thin slice) you can defer even more:** ship with the Orchestrator, blast-radius + test + policy gates, the audit ledger, the Model Gateway, the JIRA bridge, and a single-agent Coder. The **Drift Reconciler and full KB sync can come in Phase 1** — Phase 0 proves the loop; the reconciler makes it durable at scale.

**Phase-0 minimum: write-back-on-ship.** The *continuous* spec↔code re-check defers, but every merged change updates the KB entries it touched — spec flips to ACTIVE, traceability links refresh, superseded claims demote — as part of the merge pipeline itself. The KB must never be *knowingly* stale: every downstream gate grounds in it, and gate 2 (`06`) fails on stale citations.
