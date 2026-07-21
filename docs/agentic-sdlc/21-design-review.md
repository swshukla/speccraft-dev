# 21 · Design Review — Open Items

*Reviewed: 2026-07-17 against docs 00–20 as pure ideation. Revised: 2026-07-18 — the review's major findings (circular-trust holes, throughput/decay dynamics, canonical-answer contradictions) have been **applied to the design docs themselves** and are removed from this doc. What remains below is only what is still open. Citations are `doc:line`. The two hand-run experiments (IV-CodingAgent reconciliation, bug-fixing-orchestrator) are used only as calibration priors for design parameters, not as a standard the spec is graded against.*

---

## Verdict

The idea is fundamentally sound in shape: derive as-is deterministically, elicit to-be from humans, adjudicate the difference, and let nothing act on unreconciled knowledge. That chain of custody for truth is the right spine for a brownfield-first system, and no competitor design surveyed in doc 01 has it.

The 2026-07-17 review found three circular-trust holes, four throughput/decay dynamics, and a set of cross-doc contradictions that would have defeated that spine if built as written. As of 2026-07-18 those are resolved in the docs (summary at the bottom). The remaining open items are two lower-stakes consistency gaps and a list of assumptions that can only be settled by building the first slice.

---

## Open — consistency gaps

None. The vocabulary cleanup pass (gate mapping, work-item taxonomy, "light Design", ruling taxonomy) was applied 2026-07-18 — see the record below.

---

## Open — assumptions to validate before committing the plan

These are not design flaws; they are load-bearing bets that only the first vertical slice can settle.

- **"~80% is assembly, not invention"** (01:86, 10:6) — carries the schedule thesis (03:112 "weeks-to-months") but has no derivation; treat as hypothesis, validate on the first vertical slice.
- **Coder quality at Sonnet-class pricing** (14:27 vs 01:39) — the cost model prices the token-dominant agent at the cheap tier while citing benchmark results; a forced upgrade to premium-tier multiplies the dominant cost line ~5×.
- **Regulatory permission for autonomous prod deploys** — asserted as the selected approach (00:30) while 00:188 leaves "what class of change may ship without a human" open; this is the single assumption that, if false, collapses Approach B to assistive-only. Resolve first.
- **"No production data ever reaches a model"** (02:24) vs the Monitor agent consuming production telemetry (02:53, 02:143) — telemetry payloads (error bodies, URLs, user context) need the same scrubbing guarantee as code context, and the spec doesn't yet say how. Note this seam now also carries the KB immune system's telemetry-contradiction detector (`05`), so its scrubbing design is on the trust-critical path, not just the monitoring path.
- **Kill-switch dependency** — blast-radius containment leans on the homegrown feature-flag service having a programmatic API (00:166, 00:30), which 02:119 itself flags as unconfirmed.
- **Crawl-tier gates** — the ~$600–1k local on-ramp (16:51) relies on CI running "the same gates (OPA, tests, oasdiff, Pact)" (16:39), but doc 13 classes those gates as build/adopt work (13:48-50); either budget their construction into Crawl or state that Crawl runs gate-less on developer judgment (16:44 already half-admits this).

---

## What's strong — keep and lean on these

- **The truth chain of custody** (derive → elicit → infer-as-hypothesis → never invent; 04:12, 09:18-25, 18:29) is the design's genuine differentiator. Doc 18's refinement — invention allowed only into a non-acting hypothesis tier ("Hypotheses ask; they never act," 18:109) — is the most intellectually solid piece in the set.
- **Capture-on-contact** (09:31-41): every founder answer becomes a dated, cited, `human-asserted` KB fact so the system never asks twice. This is the cheapest high-leverage mechanism in the whole design; build it first.
- **The judge-calibration rule** (07:25, 07:55): no LLM-as-judge is trusted until meta-evaluated against human labels. Correct, and rarer than it should be.
- **Gate 4, testable-by-construction** (06:78, 06:85): "a spec you can't turn into a runnable red test is not a spec — it's a wish." Right doctrine, now airtight: the acceptance tests are spec-born and read-only to the Coder.
- **The three-way disagreement-is-signal triangulation** (09:60-68) and the divergence-typed confrontation ledger (18:52-61) give the system a principled answer to messy brownfield input that none of the adopted OSS components have.
- **Doc 20's method itself** — checking the ideation against real artifacts and downgrading its own claims (20:131-136, 20:169-172) — is the right epistemic habit; institutionalize it as a recurring design-review gate rather than a one-off doc.

---

## Record — revisions applied 2026-07-18

For traceability only; the full text lives in the docs cited.

1. **Eval grounding** — Coder replay-eval restricted to post-KB ratified-spec PRs; pre-KB history demoted to weak capability signals; "ratified history is ground truth" doctrine; verdicts carry KB-coverage (`07`, `06`).
2. **Critic/oracle independence** — acceptance tests are spec-born at gate 4 and read-only to the Coder; the Critic is KB-anchored, refuting against ratified clauses with citations (`04`, `06`, `11`, `13`).
3. **Earned auto-accept** — every claim category starts human-ratified; auto-accept earned per category by measured error rate, revoked on regression; high-risk never earns it (`04`, `06`).
4. **KB immune system** — sampled re-verification, telemetry contradiction detection, and a `ratified → challenged → demoted` lifecycle; gate passage necessary but not sufficient to write into the KB; target is a stationary error rate (`05`, `04`, `03`).
5. **Adjudicator as designed component** — one ranked queue (citation count × execution frequency × consequence class), delegation tiers, back-pressure that slows intake rather than lowering the trust bar (`09`).
6. **Autonomy gate scoped to blast radius** — divergences block only the paths they touch; deferrals carry TTLs that expire into escalation (`18`).
7. **KB freshness in Phase 0** — write-back-on-ship on every merge; gate 2 fails stale/demoted citations (`06`, `03`, `10`).
8. **Cell bootstrap** — factory ships process, not trust; new cells start at Crawl/Walk and graduate to Run via an explicit eval-asset checklist (`17`, `16`).
9. **Canonical answers** — doc 03's build list canonical over 10's summary; doc 10's roadmap canonical over 00's phase sketch; minimal eval slice moved to Phase 0 in 10; in-tenant sandboxes canonical, doc 01's SaaS picks marked superseded; code graph is a warm Zone-2 service, only stage-workers ephemeral (`00`, `01`, `02`, `03`, `10`, `14`).
10. **Gate vocabulary unified** — doc 13 §3 gains a Spec-gauntlet-scripts component (gates 1–3, previously unowned) and an explicit mapping of `06`'s nine spec gates onto implementing components; blast-radius/canary/design/code-review identified as diff-and-deploy gates outside the spec gauntlet (`13`).
11. **Work-item taxonomy unified** — doc 15's table declared canonical (JIRA types are the carrier, not the taxonomy); docs 11 and 13 point to it; doc 06's JIRA mapping gains the missing Idea/one-line-problem-statement row (`15`, `11`, `13`, `06`).
12. **"Light Design" defined** — pinned in `15` as the A3 Plan/Design stage at unit scope with the human design-review gate skipped (escalates to full Design on new seams or risk triggers); cross-linked from `11` A3.
13. **Ruling taxonomy made extensible** — the three rulings in `18` become the canonical core of an open label set (adjudicators add labels on contact; recurring labels get promoted), per doc 20's observation that the one manual run needed ~nine labels.
14. **Headline metric is human leverage, not autonomy** — autonomy rate demoted from KPI to diagnostic; touches split into *intent touches* (the system's fuel — ratifications, rulings, elicitation answers) vs *failure touches* (waste); headline = human-leverage ratio (verified shipped work per human hour) with failure-touch rate as its quality counterpart (`19`).
