# Agentic SDLC — Local Dev-in-the-Loop (the cheap on-ramp)

**Date:** 2026-07-12
**Purpose:** Define the **local, developer-in-the-loop** mode as a first-class system — what it is, what runs where, what it shares with the cloud autonomous design (`00`–`15`), and the **crawl → walk → run** tiers that let you start for hundreds/month and only pay for autonomy when you need it.

## The core inversion

> **In the cloud system, the Orchestrator is the control plane. Here, the developer is.** The human picks the work, drives the agent through spec→design→code→test *interactively*, reviews continuously, and commits when satisfied. Everything the autonomous pipeline does with services and gates, the developer does with judgment — in the loop, on every task.

That single swap is why cost collapses: no always-on orchestrator, no ephemeral cloud fleet, no dedicated cluster, no model-gateway service. The laptop is the runtime; the human is the guardrail.

## What runs where

| Component | Cloud autonomous | Local dev-in-the-loop |
|---|---|---|
| **Orchestrator** | Container App, always-on | **the developer** |
| **Stage agents** (PM→Coder→Verifier) | ephemeral cloud workers | **one local agent** (Claude Code / Cline / Aider / OpenHands-local) the dev drives, playing the roles interactively |
| **Code graph / KB** | warm service + dedicated cluster | **Serena on the laptop**, over the local checkout |
| **Semantic index** | Atlas Vector (dedicated cluster) | small local vector store *(or a shared read-only KB service in Walk)* |
| **Skills** (procedural memory) | mounted in cloud workers | **same skills-as-code**, mounted into the local agent (`.claude/skills`) |
| **Specs** (intent) | spec-as-code + cloud state | **same spec-as-code**, authored/consumed locally |
| **Model access** | Model Gateway (metered API) | **Claude Code Max subscription** (flat) or a local API key |
| **Gates** (OPA, tests, oasdiff, Pact) | ephemeral cloud workers | **run in existing Azure Pipelines CI** on the PR |
| **Deploy / canary / flags** | Deployer agent | **existing Azure DevOps → App Service** pipeline |
| **Audit** | immutable ledger (dedicated cluster) | **git history + PR records + CI logs** |
| **Drift Reconciler, autonomous Monitor** | cloud jobs | *not present* (or a light scheduled job in Walk) |

## The key point: local is a *subset*, not a rewrite

The **KB, skills, specs, and gates are identical** — local just runs them on a laptop and in your existing CI instead of a cloud fleet, with the developer standing in for the orchestrator and the autonomous agents. So **nothing built for local is wasted** when you graduate to cloud; you're adding autonomy *around* the same core, not replacing it.

## The developer's workflow (local execution trace)

1. **Pick & triage** — dev takes a JIRA item, decides its treatment (`15`: bug → straight to code; feature → spec+decompose first).
2. **Spec (as needed)** — dev + agent write/refine the spec-as-code; dev ratifies intent *in the moment*.
3. **Drive the build** — agent (Claude Code/Cline) reads the local KB, writes code + tests; dev steers, corrects, unblocks — fewer wasted loops than autonomous.
4. **Verify locally** — run tests/types in the working copy; dev eyeballs the diff continuously (not a post-hoc gate).
5. **Commit & PR** — dev opens a PR on Azure DevOps.
6. **Governance on the rails** — **Pipelines CI runs the same gates** (OPA, tests, oasdiff, Pact); optional peer review; canary deploy. The human was the pre-PR gate; the pipeline is the post-PR gate.

## Governance in local mode (honest)

- **Isolation / compliance envelope holds** — the agent sees only code + specs on the laptop; **no prod/finance data**, same as cloud. Secrets = the dev's key/subscription, kept out of the repo.
- **The human-in-the-loop replaces most automated guardrails** — the dev is accountable for what they commit; the CI gates + peer review are the safety net.
- **Audit is git + PR + CI**, not a bespoke immutable ledger — real and sufficient for dev-driven work, weaker than the cloud ledger for fleet-scale autonomy.

## The three tiers: crawl → walk → run

| Tier | What it is | Infra | ~Monthly (small team) | What it *buys* | What it *can't* do |
|---|---|---|---|---|---|
| **Crawl** — local dev-in-loop | agent on laptop, dev drives, ships via normal PR/CI | ~none | **~$600–1k** (Claude Code Max × devs) | value in weeks; **bootstraps KB/skills/specs**; near-zero risk | unattended runs; scale beyond headcount |
| **Walk** — hybrid | local agents + **shared KB service** + cloud CI gates + light nightly jobs (KB sync, drift check) | small | **~$1–3k** | shared knowledge, centralized gates, first drift detection | autonomous fix/deploy; parallel fleet |
| **Run** — cloud autonomous | the full Approach-B system (`00`–`15`) | full | **~$20–40k** | **autonomy at scale**, unattended runs, autonomous drift maintenance, fleet parallelism | — |

Each tier **reuses the prior tier's KB, skills, specs, and gates** — you add autonomy incrementally, never rework.

## What local genuinely cannot do (so you know when to graduate)

- **Unattended / overnight / parallel-fleet** work — throughput is capped at developer hours.
- **Autonomous maintenance** — drift reconciliation, monitoring-triggered fixes.
- **Fleet-scale centralized audit/governance** in real time.

You graduate to **Run** precisely when one of those becomes the thing you're buying — not before.

And graduation is **gated by eval assets, not appetite** (`07`, `17`): a product runs autonomous only once it has a golden spec set of its own, a seeded-defect suite for every gate it ships, a judge calibrated against human labels from *this* product, and claim categories that have *earned* auto-accept (`04`). Crawl and Walk are where those assets accumulate as a byproduct of dev-driven work — that is the real reason to start there: the tiers are the **bootstrap sequence for trust**, not just a cost ramp.

## Recommendation

**Start at Crawl.** It's the cheapest, fastest, lowest-risk way to get value *and* it bootstraps the exact assets (KB, skills, specs) the cloud system needs. Move to **Walk** when a shared KB and centralized gates start to matter across the team. Invest in **Run** only when throughput-beyond-headcount or unattended autonomy is the explicit goal. This is the most fundable path: **small ask now, big spend deferred until justified.**

## Doctrine

1. **The developer is the control plane** — human judgment stands in for orchestrator + autonomous agents + most gates.
2. **Local is a subset, not a rewrite** — same KB/skills/specs/gates; nothing is wasted graduating up.
3. **Governance rides the existing rails** — PR + CI gates + canary give real guardrails without cloud orchestration.
4. **Crawl → Walk → Run** — add autonomy incrementally; pay for it only when it's the thing you need.
5. **Same compliance envelope** — code + specs only, never finance data, in every tier.
