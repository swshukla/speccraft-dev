# Agentic SDLC — Strategy & Approaches

**Date:** 2026-07-10
**Status:** Approaches captured for reference · **Approach B selected** for execution
**Owner:** Swapnil

---

## 1. Objective

Build and maintain the **entire software development lifecycle** (SDLC) via agentic
AI systems for the startup — a fintech / investment platform. The end state is a
loop that runs with as few humans in it as risk tolerance allows:

```
Telemetry / Ticket ─► Spec ─► Plan ─► Code ─► Test ─► Review ─► Deploy ─► Monitor ─┐
        ▲                                                                          │
        └──────────────────────────────────────────────────────────────────────────┘
```

This maps directly onto the original whiteboard: *Define Specs → Automation*,
*Agent → JIRA → Code*, the *3 Bots* (Exception / UI-API / KB), the telemetry →
investor-profile pipeline, and the *Sovereign AI* build-vs-buy thread.

## 2. Context & Constraints (from strategy session)

| Dimension | Decision |
|---|---|
| **Codebase state** | Hybrid — existing core product + new greenfield modules alongside |
| **Autonomy target** | Fully autonomous **with guardrails** — agents ship **all the way to prod** on their own (tests + policy engine + canary + auto-rollback); humans handle escalations only. Blast radius contained by module boundary + feature flag. |
| **Model strategy** | Foundation models (Claude / GPT) now; architected so **sovereign / self-hosted** models can be swapped in later |
| **Team shape** | Small eng team (5–20); agents augment, take the toil, multiply throughput |
| **Domain** | Fintech / investment platform — **regulated**, so audit trails & policy enforcement are first-class, not optional |

**Tech stack (the substrate agents operate on):**

- **Web:** Next.js
- **Mobile:** React Native
- **Server:** Node.js
- **Database:** MongoDB
- **Cloud:** Azure (everything deployed here)

> This TS/JS-heavy stack is the *best-case* substrate for agentic dev: the most mature
> tooling ecosystem, fast build/test cycles, everything scriptable.

## 3. The core question: agent topology

The SDLC *stages* are not the interesting decision — everyone agrees on
spec→plan→code→test→review→deploy→monitor. The decision that determines **cost,
safety, and ceiling** is what *topology* the agents take. That's the axis the three
approaches below sit on:

> **Human-in-loop tool → Process-as-agents → Autonomous workforce**

---

## 4. Approach A — "Copilot Fleet" (buy, human-adjacent)

**Philosophy:** Agents serve *humans in the dev loop*.

Lean entirely on off-the-shelf agentic tools (Claude Code / Cursor / GitHub Copilot
Workspace) triggered from JIRA/GitHub issues, running in ephemeral cloud dev
environments, producing PRs. Verification = existing CI + human review + the tools'
own review agents.

| ✅ Pros | ❌ Cons |
|---|---|
| Fastest to value — days, not months | Capped at what the tools expose |
| Near-zero platform to build | "Fully autonomous deploy" is bolted on, not native |
| No infra/ops burden | Can't enforce **fintech-specific policy** centrally |
| Great developer ergonomics immediately | Weak audit story for regulators |

**Verdict:** Excellent *starting posture* and a permanent part of the toolbelt — but
too shallow to be the end state described. Its coding agents get **reused inside B**.

---

## 5. Approach B — "SDLC Pipeline-as-Agents" ⭐ **SELECTED**

**Philosophy:** The SDLC *becomes* a durable, event-driven pipeline; each stage is a
**specialized agent**. You **own the orchestration + guardrail spine**; you **rent the
intelligence** from foundation models.

```
                          ┌─────────────── Guardrail Spine (you own) ───────────────┐
                          │  Policy engine · Spec-conformance gate · Adversarial     │
                          │  verifier · Canary + auto-rollback · Full audit trail    │
                          └──────────────────────────────────────────────────────────┘
   Ticket/Telemetry ─► [Spec] ─► [Plan] ─► [Coder] ─► [Verifier] ─► [Reviewer] ─► [Deployer] ─► [SRE]
                          each = a specialized agent on the Claude Agent SDK, running in Azure/GitHub CI
```

**Whiteboard mapping:** *3 Bots + KB* → the Spec/Coder/KB-RAG agents; *Define Specs →
Automation* → the Spec stage; *Agent → JIRA → Code* → Plan+Coder stages; telemetry
pipeline → the SRE/Monitor feedback edge.

| ✅ Pros | ❌ Cons |
|---|---|
| **Only approach that actually delivers "autonomous + guardrails"** | More to build than A (weeks–months) |
| You own the spine → **swappable to sovereign models later** | Requires orchestration + ops discipline |
| Guardrails & audit are first-class (fintech-ready) | Needs a real verification strategy to be trusted |
| Reuses A's coding agents as the "Coder" stage (don't rebuild) | |
| De-risked by proving **one low-risk service end-to-end first** | |

**Execution principle:** *Own the spine, rent the brains, prove the thin slice.*

**Verdict:** **This is the target.** Borrow A's tooling for the Coder stage; grow
toward C over time. See decomposition in §7.

---

## 6. Approach C — "Autonomous Agent Workforce" (build everything, org-scale)

**Philosophy:** Agents are *always-on autonomous workers* on a bespoke internal
platform.

Durable workflow engine (Temporal / Azure Durable Functions), an agent + skills
registry, a shared RAG knowledge base over code+docs+telemetry, long-running agents
that continuously groom the backlog and self-heal from telemetry.

| ✅ Pros | ❌ Cons |
|---|---|
| Highest ceiling | Heaviest build & ops |
| True org-scale standardization | Overkill for a 5–20 team **today** |
| Continuous, always-on autonomy | Premature — needs B's spine to exist first |

**Verdict:** The **12–18 month north star that B evolves into**, not a starting point.
B's spine is deliberately designed so its stages can migrate onto a C-style durable
platform without a rewrite.

---

## 7. Selected path: how B rolls out

**Strategy:** Target **B**, borrow **A**'s tooling instead of rebuilding coding agents,
treat **C** as the horizon. The spine is the durable asset; the thin-slice is how we
de-risk it.

### Decomposition of B into buildable sub-projects

B is too large for one spec. It decomposes into these subsystems, each its own
design→plan→build cycle:

1. **Orchestration spine** — event bus + stage runner + state/audit store (the backbone every agent plugs into)
2. **Guardrail layer** — policy engine, spec-conformance gate, adversarial verifier, canary + auto-rollback
3. **Stage agents** — Spec, Plan, Coder, Verifier, Reviewer, Deployer, SRE (Coder reuses Claude Code / Agent SDK)
4. **Knowledge base (KB)** — RAG over code + docs + telemetry that stages query for context
5. **Integrations** — JIRA, GitHub, Azure DevOps/Pipelines, telemetry source, notifications
6. **Control surface** — dashboard/CLI for humans to observe, approve escalations, and audit

### Sequencing

- **Phase 0 — Thin slice (first sub-project):** stand up the *entire loop* end-to-end for **one small, low-risk Node service**, with real guardrails, but minimal breadth. Proves the model. ← **we build this first**
- **Phase 1 — Harden & widen:** add remaining stage agents, strengthen the guardrail layer, extend to more services.
- **Phase 2 — Knowledge & breadth:** full RAG KB, mobile/web design-library integration, backlog-grooming agents.
- **Phase 3 — Toward C:** migrate the spine onto a durable workflow platform; always-on autonomous agents; evaluate sovereign models.

> This sequencing is the strategic sketch. **Doc `10` is the canonical roadmap** — where its phase definitions differ from the above (they do, e.g. Phase 3), `10` wins.

### The thin slice (Phase 0) — to be specced next

The first thing we actually build: a **greenfield module inside the existing Node
monolith** where a ticket flows **Spec → Plan → Code → Test → Review → Deploy →
Monitor** with agents doing the work and the guardrail spine keeping it safe —
agents ship **autonomously all the way to prod**, human sign-off only on escalation.

Safe because blast radius is contained *by construction*:

- **Module boundary** — agents may only touch the module's directory; CI hard-fails any diff outside it.
- **Feature flag** — the module ships dark behind a flag; instant kill switch.
- **Policy engine** — escalates to a human on forbidden change classes (auth, payments, PII, DB migrations, dependency changes, diff-size over threshold).
- **Canary + auto-rollback** — deploy watches the module's own metrics and reverts on regression.

CI/SCM choice (GitHub Actions vs Azure DevOps) is deferred behind an adapter
interface so it doesn't block Phase 0. Concrete scope specced in the next document.

## 8. Cross-cutting concerns (apply to every phase)

- **Auditability:** every agent action (prompt, output, decision, diff, deploy) is logged immutably — regulatory requirement, not a nice-to-have.
- **Least privilege:** agents get scoped credentials per stage; the Deployer can deploy but the Coder cannot.
- **Model portability:** all model calls go through one abstraction so foundation → sovereign swap is a config change, not a rewrite.
- **Human escalation:** clear, low-friction paths for an agent to hand off to a human when confidence is low or policy blocks it.
- **Cost governance:** token/spend budgets per stage and per loop, with observability.

## 9. Open questions (to resolve as we spec Phase 0)

- Which specific low-risk Node service is the thin-slice candidate?
- Source control & CI: GitHub (+ Actions) or Azure DevOps Pipelines?
- Telemetry source for the Monitor/SRE edge (App Insights? Sentry? custom)?
- Regulatory constraints on autonomous prod deploys — what class of change is allowed to ship without a human today?
- Definition of "low-risk change" for the auto-merge/auto-deploy guardrail.

---

*Approaches A and C are retained here intentionally: A as the always-available
tooling posture, C as the north star. Execution proceeds on B, starting with the
Phase 0 thin slice.*
