# Trust Decay — Auto-Demotion on Evidence, Queue Hygiene by Age

**Date:** 2026-07-25
**Status:** Draft for review
**Addresses:** Critique #1 (founder bottleneck) — the "no automatic
mitigation" gap that specs 1–5 all defer to this spec.

## Problem

The ratchet stops if the founder stops ratifying, and the system's only
response today is visibility (queue counts in the briefing, warnings from
the stale guard). Nothing bounds the damage:

- Facts whose citations have provably gone stale keep their trust grade —
  drift.py *declares* the demotion policy ("stale citation demotes the
  claim to `challenged`", drift.py:11) but only prints it. The KB keeps
  vouching at yesterday's grade for facts it has evidence against.
- QUEUE.md grows without bound — and rev 2 of specs 3–5 made this worse by
  design: detection capacity now scales (anchor-scope items, dep-diff
  items, drift items every commit) while adjudication capacity (the
  founder) is fixed.

The result the design review predicted: an unratified, unbounded pile that
degrades trust in the *system*, not just the facts.

## Principle — the amendment to the discipline

The system's discipline is "mechanical checks flag but never edit." This
spec carves out one precise exception, justified by asymmetric error cost:

> **Trust rises only through the founder. Trust may fall mechanically, on
> evidence, with a ledger entry.**

- A wrongly-demoted fact costs one re-verification (founder re-ratifies;
  the reversal is cheap and explicit).
- A wrongly-trusted fact costs correctness — agents build on it.

Mechanical processes therefore may: **lower** a fact's trust status, and
**move** queue items to an archive. They may never: create or modify fact
*content*, raise any status, or delete anything. Every automatic action
writes a ledger line. Self-ratification remains impossible; this adds
self-*challenging* only.

## Mechanism A — Evidence-based demotion (execute drift's own policy)

New flag: `drift.py --demote`. Run by the post-commit ship loop after the
drift report, under `KB_SHIPLOOP=1` (the sanctioned-writer context; the
lane guard already recognizes it). Policy by severity and lane:

| Finding (subtractive) | Inferred fact | Ratified/normative fact |
|---|---|---|
| `cited-file-DELETED` | auto-demote → `challenged` | auto-demote → `challenged` |
| `cited-lines-changed` | auto-demote → `challenged` | queue only (founder decides) |
| `file-changed-elsewhere` | report only | report only |

Rationale for the one aggressive cell: a *ratified* fact citing a file that
no longer exists is definitively stale — preserving its grade is the KB
lying about what it can vouch for. Ratified facts whose cited lines merely
changed stay founder-adjudicated: the change may be cosmetic, and
founder-granted trust should not be revoked on ambiguous evidence.

Demotion writes exactly one frontmatter field (`status: challenged`) plus a
`status_note` line citing the evidence. Content untouched.

### Ledger entry (every demotion)

```
2026-07-25  AUTO-DEMOTE  kb/inferred/06-integrations.md  observed → challenged
  evidence: cites backend/feeds/rss.py:40-62; file deleted in a1b2c3d..d4e5f6a
  reverse-by: speccraft-ratify (founder)
```

The ledger is the audit trail that makes mechanical demotion safe: nothing
is silent, everything is reversible by exactly one human action.

## Mechanism B — Queue hygiene (archive by age, never by importance)

With Mechanism A in place, the durable state of a stale fact lives in its
`status` field — drift-generated queue items become *notifications*, not
state. That makes archiving them safe:

- **Mechanical items** (drift staleness, anchor-scope, dep-diff sections)
  older than `queue_archive_days` (default 30, in `kbforge.yaml`) are
  collapsed into `QUEUE-ARCHIVE.md` with a one-line digest left in
  QUEUE.md: `> archived 2026-06-25: 14 mechanical items → QUEUE-ARCHIVE.md`.
  Nothing is deleted; if the underlying staleness still matters, the fact's
  `challenged` status still says so, and the next drift run re-detects
  anything still live.
- **Adjudication items** (numbered session divergences, speccraft-diverge
  output) are **never archived**. They are the high-value human questions
  the queue exists for. They age visibly instead (Mechanism C).

This split prevents archiving from becoming neglect-laundering: the items
that require a human answer cannot silently expire; the items that are
re-derivable by machine can.

## Mechanism C — Aging as visibility (and why age-based demotion was rejected)

`kb-briefing.sh` gains one line:

```
Trust: 12 ratified | 3 pending (oldest 41d) | 7 challenged (5 auto)
```

`telemetry-report.sh` / health block gain the demotion and archive counts
per window, and the oldest-pending-age trend.

**Deliberately rejected: demoting facts on age alone.** A pending fact
whose anchors haven't changed in 90 days is probably still true — the code
didn't move. Demoting it manufactures founder work from calendar time and
teaches the founder that demotions are noise. Evidence-based demotion keeps
the signal honest: every automatic demotion can point at a diff. Age is
surfaced relentlessly (briefing, stale-guard warning tier, reports) but
never acted on mechanically. If real usage shows aged-pending facts going
stale *without* anchor drift, revisit — that evidence would itself be the
justification.

## Where it runs

Post-commit ship loop, in order: drift report → `drift.py --demote`
(Mechanism A) → queue archiver (Mechanism B, small script or drift.py
step) → re-pin. All under `KB_SHIPLOOP=1`. No new daemons, no cron
required; decay happens exactly as often as the code moves — which is the
only time evidence can appear.

## Interactions with the other rev-2 specs

- **Stale commit guard (spec 1):** its warning tier counts *open* items
  only; the briefing shows the archived count separately. Its future
  escalation knob (oldest-item age) reads adjudication items — which never
  archive — so archiving cannot mask the neglect signal the knob needs.
- **Recall gate (spec 2):** demoted facts drop out of the normative gate
  tier naturally (a `challenged` fact is not ratified truth), so the gate
  never denies edits on evidence the system itself has withdrawn.
- **Anchor scope drift (spec 3) / dep-diff (spec 4):** their queue items
  are mechanical-tier — archivable. Their normative-anchored findings also
  become T2 judge targets, whose verdicts feed founder adjudication, not
  auto-demotion (the judge flags, never edits — that discipline is
  unchanged; only *deterministic* evidence demotes).
- **Recall telemetry (spec 5):** `auto_demote` and `queue_archive` events
  ride the same JSONL schema.

## Telemetry

- `auto_demote` — fact path, from→to, evidence kind (deleted / lines-changed)
- `queue_archive` — item count archived
- Report: demotions per 30d window; a *rising* trend with a flat ratify
  count is the quantitative form of critique #1 — the system now measures
  its own bottleneck instead of just suffering it.

## Out of scope

- **Ratification ergonomics** (batch ratify, one-command adjudication
  sessions) — the other half of the bottleneck: this spec bounds the damage
  of not ratifying; making ratifying cheap is a separate spec.
- **Auto-promotion of any kind** — never. Trust rises only through the
  founder.
- **Age-based demotion** — rejected above, with the condition for
  revisiting stated.
- **LLM-judge-triggered demotion** — the T2 judge flags and targets; only
  deterministic evidence (a diff) demotes. Keeping the judge advisory
  preserves the system's core discipline.
