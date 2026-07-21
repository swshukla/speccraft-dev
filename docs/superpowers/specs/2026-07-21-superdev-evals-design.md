# superdev Evals — Design

**Date:** 2026-07-21
**Status:** Approved in design review (brainstorming session)
**Scope:** Measurement layer for the built kb-forge / superdev system (session-kit as
installed in repos like stocktickerapp) — NOT the aspirational full-SDLC eval doctrine
in `docs/agentic-sdlc/07-evals-layer.md`, which remains deferred until multi-repo /
customer scale.

## Problem

The superdev KB system (trust-graded KB, five skills, session hooks, ratify loop) emits
zero measurement. We cannot answer "is this system working?" — which decomposes into
three distinct claims:

1. **Is the loop even used?** (do sessions run recall, do commits ratify)
2. **Is the KB true?** (are claims correct and fresh against the code)
3. **Do agents behave better with it?** (fewer invariant violations, more reuse)

An unmeasured trust system undermines its own value proposition: the KB's pitch is
ground-truth credibility, and credibility requires evidence.

## Decision summary (approved)

- **Layered pyramid, all three claims**, sequenced cheapest-first.
- **Harness = Approach A**: deterministic scripts in the kit, wired to existing hooks;
  a single capped LLM-judge pass for semantic checks; behavioral suite run manually.
  A thin `superdev-eval` skill is added LATER as a front-end only (Approach B); the
  external pytest/CI harness (Approach C) is explicitly deferred.
- **Core rule, inherited from the KB itself:** an eval you can't trust is worse than
  none. Every number that gates or scores is deterministic. The LLM judge only ever
  *flags* for human review — it never autonomously marks a claim false and never edits
  the KB. Same pending-ratification discipline the KB uses.

## Architecture

```
        Tier 3: Behavioral lift        "does the KB make agents better?"
                (per release, manual)   5–8 paired tasks, KB-armed vs KB-blind
        ─────────────────────────────
        Tier 2: KB truth audit         "are the claims still true?"
                (weekly / on demand)    deterministic checks + 1 LLM-judge pass
        ─────────────────────────────
        Tier 1: Compliance telemetry   "is the loop even being used?"
                (always on, free)       JSONL lines from existing hooks
```

### File layout

```
kb-forge/session-kit/evals/            # canonical, distributed by install.sh
  telemetry-report.sh                  # Tier 1: JSONL → rates + Health block + GC
  kb-audit.sh                          # Tier 2: mechanical checks + judge dispatch
  judge-rubric.md                      # Tier 2: fixed rubric for the claude -p judge
  behavioral/tasks-template.md         # Tier 3: task format + grading rubric
  behavioral/run.sh                    # Tier 3: paired worktree runs
  self-test.sh                         # seeded-defect self-test of the machinery
  fixtures/                            # miniature KB + telemetry + diffs w/ seeded defects

<repo>/superdev/evals/                 # per-repo
  telemetry.jsonl                      # appended by hooks — GITIGNORED
  behavioral-tasks.md                  # repo-specific task instances — tracked
  reports/YYYY-MM-DD-audit.md          # Tier 2 output — tracked
  reports/YYYY-MM-DD-behavioral.md     # Tier 3 output — tracked
```

Results surface where people already look: a **Health** block in `KB-STATUS.md`
(Tier 1 rates, last audit precision, last behavioral delta). Threshold breaches write
entries to `superdev/findings/`. Thresholds and knobs live in `kbforge.yaml` under a
new `evals:` block so per-repo tuning never means editing scripts.

## Tier 1 — Compliance telemetry (always on, free)

A shared `append_telemetry` helper; each of the four existing hooks gains one call.
No new hooks. One JSONL record per event:

```json
{"ts":"2026-07-20T10:14:02Z","session":"fff71ebe","event":"recall_ran","detail":"before_first_edit"}
```

| Hook | Event(s) | Tells us |
|---|---|---|
| `kb-briefing.sh` (session start) | `session_start` | denominator for all rates |
| `kb-recall-post.sh` | `recall_ran` / `recall_skipped` | KB consulted before edits? |
| `kb-guard.sh` | `guard_block`, `ratify_used` | normative writes go through ratification? |
| `kb-status.sh` | `divergence_filed`, `queue_delta` | loop closing or just accumulating? |

`telemetry-report.sh` computes four rates over a window (default 14 days,
`evals.report_window_days`):

- **Recall rate** — sessions with recall before first edit / sessions with edits
- **Ratify rate** — normative commits via `KB_RATIFY=1` / all normative commits
- **Divergence closure** — ledger entries resolved / filed
- **Queue drain** — QUEUE.md items closed / opened

**Interpretation contract:** Tier 1 gates nothing automatically. A low rate is a
*finding* — recall rate below `evals.min_recall_rate` (default 0.70) over the window
writes a `findings/` entry stating that the loop is not engaged and Tier 2/3 results
are unattributable.

### Garbage collection (bounded file, no cron)

Raw lines are only needed for the reporting window; history persists in rendered form
(rates committed in `KB-STATUS.md`, breaches in `findings/`). Two dumb layers:

1. **Prune on report:** every `telemetry-report.sh` run atomically rewrites the file
   keeping only lines within `evals.telemetry_retention_days` (default 90) — awk to
   `telemetry.jsonl.tmp`, then `mv`, so a concurrent hook append cannot corrupt it.
2. **Size backstop on append:** `append_telemetry` does a cheap `stat`; if the file
   exceeds 5 MB it truncates to the newest 10k lines before appending. Bounds the file
   even if reports never run.

**Error handling:** all telemetry writes are fire-and-forget (`|| true`) — eval failure
must never break a session hook. The report skips malformed JSONL lines but counts
them as `unparseable` so corruption is visible, not silent.

## Tier 2 — KB truth audit (`kb-audit.sh`, weekly / on demand)

Every check is either **mechanical** (deterministic, always runs) or **semantic**
(LLM judge, capped, optional).

### Mechanical checks (bash/git only)

- **Anchor rot** — every `anchors:` frontmatter entry must resolve to a real
  path/module. Dead anchor = broken claim regardless of content.
- **Provenance validity** — `elicited_by` / `documented_by: doc:<path>@<commit>`
  targets must exist in git history.
- **Staleness index** — commits touching a claim's anchored paths since the claim was
  last ratified. High churn ≠ wrong; it ranks who gets judged first.
- **Structural lint** — legal `status:` values, unique INV-ids, provenance frontmatter
  present on every normative file.
- **Derived freshness** — commit distance between each `kb/derived/*` file's
  generation commit and HEAD.

### Semantic check (one headless `claude -p` pass per audit)

- **Never judges `elicited` claims** — by the system's own rules, code cannot
  invalidate founder intent; judging intent against code would be incoherent. (Their
  anchors still get mechanical checks.)
- **Samples `observed` / `documented` / derived claims**, prioritized by staleness
  index, capped at `evals.judge_sample_size` (default 20) per run.
- **Invariant compliance pass:** for each `INV-N`, "does the anchored code visibly
  comply or contradict?" — invariants are where silent drift hurts most.
- **Verdicts:** `SUPPORTED` / `POSSIBLY_STALE` / `CONTRADICTED`, each requiring cited
  `file:line` evidence per `judge-rubric.md`.
- **Judge never edits the KB:** `CONTRADICTED` → divergence candidate queued for
  `superdev-diverge`; `POSSIBLY_STALE` → `QUEUE.md` item. A human (or the ratify flow)
  closes them.

### Output & error handling

`superdev/evals/reports/YYYY-MM-DD-audit.md` (tracked): precision (% of sampled claims
SUPPORTED), anchor-rot count, staleness top-10, judge verdicts with evidence. Headline
numbers go to the Health block. Precision below `evals.min_precision` (default 0.80)
writes a `findings/` entry.

Judge unavailable (no `claude` CLI, API failure) → audit completes mechanically, the
semantic section is marked `SKIPPED`, exit 0. The audit never blocks a commit or a
session.

## Tier 3 — Behavioral suite (per release, manual)

**Question:** does the KB actually change agent behavior? **Method:** paired runs —
same task, same model, one session KB-armed, one KB-blind.

### Task design

Tasks are repo-specific (derived from *this repo's* invariants). The kit ships the
format and grading rubric (`behavioral/tasks-template.md`); each repo keeps 5–8
instances in `superdev/evals/behavioral-tasks.md`. Each task is a *temptation*:

- **One per high-stakes `INV-N`:** a plausible feature request whose easiest
  implementation violates the invariant (e.g., INV says the calls ledger is
  append-only → task asks for an "edit call record" feature).
- **One–two reuse traps:** a task needing data/capability already recorded in
  `05-data-sources.md` / `06-integrations.md` — does the blind agent reinvent it?
- **One divergence trap:** a request contradicting stated product intent — does the
  armed agent push back / file divergence, or silently comply?

Each task declares its **tripwires** up front: observable, mostly grep-able failures
in the resulting diff or transcript ("introduces UPDATE on `calls` table", "adds a
second yfinance client", "no recall invocation in transcript").

### Run protocol (`behavioral/run.sh`)

For each task, two throwaway git worktrees:

- **Armed** — repo exactly as installed (KB, skills, hooks present).
- **Blind** — worktree with `superdev/`, the `superdev-*` skills, and the KB hooks
  stripped.

Same `claude -p` prompt in each. Capture diff + transcript; discard worktrees after
grading. Nothing ever touches a real branch. Full run ≈ 12–16 headless sessions —
hence per-release and manual, not CI.

### Grading

Tripwires checked deterministically by the script; a human grading sheet covers
judgment calls (did it push back appropriately?). Score per run = tripwires hit +
reuse misses. Headline metric = **armed − blind delta**, reported in
`reports/YYYY-MM-DD-behavioral.md` and the Health block.

## `superdev-eval` skill (Phase 4, front-end only)

A thin sixth skill in the kit: runs the scripts, narrates results, walks the user
through queued judge verdicts (ratify / diverge / dismiss each). Contains **no
measurement logic of its own** — the scripts are the substrate; the skill is UX.
Distributed exactly like the other five skills (`.claude/skills/`, `.agents/skills/`,
`.opencode/commands/`, `~/.codex/prompts/`).

## Testing the eval machinery (`self-test.sh`)

Who evals the evals: deterministic **seeded-defect fixtures** in the kit —

- a miniature KB containing a dead anchor, an illegal `status:`, a duplicate INV-id,
  and a claim whose anchor churned;
- a telemetry fixture containing malformed lines;
- synthetic diffs that should trip each behavioral tripwire.

`self-test.sh` asserts every seeded defect is caught and every clean fixture passes.
Runs in seconds. This is the honesty check: if the audit can't catch a defect we
planted, we don't trust it to catch real ones.

## Sequencing (four independently shippable phases)

1. **Tier 1:** `append_telemetry` helper, one-line hook additions, `telemetry-report.sh`
   with GC, Health block, `.gitignore` entry for `telemetry.jsonl`, `evals:` defaults
   in `kbforge.yaml`, fixtures + self-test coverage for Tier 1.
2. **Tier 2 mechanical**, then **Tier 2 semantic** (`judge-rubric.md` + capped judge
   pass), each with self-test fixtures.
3. **Tier 3:** task template in the kit, author stocktickerapp's task instances from
   its real INVs, `run.sh` + grading sheet, first paired run.
4. **`superdev-eval` skill** front-end.

**Distribution:** `install.sh` gains an `evals/` copy step alongside the existing
skills loop; updated hooks propagate the same way.

## Configuration (new `evals:` block in `kbforge.yaml`)

```yaml
evals:
  report_window_days: 14
  telemetry_retention_days: 90
  min_recall_rate: 0.70
  min_precision: 0.80
  judge_sample_size: 20
```

## Out of scope

- CI gating, golden sets, seeded-defect extraction suites at scale (the
  `07-evals-layer.md` doctrine) — deferred until multi-repo or customer-driven rigor
  is needed.
- Any autonomous KB mutation by evals — evals observe, flag, and report; humans and
  the existing ratify/diverge flows change the KB.
- Cross-harness session telemetry: OpenCode/Codex sessions don't run Claude Code
  session hooks, so session-side events (`session_start`, `recall_ran`) cover Claude
  Code only — a known, documented blind spot. Commit-side events (`ratify_used`,
  `guard_block`) come from git hooks and are harness-independent.
