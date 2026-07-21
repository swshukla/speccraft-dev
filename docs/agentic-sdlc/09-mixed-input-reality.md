# Agentic SDLC — The Mixed-Bag Input Reality

**Date:** 2026-07-11
**Purpose:** The earlier docs assumed inputs are *code* (derivable) or *written problem statements*. The real product is messier: knowledge is split across **built code, a partial backlog, and — the majority — the founder's head.** This doc handles that reality, especially the tacit part, which nothing upstream can derive or infer.

## The three input classes (they behave nothing alike)

| Source | Form | Certainty | Who holds it | How it enters the KB | Failure mode if mishandled |
|---|---|---|---|---|---|
| **Built code** | executable, precise | ground truth — but **intent-opaque** | the repo | deterministic derivation (Serena, `04`) | you know *what* it does, not *why* |
| **Backlog** | semi-structured text (JIRA) | *stated* intent, often **partial / stale** | tickets | parse → ground → PM/Spec (`06`/`08`) | trust a stale ticket as current truth |
| **Founder's head** | tacit, unwritten | the **actual intent** — but volatile, un-citable | one/few people | **elicitation** (this doc) | the LLM *invents* intent nobody stated |

> The trap is the third row. Code you derive; backlog you parse; **intent that lives only in someone's head can only be *asked for*.** An agent that fills that gap by guessing is hallucinating product direction — the most expensive kind of wrong.

---

## The governing principle: derive → elicit → infer, never invent

This extends doc `04`'s "derive before you infer" with the rung it was missing:

1. **Derive** what the code makes certain (structure, contracts) — free, deterministic.
2. **Elicit** what only a human knows (intent, priorities, domain rules) — *ask the founder before letting a model guess.* For intent, a human answer outranks any LLM inference.
3. **Infer** only as a last resort, and only as a **tagged hypothesis** requiring confirmation — never as fact.
4. **Never invent** — no unstated user need, no assumed intent presented as truth (`08`'s "cite or it's a hypothesis").

The correction to `04`: don't let the LLM *infer* intent when a human could simply *tell you*. Asking is cheaper and correct. The discipline is only to ask *well* — because founder time is the bottleneck.

---

## Capture on contact (the mechanism that makes this affordable)

You do **not** do a big upfront brain-dump. You externalize the founder's head **incrementally, as a byproduct of real work:**

> **Every time the founder answers a clarifying question, that answer becomes a durable, cited KB fact — so the system never asks twice.** The brain-dump is amortized across actual tickets, one ratified answer at a time.

- **Provenance = `human-asserted`.** A distinct tag: not derived-from-code, not inferred-by-LLM, but **founder-ratified, dated.** Highest trust for *intent* — but volatile (intent changes), so it carries a date and is re-confirmed on staleness or when code catches up to it.
- **Ask once.** Future agents read the captured fact instead of re-asking. The intent KB grows monotonically from your head.
- **Batch & prioritize.** Founder time is the scarcest input in the system. Questions are grouped, closed-form, and ranked by value — you answer a dozen high-leverage questions, not a stream of trivia.

This quietly solves a *business* risk too: "majority in my mind" is a single point of failure. The elicit-and-capture loop is also a **knowledge-continuity mechanism** — it turns your head into a durable, queryable asset, lowering bus-factor as a side effect of shipping.

---

## Route by module maturity (the seeding order this implies)

Different parts of the product sit at different maturities, so the pipeline picks a mode per module:

| Module profile | Primary mode | Elicitation load |
|---|---|---|
| **Built & stable** | archaeology — derive from code (`04` Seed-2) | low (confirm intent only) |
| **Built, intent unclear** | derive structure + **elicit the "why"** | medium |
| **Backlog-only (spec'd, not built)** | forward spec-first (`06`), grounded at the seams | medium |
| **In-head only (not built, not written)** | **elicit first** → problem statement (`08`) → forward spec | high |

This is both a routing rule and a risk map: start where derivation carries the load and elicitation is light; save the in-head-only modules until the capture loop is trusted.

---

## Triangulate three ways — disagreement is signal

The three sources will contradict each other, and each contradiction is information, not noise:

- **code ≠ intent** → the code is legacy/wrong, *or* intent changed → a Drift-Reconciler-style finding (`03`), routed as a decision.
- **backlog ≠ intent** → stale backlog → a grooming ticket.
- **code ≠ backlog** → drift between what was planned and what shipped.

None is silently auto-resolved; each surfaces to the human who owns the intent. This is `04`'s triangulation, now three-way.

---

## Proactive externalization (optional, high-leverage)

Beyond *pull* (ask when blocked), the system can *push*: periodically present **its model of the product** — the module map, inferred domain rules, the roadmap it reconstructed from code + backlog — and ask *"what's wrong or missing?"*

> "Here's what I think the system does and where it's going. Correct me." — this drains tacit knowledge far faster than waiting for blocking questions, and doubles as a KB-accuracy audit.

Guardrail: proposal-only, founder ratifies (same L0–L1 stance as the PM Agent, `08`). Phase 2+.

---

## Where it runs / isolation

- **Elicitation surfaces in JIRA** — the human-in-the-loop channel already used for clarify/ratify.
- **Captured facts** become **`human-asserted` intent-KB entries** in the agentic plane's **own store** (isolation invariant, `02`), with provenance (who, when, ratified) per `05`.
- No new infra — this is a *provenance class + a capture hook* on the existing Spec/PM clarify loops, not a new component.

---

## The adjudicator is a designed component, not a free resource

Every trust mechanism in this design terminates in the same place: a human ruling. Spec ratification (`06` gate 9), KB ratification (`04` check 5), divergence rulings (`18`), drift findings (`03`), episodic-lesson governance (`05`) — all queue on founder/expert attention. That makes **adjudication capacity the throughput ceiling of the whole system**, and it has to be designed like any other bottleneck, not assumed infinite:

- **One queue, one ranking.** All adjudication requests land in a single ranked queue (surfaced in the tracker), prioritized by the **value of the divergence**. You can't know a priori which disagreement matters, but you can proxy it: *citation count* (how many specs/modules ground in the answer) × *execution frequency* (how often the code path runs in prod) × *consequence class* (money/auth/data vs. copy). The load-bearing dozens get answered; the long tail waits without blocking work it doesn't touch (`18`'s blast-radius gate).
- **Delegation tiers.** Not every ruling needs the founder: module-scoped, low-consequence questions delegate to a domain owner; only cross-cutting intent and high-risk classes escalate to the top. Provenance already records *who* ruled.
- **Back-pressure, never bypass.** When the queue exceeds capacity, the pipeline **slows intake** — fewer modules in flight, elicitation batched harder. It never responds by widening auto-accept or letting hypotheses act. A backed-up queue is a visible, managed state (queue depth and ruling latency are first-class KPIs, `19`), not a silent one.

---

## Doctrine

1. **Derive → elicit → infer, never invent** — ask a human for intent before letting a model guess it.
2. **Capture on contact** — every answer becomes a cited, dated `human-asserted` fact; ask once.
3. **Intent is volatile** — `human-asserted` facts carry a date and are re-confirmed on staleness or when code catches up.
4. **Route by maturity** — derive-heavy modules first; in-head-only modules last.
5. **Three-way triangulation** — code/backlog/intent disagreements are surfaced as decisions, never auto-resolved.
6. **Externalize as a byproduct** — the founder's head drains into the KB through real work, not a big upfront dump; this is also knowledge-continuity insurance.
7. **Adjudication is the throughput ceiling** — one ranked queue, value-proxied ranking, delegation tiers, and back-pressure that slows intake rather than lowering the trust bar.

## Phase 0 scope

Deliberately pick a **code-complete, low-risk module** for the first loop — derivation carries it, elicitation is light — so you prove the loop before leaning on heavy founder Q&A. **But turn on "capture on contact" from day one:** every clarifying answer in Phase 0 is captured as a `human-asserted` fact, so the intent KB starts filling immediately and the elicitation muscle is exercised early on low stakes. In-head-only modules and proactive externalization come once that habit and the capture loop are trusted.
