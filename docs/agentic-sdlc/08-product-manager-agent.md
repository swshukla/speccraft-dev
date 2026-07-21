# Agentic SDLC — The Product Manager Agent

**Date:** 2026-07-11
**Purpose:** The front of the pipeline. It turns *raw signal* — an ask, a pain, a metric anomaly, a recurring incident — into a **well-formed, evidence-grounded, prioritized problem statement** that the Spec system (`06`) can consume. It fills the gap `06` assumed away: that a good problem statement already exists.

## Autonomy inverts with altitude (the governing principle)

This is why a PM Agent is fundamentally different from the Coder or Verifier:

```
ALTITUDE        DECISION                       VERIFIABLE BY      AUTONOMY
─────────────────────────────────────────────────────────────────────────
PM        why / what-problem / worth-solving   human judgment     L0–L1  (propose, human ratifies)
Spec      what-exactly / acceptance contract    KB + tests        L1–L2  (validate, human ratifies intent)
Build     how / code                            execution         L2–L3  (autonomous within gates)
Test/Ship does-it-work / is-it-safe             execution         L2–L3  (autonomous within gates)
```

> The lower the altitude, the more a machine can *prove* it's right, so the more autonomy is safe. The higher the altitude, the more the decision is a *value judgment* no execution can settle — so the human keeps it. **The PM Agent is the least autonomous agent in the system, on purpose.** You never want an AI unilaterally deciding product direction.

---

## Boundary: PM owns the *problem*, Spec owns the *solution*

Clean handoff, no overlap:

| | **PM Agent** | **Spec Agent** (`06`) |
|---|---|---|
| Owns | the **problem** — why, who, worth it, how much | the **solution contract** — what exactly, verified how |
| Input | raw signal (ask / pain / metric / incident) | a ratified problem statement |
| Output | a **problem statement** (evidence + success metric + priority) | a **spec** (acceptance criteria + contracts) |
| Human gate | "is this worth solving, and is this the real problem?" | "does this spec solve the stated problem?" |

The PM Agent's output *is* the Spec Agent's input. Together they cover the two human gates the system deliberately keeps: **what to build** (PM) and **does the spec match intent** (Spec).

---

## What a problem statement is (the artifact)

Written to JIRA + as spec-as-code draft, structured so the Spec Agent can ground it:

1. **Problem & job-to-be-done** — the actual problem, not the requested feature. *Symptom vs root cause is explicit.*
2. **Who & reach** — who is affected, how many, how often.
3. **Evidence** — the signals this rests on: support tickets, telemetry, incidents, user quotes, episodic memory. *Every problem claim cites evidence or is marked a hypothesis.*
4. **Success metric (outcome, not output)** — "increase recurring-investment adoption by X%", not "ship a recurring-invest button". This is what the Monitor/evals layer later measures to close the loop.
5. **Constraints & non-goals** — regulatory, technical, explicit out-of-scope.
6. **Priority proposal** — impact × reach vs effort (effort estimated from the KB blast-radius), and alignment with stated goals. *Proposed, not decided.*
7. **Links** — related specs, prior attempts (episodic memory), affected modules.

---

## The PM pipeline

> **Governing rule: cite or it's a hypothesis.** A problem grounded in a real signal (a ticket, a metric, an incident) is a *problem*. A problem with no evidence is a *hypothesis* — allowed, but tagged as such and routed to validation, never presented as fact. This is `04`/`06`'s anti-hallucination doctrine applied to product: **no invented user needs.**

1. **Intake** — receive raw signal (see triggers below).
2. **Frame** — articulate the real problem + JTBD; separate symptom from root cause. Ask the human a closed clarifying question if intent is ambiguous.
3. **Ground in evidence** — pull support tickets, telemetry (read-only seam), incidents (from Monitor), episodic memory, existing specs. Attach evidence to every claim; flag the unevidenced.
4. **Assess** — impact × reach, effort (from KB blast-radius), alignment with goals, opportunity cost.
5. **Prioritize** — *propose* a ranking; the human decides. The PM Agent never self-authorizes what enters the build queue.
6. **Shape** — scope, success metric, constraints, non-goals (Shape-Up-style shaping).
7. **Ratify (human)** — a human accepts/reprioritizes/rejects. Only ratified problems hand off to the Spec Agent.

---

## Triggers — reactive and (optionally) proactive

- **Reactive** (default): a human stakeholder ask, a support-feedback theme, a sales request → JIRA.
- **From the loop:** the **Monitor** surfaces a recurring incident or a shipped-but-didn't-move-the-metric outcome → the PM Agent frames it as a new problem. *This closes the outermost loop* (below).
- **Proactive discovery** (opt-in, Phase 2+): the PM Agent watches telemetry for anomalies (adoption drop, funnel leak) and *surfaces candidate problems* for human review. Powerful but noisy — strictly **proposal-only, never self-authorizing**, and gated behind an explicit toggle.

---

## Closing the outermost loop

The PM Agent is what makes the whole system *outcome-driven*, not just *output-driven*:

```
PM (problem + success metric) → Spec → Build → Ship → Monitor (measure the metric)
        ▲                                                        │
        └──────────  did it actually solve the problem?  ────────┘
```

- The **Spec↔code** loop (`06`) proves the code matches the spec.
- The **Drift** loop (`03`) proves code and spec stay coherent.
- The **PM↔outcome** loop proves the *shipped thing actually solved the problem* — and if it didn't, that's a new, evidenced problem statement. This is the loop that stops the system from efficiently building the wrong things.

---

## Where it runs

Same rails, same isolation invariant (`02`):
- **PM Agent** — an ephemeral **Zone 3** stage-worker, dispatched by the Orchestrator, torn down after each run.
- **Reads** evidence through **read-only seams** — the telemetry export, support/JIRA APIs, incidents from Monitor — plus episodic memory and the KB (all in the agentic plane's own store). It never connects to the application datastore.
- **Writes** problem statements as **JIRA issues + spec-as-code drafts** (PRs), never straight into the build queue.
- **Human ratifies** in JIRA — the same human-in-the-loop surface as clarify/ratify elsewhere.
- **Autonomy: L0–L1** — assistive and proposal-only. Explicitly *not* L3, ever.

---

## Doctrine

1. **Autonomy inverts with altitude** — product decisions stay human; only execution-verifiable work goes autonomous.
2. **PM owns the problem, Spec owns the solution** — clean handoff, no overlap.
3. **Cite or it's a hypothesis** — no invented user needs; unevidenced problems are tagged, not asserted.
4. **Symptom vs root cause** — frame the real problem, not the requested feature.
5. **Outcomes, not outputs** — every problem carries a success metric the Monitor later measures.
6. **Propose, never self-authorize** — the PM Agent ranks and shapes; a human decides what gets built.
7. **Close the outer loop** — "did it solve the problem?" feeds the next problem.

## Phase 0 scope

**Defer, or run purely assistive.** In Phase 0, humans write problem statements directly (as `06` assumes). The PM Agent is a **Phase 1+** addition, and even then it starts **reactive and assistive only** — it drafts and grounds a problem a human brought, with a human ratifying. Proactive discovery is Phase 2+, behind an explicit toggle. The altitude principle means this is the *last* place to add autonomy, not the first.
