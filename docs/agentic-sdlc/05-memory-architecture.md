# Agentic SDLC — Memory Architecture

**Date:** 2026-07-11
**Purpose:** How the system *remembers* — the layers of memory, the one layer we were missing (episodic/operational), and the build-vs-buy verdict for the memory slot after evaluating **MemPalace**, Mem0, Zep/Graphiti, Letta, and Cognee.

## Two memory problems, not one

The seeding/KB work (docs `03`, `04`) solved **truth memory** — what the system *is*. It did not name **episodic memory** — what the agents *learned*. They are different, and conflating them is the mistake most memory frameworks make.

| Memory | Answers | Written by | Trust basis |
|---|---|---|---|
| **Truth KB** | "What *is* the code / spec right now?" | Derivation + verified inference | Execution + citation (docs `04`) |
| **Episodic** | "What did we *try*, and what happened?" | Agents, from run outcomes | Provenance + outcome evidence |

Truth memory is a *photograph of reality*; you re-derive it and it self-corrects. Episodic memory is *accumulated experience*; it only exists if you record it, and it's the layer that stops the fleet from repeating its own mistakes.

> **The governing principle:** truth memory is **derived and disposable** (re-buildable from code any time); episodic memory is **earned and precious** (lost forever if not captured). Treat them differently.

---

## The five memory layers

```
① STRUCTURAL   code graph — symbols, calls, routes, schemas     Serena (derived, deterministic)
② SEMANTIC     embeddings over code/docs/tickets/incidents       Atlas Vector Search
③ INTENT       spec-as-code + spec↔code traceability links       repo + Drift Reconciler
④ EPISODIC     lessons: what was tried, what failed, what's fragile   ← NEW, this doc
⑤ AUDIT        append-only ledger of every prompt/decision/diff/deploy   Mongo (regulatory)
```

①–③ are the **Truth KB** from docs `03`/`04`. ⑤ is the immutable evidence trail. **④ is the gap this doc closes.**

---

## ④ The episodic memory layer (net-new)

**What it holds** — durable, cross-run lessons, each tied to evidence:
- **Mistakes:** "attempted fix X on module M → caused regression R" (linked to the audit entry + the reverting commit).
- **Fragility notes:** "M has hidden coupling to N; changes here break N's tests."
- **Working patterns:** "for this class of change in M, approach Y passes gates reliably."
- **Escalation history:** "humans rejected this kind of change twice — escalate, don't auto-ship."

**The core behavior — check before acting.** Before the Coder/Planner touches a module, it queries episodic memory for that module + change-class and injects the relevant lessons into context — a fleet that doesn't consult its own scar tissue relearns every failure. (MemPalace's auto-save-then-recall loop is the same pattern; we keep the pattern, not the tool — see the verdict below.)

**How it's written — outcome-gated, never on assertion.** An episodic entry is created only when a run *concludes* with a verifiable outcome: a gate failed, a canary rolled back, a human rejected, a regression fired in Monitor. The outcome (from the audit ledger) *is* the evidence. No agent writes "I think M is fragile" from opinion — same doctrine as `04`: **outcome or it didn't happen.**

**How it runs / where** — a small library the Orchestrator and stage-workers call, over a collection in the **agentic plane's own dedicated cluster** (Zone 2 — never the application DB; isolation invariant, `02`), indexed into its **Atlas Vector Search** for fuzzy recall ("lessons *like* this change"). Persistent data; the writer runs wherever a stage runs. It is *derived from* the audit ledger (⑤), so it is rebuildable and never a second source of truth.

**Guardrails on the memory itself:**
- **Provenance + confidence + freshness** on every entry (same tags as the Truth KB). A lesson from 200 commits ago on since-rewritten code is stale — decay it.
- **Human-governed for the risky.** Lessons touching auth/payments/PII are ratified before they can *suppress* an action (see governance finding below). A poisoned lesson must not become an unreviewed veto.
- **Bounded blast radius.** Episodic memory *advises and escalates*; it never silently expands what an agent is allowed to do.

---

## The KB immune system (net-new — error must not compound)

A human team's knowledge is error-prone but **self-correcting for free**: different heads hold different mental models, wrong beliefs collide in review and argument, and every contact with the code re-tests them. The error rate stays roughly stationary. A canonical KB inverts both properties: an error in it is **perfectly correlated** across every agent and every future validation (there is no second mental model to collide with), and the citation discipline — "cite or it didn't happen" — actively **suppresses re-derivation**: citing the wrong entry is the well-behaved thing to do. Gate coverage is never total, so eventually a subtly wrong claim gets ratified; if nothing can remove it, KB error **compounds monotonically**.

The requirement is not a perfect KB — it is that **at least one channel exists through which a wrong ratified entry gets detected and demoted without a human happening to notice.** Three cheap ones:

1. **Sampled re-verification.** Each cycle, re-run archaeology on a small random sample of *ratified* entries and check the code still supports them (a few % of throughput). Catches rot with no external signal needed.
2. **Telemetry contradiction detection.** Production behavior that disagrees with what a KB entry claims (via the read-only telemetry seam, `02`) auto-demotes the entry to hypothesis and queues it for adjudication. This is the only channel that can catch an error every agent agrees with.
3. **A demotion path in the entry lifecycle.** `ratified → challenged → demoted | re-ratified`. The lifecycle must move both ways, not only toward trust. A demoted entry loses citation authority immediately — any spec citing it flags as ungrounded on its next validation (gate 2, `06`).

And the write-side rule that bounds how much the immune system must catch (details in `04` check 5): **gate passage is necessary but not sufficient to write into the KB.** Entries citing already-ratified clauses may auto-write; anything that adds or modifies an invariant needs human ratification; auto-accept is earned per claim category by measured error rate, never granted on model confidence.

> **Target property: a stationary KB error rate** — mistakes leak in, channels flush them out — like a healthy team, not a perfect one.

---

## Build-vs-buy for the memory slot

Evaluated: **MemPalace** (the corrected repo — supersedes temple-vault, which was the mistakenly-shared link and is not reconsidered), and the serious contenders **Mem0, Zep/Graphiti, Letta (MemGPT), Cognee, Basic Memory.**

| Option | What it is | Verdict | Why |
|---|---|---|---|
| **MemPalace** | Local-first MCP server (35 tools); SQLite + ChromaDB; spatial hierarchy (palace→wings→rooms→drawers); verbatim storage; built-in temporal graph | **REJECT as infra · MINE HEAVILY for ideas** | Best *idea source* of the set (see "What to steal"). But local-first/single-node SQLite doesn't fit a multi-worker, isolated, audited cluster; it's agent-authored (no human-governed/provenance/ratification); benchmark claims are contested; and its impostor/typosquat ecosystem is a **supply-chain risk** we won't take into an autonomous-to-prod plane. *Optional: prototype it in a sandbox for the episodic layer only (Phase 1), never core.* |
| **Letta (MemGPT)** | Apache-2.0 full agent *runtime* with OS-like memory tiers | **REJECT** | It's a runtime, not a memory layer — adopting its memory means running agents inside it. Conflicts with our own Orchestrator. |
| **Mem0** | Fast, popular key-value+vector agent memory | **REJECT as owner** | Too thin for traceability/provenance; assumes agent-authored memory. Fine as a pattern reference only. |
| **Cognee** | Poly-store knowledge graph, ECL pipeline, MCP/Claude Code native | **REJECT as owner** | Overlaps Serena + spec store; no SOC2/HIPAA; still agent-authored, not human-governed. |
| **Zep / Graphiti** | Bi-temporal knowledge graph (tracks when a fact became true / was invalidated) | **MINE FOR PARTS** | Don't adopt as the KB — but its **bi-temporal model is a direct build input for the Drift Reconciler + staleness tags** (MemPalace corroborates the same idea). |
| **Markdown-vault-in-repo + bespoke provenance** | Versioned files, human edits via PR, our own trust layer | **ADOPT (the base)** | Only approach that is human-governed, reviewable, and audited by construction — matches spec-as-code + Rego-in-repo. |

---

## The finding that rules out every managed framework

> **Every managed memory framework — Mem0, Zep, Letta, Cognee — assumes the agent has authority to write memory directly.** None natively supports *human-governed* memory updates.

Our doctrine (docs `04`) *requires* human ratification of risky/uncertain knowledge, an immutable audit trail, and provenance on every fact. A memory store the agent writes unilaterally violates all three. So **no off-the-shelf memory product can own our KB** — the same conclusion the drift-sync research reached. Human-governed memory is a moat, not a missing feature we should shop for.

This is why the base is **markdown/spec-as-code in the repo + our provenance layer**: it keeps memory as inspectable, versioned artifacts — *with* the PR review, audit, and human governance that MemPalace (agent-authored, local-first) does not provide.

---

## What to steal (mostly from MemPalace)

1. **Structure beats flat search — scope retrieval by the code graph.** MemPalace's central, benchmarked claim is that imposing a *hierarchy* over memory and searching *within a scope* beats flat vector search by a wide margin (they report ~61%→~95% recall). We already own the perfect hierarchy: the **structural KB** (module → file → symbol) and the **spec tree** (domain → epic → unit). So the semantic layer should **not** be a flat vector search over everything — it should be **scoped by the structural graph**: resolve the relevant module/domain first, then embed-search *within* it. This is a concrete upgrade to the Truth KB (`04`), not just the episodic layer, and it's the single most actionable idea from the whole survey. *(Treat their exact numbers as contested; adopt the principle, which is sound regardless.)*

2. **Verbatim + pointer, never lossy summarization.** MemPalace stores raw text and retrieves by search rather than paraphrasing into "extracted facts." That matches our doctrine directly: a summarized memory is a *hallucination surface*. Store the verbatim evidence (or a pointer to it in the audit ledger) and derive views on read — never let a lossy paraphrase become the remembered "truth."

3. **Layered / incremental context loading.** MemPalace loads a tiny top layer at startup (~hundreds of tokens) and pulls deeper detail on demand. Adopt this for how agents load KB/memory into context — load the module map + relevant lesson headers first, fetch full detail only when a stage needs it. Pairs with the **Model Gateway** token budgets (`03`).

4. **Bi-temporal facts (from Graphiti, corroborated by MemPalace's validity windows)** — every Truth-KB and episodic fact carries *two* timestamps: when it **became true in the code** and when it was **last verified/invalidated**. Exactly the machinery the **Drift Reconciler** needs to answer "is this spec link stale?" — adopt the model, not the product.

5. **Event-stream-as-source-of-truth, framework-as-index** — keep the raw stream (prompts, decisions, ingests, outcomes) in **our own audit ledger** as the source of truth; treat *any* memory tool as a **disposable index** rebuilt from it. This keeps every memory technology swappable and never load-bearing — and is what lets us safely *prototype* MemPalace for the episodic layer without betting the system on it.

---

## The doctrine (add to `04`'s list)

9. **Two memories, two rules** — truth memory is derived and disposable; episodic memory is earned and precious. Never let one masquerade as the other.
10. **Outcome or it didn't happen** — episodic lessons are written only from concluded, evidenced outcomes (a gate fail, a rollback, a rejection), never from agent opinion.
11. **Check your scars first** — agents consult episodic memory for the target module/change-class *before* acting.
12. **Human-governed memory** — no framework may unilaterally own the KB; risky lessons are ratified before they can veto an action.
13. **Framework as index, ledger as truth** — the audit ledger is the source of truth; any memory tool is a rebuildable index over it.

## What this changes in the build

- **Add** the episodic-memory library + collection to the net-new list in `03` (a *memory-keeper*, alongside the audit ledger and Drift Reconciler). It is modest glue: a Mongo collection + a writer lib + a vector index + a "check-before-act" hook — not a new platform.
- **Feed** the bi-temporal model into the Drift Reconciler's design.
- **Add** the immune-system jobs (sampled re-verification + telemetry-contradiction watcher) next to the Drift Reconciler in `03`'s net-new list; the demotion lifecycle is a field + state on existing KB entries, not a new store. Phase 0 minimum: the demotion path + write-back-on-ship (`06`); the sampling/telemetry jobs land with the Reconciler in Phase 1.
- **Upgrade the semantic KB to structure-scoped retrieval** (`04`): resolve the module/domain via the structural graph first, then vector-search *within* that scope, rather than flat search over the whole corpus. Low-cost change, meaningful recall gain — and it makes citations more precise (a win for `06`'s grounding gate too).
- **Defer to Phase 1:** Phase 0 can run without episodic memory (the loop works on a single well-tested module); episodic memory earns its keep once the fleet is doing enough runs to *have* repeatable mistakes to avoid. A MemPalace sandbox spike for the episodic layer, if wanted, also belongs in Phase 1 — behind the isolation invariant (`02`) and never on the trusted path.
