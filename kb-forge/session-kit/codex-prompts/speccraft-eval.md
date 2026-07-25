---
description: Founder-only — use when the founder wants to check whether the speccraft KB system is actually working (loop usage, KB truth, behavioral lift), or to walk queued judge verdicts from a prior audit. Runs the Tier 1/2/3 eval scripts and narrates results; carries no measurement logic of its own.
---


# speccraft-eval — narrate the evals, walk the queue

This skill is UX only. Every number comes from the scripts in
`~/.speccraft/kb-forge/session-kit/evals/`; never compute or assert a rate,
verdict, or precision figure yourself — run the script and report what it
printed.

1. **Tier 1 — compliance telemetry** (always, cheap):
   ```
   ~/.speccraft/kb-forge/session-kit/evals/telemetry-report.sh
   ```
   Report the printed line verbatim (recall/ratify/stale/queue/ledger rates).
   If it wrote a `findings/*-evals-recall-rate.md`, say so and name the file
   — don't paraphrase the finding, point at it.

2. **Tier 2 — KB truth audit** (weekly / on demand, ask before `--judge`):
   ```
   ~/.speccraft/kb-forge/session-kit/evals/kb-audit.sh
   ```
   runs the mechanical checks (anchor rot, provenance, staleness, structural
   lint, derived freshness) for free. Ask the founder whether to re-run with
   `--judge` — it invokes one headless `claude -p` pass, is capped by
   `judge_sample_size` in `kbforge.yaml`, and is the only step in this skill
   that costs real time/tokens. Report the mechanical issue count and the
   report path; if `--judge` ran, report precision and note that
   non-`SUPPORTED` verdicts were appended to `.speccraft/QUEUE.md`.

3. **Tier 3 — behavioral suite** (per release, manual, always ask first —
   this spawns ~2 headless sessions per task and is the most expensive tier):
   ```
   ~/.speccraft/kb-forge/session-kit/evals/behavioral/run.sh [--only TASK-N]
   ```
   Requires `.speccraft/evals/behavioral-tasks.md` to exist (author instances
   from `behavioral/tasks-template.md` if missing — that's a separate,
   explicit ask, not something to improvise). Report the armed-vs-blind
   tripwire totals per task and remind the founder the judgment-call section
   of the report still needs a human read of the transcripts.

4. **Walk queued judge verdicts.** `kb-audit.sh --judge` appends
   `[evals-audit <date>] <verdict>: <claim> [<file>] — <evidence>` lines to
   `.speccraft/QUEUE.md` `## Open`. Filter for that tag and present them one
   at a time, highest-severity verdict first (`CONTRADICTED` before
   `POSSIBLY_STALE`):
   - **Confirm the claim / dismiss the flag** → hand off to
     **speccraft-ratify** (fact ratified path).
   - **The claim is wrong, code is right** → hand off to **speccraft-diverge**
     (files it as a divergence for founder ruling — do not edit the KB
     yourself).
   - **Defer** → leave the item in `## Open`, do not guess.
   This skill never writes `status: ratified`, never edits `ledger/`, and
   never marks a QUEUE item resolved itself — it routes, the founder rules.

5. **Summarize.** One short status line per tier that ran (skip tiers not
   run), plus a count of judge-verdict items still open after step 4. Point
   at report paths (`.speccraft/evals/reports/*.md`,
   `.speccraft/evals/health.md`) rather than restating their contents.

**Input:** $ARGUMENTS
