# Agentic SDLC — Work-Item Taxonomy & Treatment

**Date:** 2026-07-12
**Purpose:** A JIRA item is not one thing. A bug fix, a simple module, a product requirement, and a one-line problem statement enter at different **altitudes**, take different **paths**, need different **human involvement**, and cost different amounts. This defines each type's treatment — and corrects what "1 run" means for the cost model (`14`).

## The principle

> **Treatment scales with altitude and ambiguity.** The vaguer and higher-altitude the item, the more *define* work (elicitation, spec, design, human ratification) it needs before any code — and the more it **fans out** into multiple buildable units. The lower and more concrete, the more it goes straight to an autonomous build run. (This is `08`'s "autonomy inverts with altitude," applied to intake.)

Every item is **triaged at intake** (a cheap classifier step, `06`) onto one of the paths below.

## The taxonomy

> **This table is the canonical work-item taxonomy.** JIRA types are the *carrier*, not the taxonomy (`06` maps them); where other docs enumerate work-item types, this doc wins.

| Type | JIRA | Altitude | Path (which stages run) | Human load | Fans out into | Rough cost |
|---|---|---|---|---|---|---|
| **One-line problem statement** | Idea / empty Epic | **Problem** | **PM Agent: frame + *heavy elicitation*** (`09`) → produces a Feature | **High** — your Q&A + ratify intent | 1 Feature → then its runs | mostly *your time* + low tokens, **then** the Feature's cost |
| **Product requirement / Feature** | Epic / Feature | **Product** | PM (intent, ratify) → Spec (epic-spec, **decompose**) → Design → **N build runs** | **Med–High** — ratify intent + design | **3–15 Story/Task runs** | define + Σ child runs → **~$50–500+** |
| **Simple module / enhancement** | Story | **Unit** | Spec (unit-spec) → light Design → Coder → gates → ship | **Low–Med** — ratify spec, maybe review PR | **1 run** (sometimes 2) | 1 moderate run → **$8–26** |
| **Bug fix** | Bug / Task | **Unit (defect)** | repro + lightweight spec → Coder → gates → ship (*skips PM & Design*) | **Low** — often just approve the PR | **1 run** | 1 simple run → **$3–8** |

The bottom two rows are **atomic** — they *are* one run. The top two are **composite** — they're define-phase work that *generates* runs.

> **"Light Design," defined (the term lives only in this doc, so pin it):** the same Plan/Design stage (A3, `11`) run at unit scope — an implementation plan (files touched, approach, test strategy) cited against the KB, with **no new contracts at the seams** and the **human design-review gate skipped** (`11` reserves that gate for new systems, high blast radius, or auth/payments/PII anyway). If the unit turns out to need a new seam or trips a risk trigger, it escalates to full Design. A fast lane through the same machine, not a different machine.

## What this fixes about "1 run"

> **1 run = one *atomic build unit* — a Story, Task, or Bug ≈ one PR ≈ one shipped change.** Product requirements and problem statements are **not** runs; they're define-phase items that **decompose into multiple runs plus a define cost.**

So the cost math is **not** "total JIRA items × per-run." It's:

```
monthly cost ≈  Σ(atomic runs × per-run cost)          ← the builds (Coder-heavy, the bulk)
              + define overhead for Features/problems    ← PM+Spec+Design: your time + modest tokens
              + evals + infra
```

A **Feature isn't one line item at $8** — it's a define step **plus** its 3–15 child runs. Counting a requirement as a single cheap run is the classic way an estimate blows its budget; this taxonomy is what prevents that.

## The two useful units to quote

- **Cost per change** (per atomic run): $3–90 — good for "what does a routine ticket cost."
- **Cost per feature** (define + fan-out): ~$50–500+ — good for "what does shipping a *capability* cost." Quote this one when the audience thinks in features, not tickets.

## Treatment differences at a glance

- **Bug/Task** — skip PM and Design; go repro → fix → verify → ship. Cheapest, fastest, highest autonomy.
- **Story/module** — full unit-spec + light design + build. The everyday run.
- **Feature/requirement** — the full two-phase lifecycle (`11`): PM intent → epic-spec → decompose → design → many builds. Human ratifies intent once, machine builds many units.
- **One-line problem** — starts *below* zero: heavy **elicitation** (`09`) to turn "what's in your head" into a Feature before anything downstream. Your time is the gating cost, not tokens.

## Doctrine

1. **Treatment scales with altitude & ambiguity** — vaguer/higher = more define + more fan-out; concrete/lower = straight to build.
2. **Triage at intake** — classify every item onto a path before work starts.
3. **A run is atomic** — Story/Task/Bug ≈ PR. Composite items decompose into runs + define overhead.
4. **Cost by type, not by ticket** — never multiply all items by a flat per-run figure; separate atomic runs from composite items.
5. **Quote cost-per-feature to feature-thinkers**, cost-per-change to ticket-thinkers.
