# 20 · Field Validation — Our Design vs. Two Real Systems

## Why this doc exists

We designed an end-to-end autonomous development pipeline on paper across ~19 docs, before
seeing any of your production code. You then pointed us at two systems you've actually built and
run:

- **bug-fixing-orchestrator** — a live production pipeline that watches Jira/PostHog/SigNoz for
  bug alerts, writes a fix, and opens a PR for a human to review.
- **IV-CodingAgent** — a framework that reconciles what a codebase actually does against what its
  tickets/specs say it should do, running against a live Next.js/Node app.

Both repos were cloned and read in full, claim by claim, against the source — not summarized from
memory. This doc reports where our design and your real systems agree, where your systems are
ahead of our design, and where our design goes further than anything built or proven yet.

This does not get merged into the doctrine list until each item below has a disposition (adopt /
defer / already covered).

## 1 · Gaps in our design — your systems already solve these, we should adopt them

**A "is this fix real, or a band-aid" check.** Our design's Component View has a Verifier (do
tests pass) and a Reviewer (is the code good), but nothing asks "did this fix the actual root
cause, or just hide the symptom." bug-fixing-orchestrator has exactly this as its own pipeline
step: it classifies every fix as root-cause / boundary-guard / band-aid / unknown (the last being
a fallback when the model's answer can't be parsed), each with a confidence score. When a fix is a
high-confidence band-aid, one setting (`DEPTH_GATE`, per deployment) picks the response: `label`
still opens the PR but tags it and surfaces the root cause it masked, while `divert` withholds the
PR entirely and emails a human a diagnosis instead. A root-cause fix or a legitimate boundary-guard
is never flagged. This is a distinct check from "does it work" and "is it well-written," and needs
its own slot in our pipeline, not folded into Reviewer.

**What happens when two things go wrong at once, or a worker crashes mid-fix.** Our design assumes
one clean run at a time and doesn't say what happens otherwise. The real orchestrator has an actual
answer: it atomically claims an incoming alert (one atomic database update, so two triggers for the
same bug can't both start fixing it), and if the worker holding that claim dies mid-run, a sweep
that runs hourly finds claims that have gone stale — older than a fixed timeout, a full day by
default — and releases them back for retry (capped at exactly 2 attempts before the issue is parked
as failed for a human). Worth noting: detection is timer-based, not a live "is this worker still
alive" check — a slow-but-alive worker looks the same as a dead one, and a genuinely dead worker's
claim isn't reclaimed until that day-long timeout elapses. We should adopt the pattern, with that
caveat in mind.

**A middle tier between "one deployment" and "fully separate customer."** Our multi-org design
jumps straight from "single deployment" to "fully isolated org." The real system has a documented,
deliberate middle rung (a `docker-compose.prod.yml` plus a `DEPLOY-PROD.md` runbook): two processes
on one machine — one per environment (dev/prod) — built from the same image and sharing the same
infrastructure, but with separate policy (dry-run on/off, a daily PR cap, which branch to target),
separate env files, a separate webhook secret, and separate databases. The one credential they
deliberately share is the GitHub App key. That's a real, working middle rung we're missing: same
product, same infrastructure, different environment, different risk tolerance.

## 2 · Present in our design but underspecified — your systems show a fuller version

**More outcome states for ruling on a divergence.** When our design finds a gap between what the
code does and what it should do, it allows exactly three rulings (its words: "Fix the code / Fix
the model / Accepted deviation"). IV-CodingAgent does the same kind of ruling in practice, and its
real adjudication log uses far more — nine distinct labels, including a clean false-positive state,
a "keep both" state, and a "revisit later" state. **Caveat:** this isn't a clean, disciplined
system we can copy wholesale — there's no schema or enum anywhere, just free-text labels a human
wrote inconsistently in a markdown log (even "deferred" is written two different ways). The real
evidence is "you will need more than three rulings," not "here is the exact list to adopt."

**How to actually test that the AI did its job.** Our design says fixes/features need evals but
doesn't say what an eval looks like. Both real systems have a concrete, working answer. In its
security/access eval set, IV-CodingAgent writes a test expected to fail (RED) until the specific
fix ticket — named in the eval — merges, then it must turn green; each such eval pairs a
"vulnerability present" assertion with a "vulnerability fixed" one and records which ticket flips it
(its feature evals are plainer pass/fail). Separately, the orchestrator's test suite pins the
*shape* of what happened across twelve named scenarios (which steps ran, what state things ended in,
was an email sent, was the knowledge base written, did the AI agent run at all) rather than pinning
exact text output — which is specifically good at catching a refactor that silently changes
behavior, something exact-output tests miss.

**The caveat that decides whether the RED-test pattern is worth anything: an AI-written test that
the same AI then makes pass proves nothing on its own — you've just moved the trust problem from the
fix to the test.** The security/access evals escape that only because three things happen to hold
there: the test pins *observably wrong behavior* you can exhibit today (tenant B can read tenant A's
data — run it and watch), the definition of "wrong" comes from a hard invariant plus a
human-adjudicated ticket rather than from the AI, and the test itself passes a named-human review
gate before it counts. Strip any of those and the circularity returns — which is exactly what
happens in the real system's own fuzzier eval set (education-loan), where there's no crisp oracle
and the evals fall back to plain pass/fail. So the pattern is **not extendable by itself**. It
extends only as far as we can ground each eval's notion of "correct" in the human-adjudicated
knowledge base we've been building toward — the reconciliation decisions and spec ground truth, not
the agent's own idea of what the fix should do. Adopt the orchestrator's shape-based scenario
testing broadly; adopt the RED-test pattern only where an eval is anchored in that KB and a human
has ratified the test.

**One config file per project, plus a live-override layer.** Our design says config for a target
should live in one place but doesn't say how you'd change it without redeploying. The real system
has this fully built: one profile object per project holding build/test commands, telemetry source,
secret references, and knowledge-routing rules — plus a live-override layer on top with caching, a
guard against duplicate concurrent fetches, a fallback to the last-known-good value if the override
store is down, and a kill switch to force code-only config. This is a complete, working answer we
should adopt as-is.

**Working metrics, not just a wishlist.** Our design lists metrics it wants (escalation rate,
rollback rate, cost per run) but never shows one computed. The real system actually computes them
from live data: a fix-merge rate (merged PRs over PRs opened) in its nightly report, and a per-run
dollar cost derived from a token-count × model-price table in each run's log. Confirms the idea is
practical, not just aspirational.

**A rule for what goes in a design doc vs. a "here's how we found this" narrative.** IV-CodingAgent
has this rule written down explicitly: the design doc records facts and decisions; the story of how
those facts were discovered belongs in a separate reconciliation doc, never the design doc itself.
Our docs don't have this rule yet and would benefit from it (this doc follows it).

**Tickets that block other tickets.** IV-CodingAgent's ticket specs carry an explicit
"blocked_by" field naming other tickets. Our design doesn't model ticket dependencies at all —
worth adding.

## 3 · Confirmed — no changes needed

Three things our design insists on are already true in the real, production system, with no gaps:

- **No auto-merge, ever.** The real system's git integration has no merge capability at all — only
  "open a PR" and "read PR state." Every fix is a PR a human must approve.
- **Disposable, locked-down sandbox.** Every run gets its own temp directory, destroyed when the
  run ends (even on failure), and secrets are stripped from the environment before any untrusted
  code runs in it — specifically to stop a poisoned dependency or an AI-written test from stealing
  credentials.
- **Swappable AI/git-host/ticket-tracker providers.** Which AI model, which git host, which ticket
  tracker to use are all chosen by config, not hardcoded — every provider is looked up by name
  through one registry. Honest caveat: the seam is real and config-driven, but today the AI-model
  and git-host slots each have a single implementation wired in; the ticket-tracker and agent-runner
  slots are the ones that actually ship more than one. So it's a proven *pattern*, not yet a proven
  swap for every slot.

## 4 · Where our design reaches past what's been built — labeled honestly

Two things here are genuinely unbuilt in either system; a third is an *extension* of something one
of your systems already proves works. I want to be careful about which is which — one draft of this
doc overclaimed the first item, and it's the kind of overclaim that would rightly cost us your
trust.

**First, the honest correction on intent reconciliation.** `18-first-principles-intent.md` proposes
deriving an "as-is" model purely from reading the code, keeping it separate from a "to-be" model
sourced from humans, and reconciling the two through deliberate human adjudication — never letting
the AI invent intent on its own. This loop is **not** ahead of your systems: IV-CodingAgent does
exactly this today. Its reconciliation flow reads what the code actually does, compares it against
what the Jira tickets/specs say it should do, and has a human rule each divergence (code is right /
ticket is right / keep both / defer). That manual version, running in markdown, is the strongest
evidence in either repo that the whole approach is sound. Where our design reaches past it is
narrower and should be stated as such: running that scan **proactively across a whole codebase**
rather than per-feature when a human kicks it off, and **automating the loop** instead of a person
writing the reconciliation by hand. Those two extensions are the unproven part — not the loop
itself.

**Second, genuinely unbuilt everywhere: checking consistency across repos.** `18-first-principles-intent.md`
also proposes a concept registry — canonical domain concepts (its own examples: "Wallet,"
"KYC-status," "Settlement") mapped to every place they're implemented, so two repos that implement
the same concept with different rules get flagged automatically. The closest thing in either of your
systems is one line in a spec (`context-graph-kb.md`) noting that cross-repo *linking* — tracing a
frontend call to the backend route it hits — isn't built yet and is scoped as future work. That's
adjacent but narrower: wiring calls together is not the same as flagging that the same concept is
implemented inconsistently across repos. No concept registry, and no cross-repo consistency check,
exists in either system — this one is genuinely ahead, and unbuilt everywhere.

**Third, also genuinely unbuilt: building a new feature end-to-end from a raw ask.** Both real
systems are purely reactive — they only act on what's already been flagged (a bug alert, a ticket to
reconcile); neither has a path from "here's an idea" to "here's a built feature." Our design does:
the PM Agent (`08-product-manager-agent.md`) takes a raw one-line ask, elicits the missing context
from a human, and turns it into a full problem statement, which feeds a Spec Agent and then the
Design stage before any code gets written (`15-work-item-taxonomy.md`). Nobody has run this path
end-to-end on a real ask yet, so it's ahead but unproven.

The honest framing across all three: none of these are "gaps neither of us has an answer for." One
is a loop your own system already validates by hand and we propose to automate; two are places our
design goes further than anything running anywhere. That's a real asset — but an unproven one, and
we should not present it as validated the way sections 1-3 are.

## Corrections worth flagging on re-read

Two items above needed real correction after checking source, not just adoption at face value:

- If we adopt an "only learn from finalized fixes" rule for our own design, don't assume the real
  orchestrator already enforces it — it doesn't. The orchestrator writes to its knowledge base at
  several points, and one of them fires the moment it decides to divert a case to a human (a
  terminal "diagnosed" state that has no PR and no merge behind it), not only after a fix is merged
  or closed. So it records the hand-off decision itself, not just the eventual code outcome. That's
  a fine design; it's just more permissive than the rule we'd be writing for ourselves — adopt the
  discipline as *our* rule rather than citing the orchestrator as proof it's already followed.
- The outcome-states claim in section 2 rests on nine free-text labels a human wrote by hand, not a
  designed taxonomy. Treat it as "you'll need more than three rulings," not as a validated fixed
  list to copy.

## What this changes in earlier docs

- **Component View:** add a fix-depth/band-aid gate as a named pipeline stage, distinct from
  Reviewer; add an explicit work-claim/crash-reap contract for the Orchestrator.
- **Memory Architecture:** episodic memory write timing narrowed to terminal states only, keyed by
  a stable signature — not written speculatively mid-run. Note that this is a rule we're setting for
  ourselves: the real orchestrator writes its knowledge base more permissively (including on a
  divert-to-human decision), so cite it as a working KB, not as proof this discipline is enforced.
- **Multi-Org, Multi-Product (Cells):** add an environment-scoped sub-tenancy rung — same cell,
  same product, different environment, different risk tolerance. The orchestrator's documented
  dev/prod two-process split is the concrete precedent for it.
- **First-Principles Intent:** clarify which parts are ahead. The reconciliation loop (as-is vs
  to-be with human adjudication) is *not* ahead — IV-CodingAgent runs a manual version of it. What
  is ahead, and unproven: making that scan proactive/whole-codebase and automating it, plus the
  cross-repo concept registry, which is unbuilt in either system.
- **Mission Control:** add the intrinsic metric catalog as concrete, proven-practical metrics to
  surface — the real system already computes a fix-merge rate (nightly report) and a per-run dollar
  cost (run log, from a token-count × price table).
