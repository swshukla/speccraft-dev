# Agentic SDLC — What It Will Take to Build

**Date:** 2026-07-11
**Purpose:** A grounded answer to "what will it take" — the shape of the work, the team, the sequence, the time, the cost, and the honest risks. Synthesized from docs `00`–`09`.

## The shape of the work: ~80% assembly, ~20% bespoke

The single most important framing (from `01`/`03`): **you are not building an AI platform.** You are assembling mature open-source (Serena, OpenHands/Cline, OPA, oasdiff, Pact, sandbox runtime, Atlas Vector) and building the **thin harness** that turns it into a safe, autonomous pipeline on your rails. That's what makes this a *weeks-to-months* effort, not a *years* one.

Three things are genuinely yours to invent — the moat, and the risk:
1. **The Orchestrator** — the SDLC state machine (conductor).
2. **The Drift Reconciler** — code↔spec sync (the genuinely-unsolved part).
3. **The Spec generation + validation gauntlet** — problem → machine-checkable contract (`06`).

Everything else — gates, audit ledger, KB sync, JIRA bridge, Model Gateway, PM/stage agents, episodic memory, eval harness — is **modest glue** around adopted tools.

---

## What you're actually building, by effort tier

| Tier | Components | Nature |
|---|---|---|
| **Hard (novel)** | Drift Reconciler · Spec-validation gauntlet · Orchestrator state machine | design-heavy, eval-tuned, iterative |
| **Medium (integration)** | Model Gateway · KB sync (Serena+Atlas) · sandboxed worker runtime · canary/slot deploy · eval harness | wiring mature parts, security-sensitive |
| **Light (glue)** | JIRA⇄ADO bridge · audit ledger writer · blast-radius/policy gates · episodic memory · PM/Spec/stage agent definitions | prompts + small services + config |

> This table is a **summary by effort**; the canonical net-new component inventory is doc `03`'s build list — where the two differ, `03` wins.

---

## The team

Lean and senior beats large. Core build team of **~3 engineers**, plus founder time:

| Role | Owns | Why it's distinct |
|---|---|---|
| **Orchestration / backend engineer** | Orchestrator, Model Gateway, JIRA bridge, state machine — *the spine* | durable-workflow + API discipline |
| **AI / agent engineer** | stage-agent definitions, prompts, OpenHands/Cline integration, KB (Serena/Atlas), **evals** — *the brains* | agent/eval fluency, prompt rigor |
| **Platform / DevOps engineer** | Azure, Pipelines, ephemeral sandboxes, **isolation invariant**, Key Vault, dedicated cluster, canary/slots — *the rails* | cloud security + CI/CD |
| **Founder / PM** (part-time, **non-negotiable**) | elicitation, spec ratification, intent (`08`/`09`) — *the human gates* | you are the source of intent |

Two exceptional generalists could do it wearing multiple hats; three specialists is comfortable. A "verification/quality" focus (the Reconciler + gauntlet) can be a fourth later, or absorbed by the AI engineer early.

---

## The plan

### Phase 0 — Thin slice · **~6–10 weeks** · 2–3 engineers
**Goal:** one real loop shipping to prod on **one low-risk, code-complete module** (`09`).
- Build: Orchestrator (minimal), Model Gateway, JIRA⇄ADO bridge, single-agent Coder (OpenHands/Cline), core gates (blast-radius + tests + policy), audit ledger, staging-slot canary deploy.
- Spec: **manual** — a human writes the problem statement, Spec Agent drafts, human ratifies; gates 1–4 + 8 + 9 (`06`).
- KB: deterministic seed (Serena graph + Atlas index) on that module; **capture-on-contact on** from day one (`09`); **write-back-on-ship** — every merge updates the KB entries it touched (spec → ACTIVE, links refreshed, superseded claims demoted).
- Evals: **minimal slice from day one** (`07`, `14`) — Coder replay-eval (post-KB ratified PRs only), a seeded-defect suite for the gates actually shipped, a small golden spec set; every prompt/model change regression-gated against it.
- **Exit:** an agent ships a real change to production on that module, fully audited, with human ratification — the loop *works*.
- **Defer:** Drift Reconciler, full KB sync, episodic memory, PM Agent, multi-stage fan-out.

### Phase 1 — Durable & multi-stage · **~2–3 months**
**Goal:** the loop becomes durable and widens past one module.
- Build: **Drift Reconciler v1** (spec↔code links + oasdiff, merge + cron), incremental KB sync, **eval harness (full)** — widens Phase 0's minimal slice (broader replay corpus, richer seeded defects, `07`), **episodic memory** (`05`), full stage agents (Plan/Verifier/Reviewer/Deployer/Monitor).
- Autonomy: climb L1→L2 on low-risk modules as evals earn trust.
- **Exit:** several modules under the loop; drift auto-detected; prompt/model changes regression-gated.

### Phase 2 — Widen & lift autonomy · **~1 quarter, ongoing**
**Goal:** more modules, higher autonomy, richer product loop.
- Build: **PM Agent** (`08`, reactive first), structure-scoped retrieval (`05`), canary/rollback maturity, proactive externalization (`09`) behind a toggle.
- Autonomy: L2→L3 on proven module classes; humans move "on the loop."
- **Exit:** autonomous-to-prod on a real class of work, human as ratifier/exception-handler.

### Phase 3 — Sovereign · **later, cost/IP-driven**
Swap the Model Gateway to Azure-OpenAI-India / self-hosted. **Proven safe by re-running the eval suite** (`07`) — not a rearchitecture.

---

## Effort & timeline

| Milestone | Calendar (3 engineers) | Person-months |
|---|---|---|
| **Phase 0** working thin slice | ~6–10 weeks | ~4–7 |
| **Phase 1** durable + multi-stage | +2–3 months | ~12–18 cumulative |
| **Phase 2** meaningful autonomy | ~6–9 months total | ~18–30 cumulative |

*Assumes a strong, senior team and that Azure/JIRA/Atlas/OpenHands work roughly as advertised. The Drift Reconciler carries the most schedule risk (below).*

---

## Cost drivers

1. **People** — dominant. 3 engineers for 6–9 months is the real cost.
2. **Model tokens** — metered per run; the Coder (OpenHands) and the eval suite are the heavy consumers. Budgeted and capped at the **Model Gateway**. Plan for a variable monthly spend that scales with run volume — cheap in Phase 0, grows with autonomy.
3. **Infra** — Azure (on credits now): Container Apps (orchestrator/gateway, always-on but small), ephemeral ACI workers (per-run), the **dedicated agentic Atlas cluster** (`02` isolation), Pipelines minutes. Modest at low volume.

---

## Where it can balloon — honest risks (ranked)

1. **The Drift Reconciler** — the genuinely-unsolved moat (`01` verified nothing off-the-shelf does it). Highest schedule uncertainty. *Mitigation:* ship v1 deliberately simple (link + oasdiff), grow it; don't gold-plate before Phase 1.
2. **Gate precision/recall** — a gauntlet that false-positives blocks everything; that false-negatives ships bugs. *Mitigation:* the seeded-defect eval suite (`07`) from day one; tune gates against it, not vibes.
3. **Isolation + sandboxing done right** — security-critical, fiddly (least-privilege identities, ephemeral workers, the dedicated cluster). *Mitigation:* platform engineer owns it explicitly; treat as a security review item, not a config afterthought.
4. **Founder elicitation bandwidth** — the human bottleneck (`09`). If your time starves, the intent KB starves. *Mitigation:* batch/prioritize questions; capture-on-contact so you answer once.
5. **Homegrown feature-flag API** — autonomous deploy needs a *programmatic* flag API + kill switch (`02` flag). *Mitigation:* confirm/extend it early — it's on the Phase-0 critical path.
6. **Autonomy trust curve** — L0→L3 can't be rushed; it takes real production runs to earn. *Mitigation:* treat the autonomy ladder as evidence-gated, not calendar-gated.

---

## Bottom line

- **To a working, autonomous-to-prod thin slice on one module: ~2 months, 2–3 engineers + your part-time attention.**
- **To meaningful autonomy across a class of work: ~6–9 months** with the same small team.
- The build is *mostly assembly*; the schedule risk concentrates in **three novel pieces** (Reconciler, gauntlet, orchestrator) and **one human dependency** (your elicitation time).
- Nothing here is a research bet except the Reconciler — and even that has a simple v1. **This is a build, not a moonshot.**

The cheapest de-risking move is to **build Phase 0 and let it ship one real change to prod.** That single loop validates the orchestration, the gates, the audit trail, the deploy path, and the trust model at once — and tells you far more than any further design will.
