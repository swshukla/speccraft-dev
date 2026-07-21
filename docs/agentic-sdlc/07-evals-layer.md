# Agentic SDLC — The Evals Layer

**Date:** 2026-07-11
**Purpose:** How we measure and defend the *competence* of the agentic system itself — the agents, the gates, and the judges — as distinct from the per-run guardrails that protect a single deploy.

## Evals are not guardrails

The most important distinction in this doc:

| | **Guardrails** (docs `04`/`06`) | **Evals** (this doc) |
|---|---|---|
| Question | "Is *this* spec/diff/deploy safe?" | "Is the *Spec Agent / gate / judge* any good — and did it regress?" |
| When | Online, every run | Mostly offline; continuous online signals |
| Protects | This production change | The system's competence *over time* |
| Failure it catches | A bad artifact | A bad *agent, prompt, model, or gate* |

> A guardrail tells you a spec is wrong. An eval tells you the Spec Agent got worse after last Tuesday's prompt change — *before* it ships a hundred subtly-wrong specs. **You need both: guardrails protect the run, evals protect the system.**

---

## What we evaluate (the subjects)

1. **Each stage agent** — Spec, Coder, Critic, Verifier, Deployer, Monitor. Is each doing its job at the quality bar?
2. **The gates themselves** — precision/recall of every validation gate. Does gate 7 (adversarial) actually catch letter-vs-intent violations? Does the policy gate over- or under-trigger? *An unmeasured gate is a guess.*
3. **The judges** — any LLM-as-judge must be **meta-evaluated against human labels.** An unvalidated judge is an unmeasured ruler; trusting it is the recursive-trust trap. Calibrate it, and track its drift.
4. **The end-to-end loop** — problem → shipped: success rate, human-touch rate, cycle time, cost/run.

---

## Three kinds of eval

### 1 · Offline / benchmark — *before anything ships*
Golden datasets the system is scored against, deterministically and cheaply:
- **Spec Agent:** curated `(problem statement → known-good spec)` pairs from your own history. Metrics: grounding accuracy (cited claims that actually match the KB), criteria-testability rate, conflict-detection recall, non-goal coverage.
- **Coder:** an **internal SWE-bench** — replay past merged PRs as tasks, **but only PRs shipped after the KB existed, whose specs were ratified**: for those, history and the adjudicated KB agree by construction, so the merged diff + its ratified acceptance tests are genuine ground truth. Metric: % of ratified tasks where the agent's diff passes the ratified acceptance tests. **Pre-KB history is not a correctness oracle** — it is exactly the intent-opaque artifact the KB exists to correct (`09`/`18`): a merged diff may encode a bug that shipped, and tuning the Coder to reproduce it optimizes for the mess. Pre-KB PRs serve only as *weak capability signals* (did the agent locate the right files; does its patch pass the suite) — never labeled "correct."
- **The gauntlet / gates — the seeded-defect suite:** inject known-bad specs and diffs (a hallucinated endpoint, a contradicted invariant, a silent breaking change, a missing edge case) and measure each gate's **catch rate (recall)** and **false-positive rate (precision)**. *This is the only way you know the guardrails actually guard.*
- **Critic:** must refute the seeded-bad and pass the seeded-good — precision/recall on the same suite.

### 2 · Online / production — *continuous, lagging truth*
Real signals, derived from the audit ledger + episodic memory (`05`):
- **Escalation rate**, **human-override rate**, **rollback rate**, **drift-reopen rate**, **cycle time**, **cost/run**.
- **Gate-pass-then-fail-later** — the sharpest signal: a gate passed something that later rolled back = a *measured gate miss*. Every such event becomes a new seeded-defect case. Production teaches the gates.

### 3 · Regression gating — *CI for cognition*
> **Changing a prompt is a deploy.** Any change to a prompt, tool, model, or gate must pass the offline eval suite before it goes live.

The agentic system builds software; the agentic system *is* software, held to the same discipline it enforces. This is the meta-loop that keeps self-modification safe.

---

## The doctrine

1. **Evals ≠ guardrails** — guardrails protect the run; evals protect the system's competence over time.
2. **Ratified history is ground truth** — PRs, specs, and incidents that shipped *through* the adjudicated loop (audit ledger + episodic memory) are free, grounded eval data; the system generates its own future eval set from every run. History from *before* the KB existed is capability signal only — it was never adjudicated, and an eval that treats it as correct re-imports the mess the KB was built to correct.
3. **Meta-evaluate the judges** — an LLM-as-judge is calibrated against human labels before it's trusted, and its drift is tracked. Never trust an unmeasured ruler.
4. **Hold out to avoid overfitting** — keep an eval set the prompts/agents are *never* tuned on. Otherwise you optimize to the test and learn nothing.
5. **Every self-change is regression-gated** — prompt/model/gate/tool changes pass evals before shipping.
6. **Sovereignty is proven by evals** — the foundation→sovereign model swap (the Model Gateway seam, `02`) is validated by re-running the full suite. *"At least as good on our evals"* is the go/no-go. This is how model sovereignty becomes safe rather than a leap of faith.
7. **Offline before online** — cheap deterministic eval sets catch regressions before they ever touch a real ticket.
8. **A verdict is only as strong as its coverage** — every eval and gate verdict carries the KB-coverage of the surface it judged (`06`); a pass against thin coverage routes to elicitation (`09`) instead of silently counting as a pass.

---

## Where it runs (and it lives in the isolated plane)

- **Offline eval harness** — a batch job in the **agentic control plane (Zone 2)**, on the agentic system's **own dedicated infra** (see `02`, isolation invariant), triggered by the agentic system's *own* CI on any agent/prompt/gate/model change, and on a schedule.
- **Eval datasets** — golden specs, replayed PRs, seeded defects, judge-calibration labels — live in the **agentic plane's own store, never the application DB.** They use code + synthetic fixtures, **never regulated data** (consistent with the compliance envelope in `02`).
- **Online metrics** — derived from the agentic-plane audit ledger + episodic memory + the **read-only telemetry seam** to production (not a shared datastore).

**Net-new to build:** the eval harness (runner + dataset store + metrics dashboard), the golden/seeded datasets (curated from history — modest but *ongoing* curation), the judge-calibration set, and the regression gate wired into the agentic system's CI. Most of the execution machinery is *reused* — the same test runner and Model Gateway the loop already uses.

## Phase 0 scope

Start minimal but real: the **Coder replay-eval** (post-KB ratified PRs — until enough exist, the seeded-defect suite and golden spec set carry the load), a **seeded-defect suite** for the gates you actually ship (1–4, 8 from `06`), and a **small golden spec set** (a dozen hand-curated pairs). **Regression-gate prompt and model changes from day one** — it's cheap and it's the single highest-leverage habit for keeping an autonomous system from silently rotting.
