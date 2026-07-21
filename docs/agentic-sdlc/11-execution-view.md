# Agentic SDLC — End-to-End Execution View

**Date:** 2026-07-11
**Purpose:** One unit of work traced through the whole machine, across **two connected phases** — **A · Define** (problem → product spec → system design) and **B · Build & Ship** (spec+design → code → prod). Names the real technology and integration at each hop. This is the *motion* view (`system-diagram` = structure, `physical` = deployment). *(Earlier drafts started at an already-ratified spec; Phase A makes the spec and design generation explicit.)*

## The two phases

> **Phase A · Define** turns a fuzzy problem into a **ratified product spec + a system design** — mostly human-in-the-loop, JIRA-centric, low autonomy (`08`'s "autonomy inverts with altitude"). **Phase B · Build & Ship** takes that spec+design and executes it to production — mostly autonomous, gated. Phase A's output *is* Phase B's trigger.

## The flow at a glance

```
╔═ PHASE A · DEFINE ═ (JIRA · human-in-the-loop · low autonomy) ══════════════════════════════════╗
║ A1 Problem / JIRA Epic  ─►  PM Agent ──────────►  A2 Spec Agent ──────────►  A3 Plan/Design Agent ║
║  (or raw ask / bug)        frame · ground ·        ground vs KB · clarify      technical design:   ║
║                            prioritize · shape      (JIRA) · draft · decompose  components, data,   ║
║                                  │                 → Gherkin criteria          seams, test strategy║
║                                  ▼                        │                          │            ║
║                          human ratifies             9-gate gauntlet            grounded vs KB +    ║
║                          INTENT (epic-spec)         + human ratifies           optional DESIGN     ║
║                                                     → ACTIVE unit-spec          REVIEW (new-system)║
╚══════════════════════════════════ ratified spec + design ═══════════════════════╤════════════════╝
                                                                                   ▼  (Phase B trigger)
╔═ PHASE B · BUILD & SHIP ═ (ephemeral · gated · higher autonomy) ════════════════════════════════╗
║ B1 Trigger ─► B2 Spawn ACI ─► B3 checkout ─► B4 Coder ─► B5 sandbox tests ─► B6 gates ─► B7 PR    ║
║ (JIRA→bridge   (fresh, scoped  (repo seam)    (OpenHands/  (Gherkin+regr+    (OPA/spec/  (ADO +   ║
║  →Orchestrator) MI, per-run)                   Cline)       Pact/oasdiff)     adversary) Pipelines)║
║                                                                                   │              ║
║                    B8 OPTIONAL HUMAN REVIEW  ◄── L3 all-green → auto-merge ────────┤              ║
║                    (L2/high-risk → approve)                                        ▼              ║
║                    B9 deploy → App Service staging slot → flag OFF (dark) → canary → auto-rollback ║
║                    B10 Monitor (read-only seam) → KB re-sync + Drift + episodic + PM↔outcome → 💀  ║
╚══════════════════════════════════════════════════════════════════════════════════════════════════╝
```

---

# Phase A · Define — where spec & design are generated

### A1 · Problem intake & framing — the PM Agent
- **Source:** a **JIRA Epic/Feature**, a raw stakeholder ask, a support theme, or a **Bug** — often *just a problem*, sometimes only in your head (`09`).
- The **PM Agent** frames the real problem (symptom vs root cause), **grounds it in evidence** (telemetry via read-only seam, incidents, episodic memory — *cite or it's a hypothesis*), and **proposes** priority + a success metric.
- **Human ratifies INTENT** → an **epic-spec** on the JIRA Epic/Feature. Autonomy L0–L1: *you* decide what's worth building.
- *Integration:* JIRA (Epic/Feature), read-only telemetry seam, KB. *(doc `08`)*

### A2 · Product-spec generation & validation — the Spec Agent
- The **Spec Agent** takes the ratified problem and **grounds it against the KB** (structure-scoped retrieval), **clarifies** behavior-affecting ambiguity by asking closed questions on the **JIRA Story/Task**, **drafts** the spec (every current-system claim cited), and **decomposes** it into unit-specs with **Gherkin acceptance criteria**.
- It passes the **9-gate validation gauntlet** (well-formed · grounded · consistent · **testable-by-construction** · complete · non-breaking · adversarial · policy · human ratify).
- **Output:** an **ACTIVE unit-spec** — the contract. *This is where product-spec generation lives.*
- *Integration:* JIRA (Story/Task), Serena + Atlas KB, OPA, oasdiff/Pact, Model Gateway. *(doc `06`)*

### A3 · System-design generation — the Plan/Design Agent
- From the ACTIVE spec (the **WHAT**), the **Plan/Design Agent** produces the **HOW**: component/module design, data-model changes, **integration contracts at the seams** (new-system work), migration steps, and the test strategy.
- It is **grounded in and cited against the KB** (existing architecture) — the design must fit the real system, not an imagined one.
- **Optional DESIGN REVIEW gate:** new systems, high-blast-radius, or auth/payments/PII designs require **human architecture sign-off** before any code; low-risk changes skip it. *This is where system-design generation lives.* (`15`'s **"light Design"** is exactly this stage at unit scope with the review gate skipped — same machine, fast lane.)
- **Output:** a design/plan attached to the spec — together they become Phase B's input.
- *Integration:* Serena + Atlas KB, Model Gateway, JIRA (design review). *(the "Plan" stage, roster in `03`)*

> Phase A is deliberately human-weighted: you ratify **intent** (A1), the **spec** (A2), and — for risky work — the **design** (A3). Everything Phase B does is held to these three ratified artifacts.

---

# Phase B · Build & Ship — where spec+design become production

### B1 · Trigger — what starts a build run
- The ratified spec+design is marked ready — the **JIRA issue transitions to "Ready for Agent"** (status/label) → **JIRA webhook / automation rule** → the **JIRA⇄Azure DevOps bridge** ingress (Container App, Zone 2).
- The **Orchestrator** admits the run (ratified spec+design present? blast-radius within OPA policy?), writes `run-start` to the **audit ledger**, enqueues on **Azure Service Bus**.
- *Integration:* JIRA webhooks/API, Service Bus, OPA.

### B2 · Spawn the worker — container, not VM
- A **fresh, ephemeral Azure Container Instance** per run (or Container Apps Job), short-lived least-privilege **managed identity**, secrets from the agentic plane's **own Key Vault**. Reaches only the Model Gateway, the KB, and the repo seam — **never** the app data cluster.
- *Integration:* ACI, Managed Identity, Key Vault.

### B3 · Check out the code — the repo seam
- `git checkout` a clean working copy from **Azure DevOps Repos**. The *live checkout* is why the Coder can't hallucinate current code — it reads reality.

### B4 · Coder — implement to spec + design
- Loads the **ACTIVE spec** (Gherkin), the **design** (A3), the **KB** (structure-scoped), and **episodic memory**. **OpenHands / Cline** writes **code + supplementary tests** to satisfy the acceptance criteria *within* the ratified design — the **acceptance tests themselves were born at gate 4** (`06`) and are **read-only to the Coder**: it may add tests, never author or edit its own oracle.
- Every model call routes the **Model Gateway** — redaction, budget, audit. **Only code + spec leave the tenant; no regulated data, ever.**
- *Integration:* OpenHands/Cline, Serena, Atlas Vector, Model Gateway → Claude/GPT.

### B5 · Sandbox testing — verify by execution
- In the same throwaway sandbox: the **spec-born acceptance tests** (Gherkin, instantiated at gate 4 — not Coder-authored), the **regression** suite, **types/lint**, and **Pact + oasdiff** for integration work. Ephemeral test DB / fixtures — never prod data.

### B6 · Gates — the validation gauntlet
- Spec-conformance · blast-radius · **OPA/Rego** policy · **adversarial Critic — KB-anchored:** it refutes the diff against the *ratified spec clauses and invariants* it claims to satisfy, cited like any other claim — an independent reading of the contract, never a review of the Coder's own framing · breaking-change. Every result → audit ledger. Fail → bounded retry (back to B4) or escalate.

### B7 · Commit — open the PR
- Push a branch, open a **Pull Request in Azure DevOps Repos** linked to the JIRA issue, carrying the evidence pack (spec+design links, gate results, diff, blast-radius). **Azure Pipelines CI** re-verifies on neutral infra.

### B8 · Optional human review & approval
| Condition | Path |
|---|---|
| **L3** · low-risk · all gates + CI green · high confidence | **Auto-merge** — no human in the path |
| **L2** · or auth/payments/PII · or low confidence · or a gate flagged | **Human approves** the PR in ADO / JIRA — reviews diff + evidence pack |

Optional *by design*: gates + evals make review skippable for proven classes, so the human is the **exception path, not the default bottleneck**. Even on auto-merge a human is **on the loop** (notified + kill switch). *(This is the code review; the design review was A3.)*

### B9 · Deploy — dark, canaried, reversible
- Merge → **Azure Pipelines** builds → **App Service staging slot**. Ships **dark** (homegrown **feature flag** OFF) → **canary** ramp → **auto-rollback / kill-switch** on any regression breach.

### B10 · Monitor & close the loops
- **Monitor** reads telemetry via the **read-only seam** → ramps or holds. Then **KB re-sync** (= definition of done), **Drift Reconciler** re-check, **episodic lesson** written, **audit ledger** sealed, **PM↔outcome** loop (did the success metric move? → back to A1). The **worker is destroyed** — zero persistent state.

---

## Technology & integration map

| Concern | Technology | Phase / Zone |
|---|---|---|
| Work tracking / trigger / human surface | **JIRA** (Epics→Features→Stories→Tasks→Bugs — carrier hierarchy; work-item taxonomy canonical in `15`; webhooks + REST + automation) | A & B · external seam |
| Problem framing | **PM Agent** (Agent SDK) | A · Zone 3 |
| Spec generation + validation | **Spec Agent** + gauntlet (OPA, oasdiff, Pact) | A · Zone 3 |
| System design | **Plan/Design Agent** (+ optional human design review) | A · Zone 3 |
| Orchestration / state machine | **Azure Container Apps** + Agent SDK | B · Zone 2 |
| Job queue / events | **Azure Service Bus** | B · Zone 2 |
| Ephemeral worker sandbox | **Azure Container Instances** (or Container Apps Jobs; in-tenant microVM option) | B · Zone 3 |
| Identity / secrets | **Managed Identity + own Key Vault** | Zone 2/3 |
| Source control / PR | **Azure DevOps Repos** (repo seam) | B · external seam |
| CI/CD | **Azure Pipelines** | B · Zone 2 → 1 |
| Coder | **OpenHands / Cline** | B · Zone 3 |
| Model access | **Model Gateway** → Claude/GPT (sovereign later) | A & B · code+spec only |
| Code graph / KB | **Serena** + **Atlas Vector Search** (dedicated cluster) | A & B · Zone 2 |
| Deploy target | **Azure App Service** (staging + prod slots) | B · Zone 1 |
| Dark launch / rollback | **Homegrown feature flags** (programmatic API) | B · Zone 1 |
| Telemetry (read-only seam) | **PostHog / metrics** | Zone 1 → 2 |
| Audit / memory / specs / designs | **Dedicated agentic Atlas/Mongo cluster** | Zone 2 |

---

## The three invariants this trace never violates

1. **Isolation** (`02`) — the worker touches the app only through **seams** (repo in, deploy out, read-only telemetry in). No shared datastore, ever.
2. **No regulated data to models** — only **code + spec** cross the Model Gateway.
3. **Every hop is audited** — problem, spec, design, trigger, spawn, model call, gate, merge, deploy, rollback all land in the immutable ledger.

## The three human ratification points

Phase A is where humans stay in control: **intent** (A1 · epic-spec) → **spec** (A2 · unit-spec) → **design** (A3 · for risky work). Phase B adds one optional **code review** (B8). Everything the autonomous loop does is bounded by these ratified artifacts.
