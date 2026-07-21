# Agentic SDLC — Build vs Buy Map

**Date:** 2026-07-11
**Method:** Deep-research harness — parallel web + GitHub search across 6 slots, top sources fetched, every claim put through 3-vote adversarial verification (≥2 refutes kills a claim). Refuted claims are reported *as findings* because they tell us what NOT to trust.
**Bottom line:** The runtime, coder, code-index, and guardrail slots are **largely solved by mature OSS — adopt.** The **code↔spec drift/traceability layer is genuinely unsolved off-the-shelf — build it** (assembled from partial primitives). This confirms the hypothesis from the earlier conceptual discussion.

---

## Decision table

| # | Slot | Verdict | Adopt / assemble from | Confidence |
|---|---|---|---|---|
| 1 | Orchestration spine / runtime | **ADAPT** | Claude Agent SDK or Cline SDK + a sandbox runtime (Daytona / E2B / Modal) | High |
| 2 | Autonomous coding agent ("Coder") | **ADOPT** | OpenHands, Cline, or mini-swe-agent | High |
| 3 | Code knowledge base / graph | **ADOPT** | **Serena** (MIT, ~26k★) as the symbol graph; Potpie for graph-RAG | High |
| 4 | Spec knowledge base / spec-driven | **ADOPT format** | Spec Kit / OpenSpec / BMAD (pick one spec-as-code convention) | Medium |
| 5 | **Code↔spec drift / traceability** | **BUILD** ⚠️ | oasdiff + Pact as partial primitives; the reconciler is bespoke | High |
| 6 | Guardrails for autonomous deploy | **ADOPT + ADAPT** | OPA/Conftest/Kyverno (policy) + NeMo/Guardrails-AI (LLM I/O) + canary tooling | High |

**One-line strategy:** *Adopt for slots 1–3 and 6, standardize a format for 4, and concentrate your original engineering on slot 5 (the reconciler) — that's the moat.*

---

## Slot 1 — Orchestration spine / agent runtime → **ADAPT**

The runtime splits into *agent framework* + *sandboxed execution*:

- **Agent framework:** the **Claude Agent SDK** (what this very session runs on) or **Cline's `@cline/sdk`** (Apache-2.0, open-sourced May 2026 — "build your own AI agents… custom tools, multi-agent teams, connectors, scheduled automations"). Both give you the agent loop, tool orchestration, session persistence, and multi-agent coordination — so you don't hand-write the orchestrator core.
- **Sandboxed ephemeral workers:** dedicated code-execution sandboxes exist and are fast — **Daytona (~90 ms cold start)**, **E2B (~150 ms)**, **Modal**, Vercel Sandbox. These *are* your data-plane workers (the control-plane/data-plane split from the operating-model discussion). Cold-start matters because it compounds across thousands of stage-runs. *(**Superseded — decided in `02`:** execution is **in-tenant** — ACI / Container Apps jobs under the isolation invariant; external sandbox SaaS rejected. Analysis kept for the record.)*

**Take:** don't build a durable orchestrator from scratch. Wrap an SDK for the control loop; use a sandbox runtime for isolation — per `02`, that runtime is **in-tenant**, not an external SaaS. The bespoke part is only the *SDLC-stage state machine + guardrail gates* on top.

> ⚠️ Note: general personal-agent frameworks (Hermes, OpenClaw) were evaluated earlier and are the *wrong* substrate — they're high-trust personal assistants, not sandboxed SDLC runtimes.

## Slot 2 — Autonomous coding agent ("Coder") → **ADOPT**

Do **not** build this. Three strong, verified options:

- **OpenHands** — SOTA on SWE-bench Verified: **60.6% single-shot, 66.4% with 5 attempts** via inference-time scaling + a trained critic model that scores rollouts and filters patches on regression/reproduction tests. *(Their "best agent out there" line was refuted by verification as self-promotional — judge on the benchmark, not the tagline.)* The **critic-model + test-filtering pattern is directly reusable as your Verifier stage.**
- **Cline** — autonomous agent shipped as SDK + IDE extensions (VS Code, JetBrains) + CLI + Kanban. **Provider-agnostic** (Ollama, LM Studio, any OpenAI-compatible/self-hosted endpoint, "not locked to a single AI provider") — this is the standout for your **sovereign-later** requirement. Built-in autonomy guardrails: every file edit + terminal command requires approval by default, optional selective auto-approve, checkpoint/undo.
- **mini-swe-agent** — ~100 lines of Python, matches SWE-agent's performance (~65% SWE-bench verified at launch; treat exact % as dated). Notable as the *minimal* Coder if you want something you fully understand. SWE-agent's own "SoTA among open-source" banner is **outdated (Feb 2025)** — don't cite it as current.

**Take:** adopt **OpenHands** for raw capability, or **Cline** if provider-agnosticism/sovereign-path dominates. Steal OpenHands's critic-model idea for the Verifier gate.

## Slot 3 — Code knowledge base / structural graph → **ADOPT**

- **Serena** (`github.com/oraios/serena`, **MIT, ~26.3k★, active — v1.5.3 in 2026**) — verified: symbol-level semantic code retrieval/editing over functions/classes/methods, exploiting relational structure via LSP, exposed as an **MCP server** (already available in this environment). This *is* the structural-layer of the KB from the earlier discussion, off the shelf.
- **Potpie** (`github.com/potpie-ai/potpie`) — builds a code *knowledge graph* and lets you run agents over it (graph-RAG flavor). Complements Serena's symbol graph with the semantic-discovery layer.

**Take:** adopt Serena as the code graph; layer embeddings (Mongo Atlas Vector Search in your stack) for fuzzy discovery. No need to build a code indexer.

## Slot 4 — Spec knowledge base / spec-driven development → **ADOPT A FORMAT**

Spec-driven development is now a real, crowded category: **GitHub Spec Kit, OpenSpec, BMAD** (plus AWS Kiro, Google Antigravity, Tessl in the commercial tier). They give you the *forward* direction — machine-readable spec-as-code → generated implementation — and a review discipline.

**Take:** don't invent a spec schema. Pick **one** convention (Spec Kit or OpenSpec are the lightweight OSS choices; BMAD if you want more process scaffolding) and store spec-as-code in the repo, as designed in the KB discussion. This is a *low-stakes, reversible* choice — standardize and move on.

## Slot 5 — Code↔spec drift / bidirectional traceability → **BUILD** ⚠️ (the moat)

**This is the slot with no trustworthy off-the-shelf answer — verification proved it:**

- **Proof (`reqproof.com`)** — claims full bidirectional traceability requirements→code→tests→docs. **Refuted 0-3** (all three verifiers rejected it as unsubstantiated marketing).
- **ReqToCode (arXiv 2603.13999)** — "compile-time verifiable traceability, hard bidirectional links validated at build." **Refuted 1-2** — an academic proposal, not a shipping product; strong claims didn't survive scrutiny.

What *does* survive is a set of **partial primitives** you assemble:

- **oasdiff** (`github.com/oasdiff/oasdiff`, **Apache-2.0, ~1.3k★, v1.23.0 Jul 2026, very active**) — detects breaking changes between two OpenAPI specs → a ready **API-contract drift gate**.
- **Pact** (`docs.pact.io`) — consumer-driven contract testing; the contract is *derived from the consumer's actual code*, and it flags consumer/provider divergence → a partial **code↔contract sync** mechanism.

**Take:** the reconciler I described (traceability links spec-item ↔ code-entity, drift detection on every diff, "KB back in sync" as definition-of-done) is **genuinely bespoke** — but you build it *on top of* oasdiff (API surface), Pact (contracts), and Serena (symbol graph), not from zero. **This is where your original engineering should go**; everything else is assembly.

## Slot 6 — Guardrails for autonomous-to-prod → **ADOPT + ADAPT**

Two layers, both well-served by OSS:

- **Policy engines (deterministic gates):** **OPA/Rego** (`open-policy-agent/opa`), **Conftest** (config/policy testing), **Kyverno**, **Gatekeeper**. These enforce your "forbidden change classes" (no auth/payments/PII/migrations/deps without escalation) and deploy-time admission policy.
- **LLM-output guardrails:** **NVIDIA NeMo Guardrails** and **Guardrails-AI** — validate/constrain what agents produce and say.
- **Canary + auto-rollback:** progressive-delivery tooling (Argo Rollouts / Flagger-style) is mature; wire it to the module's own metrics.

**Take:** adopt OPA/Conftest for the policy engine and canary tooling for safe rollout; the *AI-specific* conformance gates (spec-conformance, adversarial verifier) are the thin adaptation you add.

---

## Cross-cutting conclusions

1. **~80% is assembly, not invention.** Runtime, coder, code-graph, policy, canary — all mature OSS. Reuse aggressively.
2. **The reconciler (slot 5) is the one true build** — and the market gap is *verified*, not assumed. It's also your differentiation.
3. **Provider-agnosticism is available today** (Cline, self-hostable OpenHands, local-model support) — the sovereign-later path is real, not aspirational.
4. **Integrated platforms exist** (GitLab Duo Agent Platform, OpenHands Enterprise — both self-hostable, relevant to regulated fintech) — worth a look if you'd rather buy more of the spine than assemble it. Forrester frames this whole space as the shift "from code assistants to orchestrated SDLC agents."
5. **Trust the benchmarks, not the taglines** — verification caught self-promotional and stale claims (OpenHands "best," SWE-agent "SoTA").

## Recommended adoption set (starting point)

```
Runtime        → Claude Agent SDK  (control loop)  +  in-tenant sandboxes per 02  (Daytona/E2B superseded)
Coder          → OpenHands  (capability)  or  Cline  (provider-agnostic / sovereign path)
Code graph     → Serena (MCP)  +  Mongo Atlas Vector Search (semantic)
Spec format    → Spec Kit  or  OpenSpec  (spec-as-code in repo)
Drift/sync     → BUILD reconciler  on top of  oasdiff + Pact + Serena   ← your moat
Policy/deploy  → OPA + Conftest  +  canary/auto-rollback  +  NeMo/Guardrails-AI
```

---

## Sources

**Coder / runtime:** [Cline](https://github.com/cline/cline) · [OpenHands SWE-bench + critic](https://www.openhands.dev/blog/sota-on-swe-bench-verified-with-inference-time-scaling-and-critic-model) · [SWE-agent](https://github.com/SWE-agent/SWE-agent) · [Coding-agent taxonomy](https://artificialanalysis.ai/agents/coding) · [Sandbox comparison (Modal/E2B/Daytona/Vercel)](https://particula.tech/blog/modal-vs-e2b-vs-daytona-vs-vercel-sandbox-ai-code-execution)
**Code graph / spec:** [Serena](https://github.com/oraios/serena) · [Potpie](https://github.com/potpie-ai/potpie) · [BMAD vs Spec Kit vs OpenSpec](https://medium.com/@reenbit/bmad-vs-spec-kit-vs-openspec-choosing-your-spec-driven-ai-framework-in-2026-a6996b3ebb8d)
**Drift / traceability (the hard part):** [Proof — refuted](https://reqproof.com/) · [ReqToCode arXiv — refuted](https://arxiv.org/abs/2603.13999) · [oasdiff](https://github.com/oasdiff/oasdiff) · [Pact](https://docs.pact.io/consumer)
**Guardrails:** [OPA](https://github.com/open-policy-agent/opa) · [Conftest](https://github.com/open-policy-agent/conftest) · [Kyverno](https://github.com/kyverno/kyverno) · [Gatekeeper](https://github.com/open-policy-agent/gatekeeper) · [NeMo Guardrails](https://github.com/NVIDIA-NeMo/Guardrails) · [Guardrails-AI](https://github.com/guardrails-ai/guardrails)
**Platforms / landscape:** [GitLab Duo Agent Platform](https://about.gitlab.com/gitlab-duo-agent-platform/) · [OpenHands Enterprise](https://www.openhands.dev/enterprise) · [Forrester: orchestrated SDLC agents](https://www.forrester.com/blogs/agentic-software-development-takes-the-lead-from-code-assistants-to-orchestrated-sdlc-agents/) · [Securing the agentic SDLC](https://cycode.com/blog/securing-adlc/)

*Verification note: claims were adversarially checked 3 ways; "refuted" items above failed that check and are listed so they aren't mistaken for validated options.*
