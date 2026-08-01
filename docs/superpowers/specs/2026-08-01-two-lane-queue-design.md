# Two-Lane Convergent Queue — Design (Phase 0)

**Date:** 2026-08-01
**Type:** Design / spec
**Roadmap:** Phase 0 of `docs/roadmaps/2026-08-01-drift-prevention-roadmap.md` (C+D spine)
**Status:** approved design → ready for writing-plans

---

## 1. Problem

`.speccraft/QUEUE.md` conflates two structurally different things in one file:

- **Human divergences** — numbered `## Open` items authored by the `speccraft-diverge`
  skill; judgment calls that conflict with a ratified fact/invariant.
- **Mechanical drift** — `## Staleness — drift run` / `## Dependency drift` sections
  emitted by `drift.py` / `dep-diff.py`; pure functions of `pin→head`.

In the SignalCue case study this file reached ~600 lines. Three defects compound:

1. **Self-feeding citation loop (root cause of ~90% of the volume).** `drift.py`'s KB
   walk excludes only `.git` and `derived` (`drift.py:265-266`); it does **not** exclude
   `QUEUE.md`. Once QUEUE.md contains a citation like `` `celery_app.py:90` `` from a
   prior staleness line, the *next* drift run scans QUEUE.md, treats that text as a KB
   citation, and emits a fresh `spot-check QUEUE.md — cites celery_app.py:90` line —
   which the following run scans again. The live file cites `QUEUE.md` as the source on
   lines ~200–505.
2. **No wall between lanes.** Mechanical noise buries human divergences; numbering
   collides (`kb-briefing.sh` and `kb-audit.sh` both count `^[0-9]+\.` file-wide).
3. **Append-only, no dedup, no per-item decay.** `drift.py:341-358` and
   `dep-diff.py:167-175` open in `"a"` mode and never check for existing entries. The
   existing `decay.py` archives whole sections only by 30-day age.

Net effect: genuine HIGH divergences (Alembic `drop_table` on the immutable ledger;
lapsed-tier paid pushes) are invisible under mechanical chatter, and caught drift never
converges (case-study item B1 sat unfixed 2026-07-18 → 2026-08-01).

## 2. Goals / non-goals

**Goals**
- Make the real divergences visible and durable, structurally isolated from mechanical
  output.
- Kill the self-citation loop at its source.
- Make mechanical drift self-deduplicating and self-decaying with zero bookkeeping.
- Produce a single "drift debt since last pin" number that Phase 1's forcing function
  can gate on.

**Non-goals (later phases)**
- The forcing function / ratify debt-ceiling (Phase 1).
- Seam-aware recall, Confusion Protocol (Phase 2).
- Any change to *what* drift.py detects — only how its output is stored.

## 3. Design

### 3.1 Keystone fix — stop the self-scan
Add `QUEUE.md`, `SIGNALS.md`, `QUEUE-ARCHIVE.md` to `drift.py`'s walk-exclusion set
(alongside `.git`, `derived`). `drift.py` must never scan its own output. This single
change ends the self-feeding loop regardless of everything else below.

### 3.2 Two files, strict ownership

| File | Lane | Written by | Contents |
|---|---|---|---|
| `QUEUE.md` | **Human** | `speccraft-diverge`, `speccraft-ratify`, `kb-audit.sh` | `## Open` (numbered divergences) + `## Ruled` (resolutions). No mechanical tool writes here. |
| `SIGNALS.md` | **Mechanical** | `drift.py`, `dep-diff.py`, `deps0.py` | Projection of current drift/dep state. Rewritten each run. |
| `QUEUE-ARCHIVE.md` | **History** | `drift.py` (resolved), `decay.py` | One-line records of findings that dropped out or aged. |

### 3.3 SIGNALS.md as a projection (not an append log)

`drift.py` and `dep-diff.py` switch from append → **read-recompute-rewrite**. Because
their findings are pure functions of `(pin, head, KB)`, the full current finding set is
deterministic and recomputable every run, so a full rewrite is always correct:

- **Dedup is free** — the finding set is a set; repeats cannot stack.
- **Decay is free** — a fixed finding is simply absent from the next projection and
  disappears from the file. No hashes, counters, or TTLs.

**Three fenced regions** keep the three writers from clobbering each other; each writer
idempotently replaces only its own block:

```
<!-- signals:drift -->      … drift.py owns; full projection of pin→head KB drift
<!-- signals:deps -->       … dep-diff.py owns; projection of manifest version drift
<!-- signals:advisories --> … deps0.py owns; persisted, baseline-dedup'd CVE set
```

Advisories are the one genuinely stateful stream (CVEs arrive over time, not from a
code diff) and are already baseline-dedup'd (`deps0.py:263-272`); they remain an
additive region, not a projection.

**File shape:**
```
# SIGNALS — mechanical drift (pin e5a0944 → head <sha>)
# 4 open signals · drift debt since last ratify

<!-- signals:drift -->
## re-verify (cited lines changed)
- [ ] kb/inferred/07-assumptions.md cites generate_cue_watchlist.py:44
## spot-check (file changed elsewhere)
- [ ] kb/inferred/08-consistency.md cites admin.py:705
## additive drift
- [ ] assumption: 8 new site(s) → re-run assume0.py
## anchor scope drift
- [ ] …
<!-- /signals:drift -->

<!-- signals:deps --> … <!-- /signals:deps -->
<!-- signals:advisories --> … <!-- /signals:advisories -->
```

The header open-count is the drift-debt meter consumed later by Phase 1.

### 3.4 Resolved → archive
Before rewriting its region, `drift.py` diffs the previous finding-set against the new
one. Findings present before but absent now get a one-line append to
`QUEUE-ARCHIVE.md`:
```
- resolved 2026-08-01: kb/inferred/07-assumptions.md cites generate_cue_watchlist.py:44 [cited-lines-changed]
```
Auditability without cluttering the live file. Same file `decay.py` already manages.

### 3.5 Consumer updates (all identified in the machinery map)

- **`kb-briefing.sh`** — replace the file-wide `grep -cE '^[0-9]+\.' QUEUE.md` with two
  scoped counts: `## Open` items in `QUEUE.md` and open `- [ ]` in `SIGNALS.md`.
  Briefing line: `"N open divergences | M drift signals"`.
- **`kb-audit.sh`** — eval-audit findings are judgment calls → route to `QUEUE.md
  ## Open`, with numbering scoped to the `## Open` section (not `grep -c` over the whole
  file). It no longer appends past arbitrary end-of-file.
- **`decay.py`** — the projection model subsumes section-age archiving for drift/dep-diff
  (they self-clean). Repoint `decay.py` off `QUEUE.md`; retain it to bound
  `QUEUE-ARCHIVE.md` growth and for advisory hygiene. Its `MECH_HEADER` regex, which is
  hard-coupled to the old `## Staleness — drift run` header, is retired.
- **`speccraft-diverge` / `speccraft-ratify` SKILL.md** — repoint prose to the split:
  diverge writes `QUEUE.md ## Open`; ratify reads `## Open`, moves resolved items to
  `## Ruled`, and — when it advances the `source_commit` pin — re-runs the existing
  `drift.py --queue` (no new mechanism) so `SIGNALS.md` re-projects against the new pin.

### 3.6 Migration (clean rebuild)
One-time, on the stocktickerapp instance and any other installed KB:
1. Preserve `## Open` items 1–16 and the `## Ruled` section **verbatim** into the new
   `QUEUE.md` (they are real judgment calls).
2. Discard every `## Staleness — drift run` and `## Dependency drift` section (self-loop
   garbage; regenerable).
3. Run one clean `drift.py` against the current pin to generate a fresh `SIGNALS.md`.
The ~600 lines collapse to the genuine divergences plus a handful of live signals.

## 4. Testing

`self-test.sh` is updated; the load-bearing assertions:

1. **Idempotency (the key property).** Two consecutive `drift.py` runs on the same head
   produce a **byte-identical `SIGNALS.md`**. Proves both the projection model and the
   death of the self-scan loop in one assertion.
2. **Lane isolation.** After a drift run, `QUEUE.md` contains **zero** `- [ ]`
   mechanical lines and no `cites` text; all mechanical output is in `SIGNALS.md`.
3. **No self-citation.** `SIGNALS.md` never contains a line citing `QUEUE.md`,
   `SIGNALS.md`, or `QUEUE-ARCHIVE.md`.
4. **Resolution.** A finding present in run N and fixed before run N+1 disappears from
   `SIGNALS.md` and appears once in `QUEUE-ARCHIVE.md`.
5. **Region ownership.** A `dep-diff.py` run does not alter the `signals:drift` region,
   and vice versa.
6. **Briefing counts.** `kb-briefing.sh` reports divergence and signal counts separately
   and does not double-count across the two files.

Existing `self-test.sh` assertions coupled to the old single-file format (the
`## Staleness — drift run (a→b)` synthetic seed, `decay` round-trip, exact-substring
greps) are rewritten to the new shape.

## 5. Risk / rollback
- **Blast radius** is contained to speccraft tooling (`drift.py`, `dep-diff.py`,
  `deps0.py`, `decay.py`, three shell hooks, two SKILL.md, `self-test.sh`); no product
  code. Installed KBs change only via the one-time migration.
- **Rollback:** the change is additive to the file layout; reverting the code writers to
  append-mode plus restoring the old `QUEUE.md` from git history fully reverses it. The
  keystone exclusion (3.1) is independently safe and worth keeping even on rollback.

## 6. Out of scope → next
Phase 1 (forcing function on the drift-debt count + briefing-led debt banner) builds
directly on §3.3's header count and the now-clean `## Open` lane. That is the next spec.
