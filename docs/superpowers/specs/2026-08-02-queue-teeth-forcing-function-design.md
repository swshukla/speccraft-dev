# Queue Teeth — HIGH-Debt Forcing Function + Debt Banner (Phase 1)

**Date:** 2026-08-02
**Type:** Design / spec
**Roadmap:** Phase 1 of `docs/roadmaps/2026-08-01-drift-prevention-roadmap.md` (C+D spine)
**Builds on:** Phase 0 (two-lane queue — `SIGNALS.md` projection + drift-debt header)
**Status:** approved design → ready for writing-plans

---

## 1. Problem

Phase 0 made drift *visible* (the `SIGNALS.md` header is a live "N open mechanical
signals" meter) and split real divergences into a durable human lane. But nothing yet
makes drift *cost* anything. In the case study, HIGH-severity defects sat open for weeks
(B1 unfixed 2026-07-18 → 2026-08-01) because the loop has an inbox but no forcing
function: you can keep declaring the KB "caught up" (advancing the pin) while serious
bugs rot.

Phase 1 gives the queue teeth: advancing the pin — the act that declares "the KB is
current as of this commit" and resets the drift meter — is **refused while HIGH-severity
findings are open past a ceiling**, escapable only via an explicit, logged waiver. Every
session opens staring at the HIGH-debt and whether it is blocking.

## 2. Where severity lives (grounding)

Severity is tracked in `.speccraft/findings/FINDINGS.md`, a markdown table:

```
| ID | Sev | Finding | Evidence (@pin) | Source | Status |
```

- `Sev ∈ {High, Med, Low}` — High = data loss / security / ledger integrity / paying
  users mis-served.
- `Status ∈ {proposed, confirmed, fixed, dismissed}` — `proposed` appended by extraction
  passes and `speccraft-diverge`; flipped to `confirmed`/`dismissed` by `speccraft-ratify`
  (requires `KB_RATIFY=1`); `fixed` set by the resolving commit.

**Open HIGH finding** ≡ a row with `Sev=High` and `Status ∈ {proposed, confirmed}`.

The pin is `source_commit:` in `kb/derived/inventory.md`, advanced during `ratify`. KB
writes already require `KB_RATIFY=1` via a pre-commit lane guard.

## 3. Goals / non-goals

**Goals**
- Refuse pin advance while open HIGH debt exceeds a ceiling (count) or any open HIGH has
  aged past a limit (neglect) — with a logged override.
- Surface HIGH-debt and its blocking status at every SessionStart.
- Keep the check single-sourced and usable from both the ratify flow and a git hook.

**Non-goals (later phases)**
- Seam-aware recall / Confusion Protocol (Phase 2).
- Any change to *what* findings are detected — only to what open HIGH debt *costs*.
- Gating on Med/Low severity (only HIGH gates; Med/Low remain advisory).

## 4. Design

### 4.1 A `Raised` date on findings (enables age)
Age cannot come from git-blame: flipping a finding's `Status` edits its row and resets
the blame date, so blame yields "last touched", not "raised". Therefore findings carry an
explicit date.

- **Schema change:** add a `Raised` column → `| ID | Sev | Raised | Finding | Evidence
  (@pin) | Source | Status |`. Value is an ISO `YYYY-MM-DD`, stamped when the row is first
  appended (as `proposed`), and **never modified** by later status flips.
- **Writers updated:** `speccraft-diverge` and the extraction passes stamp today's date
  on append; `speccraft-ratify` preserves the existing `Raised` value when flipping status.
- **Backfill (one-time):** a migration stamps `Raised` for existing rows from the first
  commit that introduced the row (`git log -S 'BUG-NNN' --reverse --format=%ad --date=short`
  over `FINDINGS.md`), falling back to the pin commit's date if not found. Applied via a
  small `migrate_findings_raised.py` (mirrors `migrate_split_queue.py`).

### 4.2 The gate — `gate.py`
A stdlib script that reads `FINDINGS.md` + `kbforge.yaml` and computes, over open HIGH
findings:
- `open_high_count`
- `oldest_open_high_age_days` (today − min(`Raised`))

It **blocks** (exit nonzero, prints the offending findings) when **either**:
- `open_high_count > high_debt_ceiling`, or
- `oldest_open_high_age_days > high_debt_max_age_days`

Config in `kbforge.yaml`, with defaults:
```yaml
high_debt_ceiling: 3        # max open HIGH findings before pin advance is blocked (0 = zero-tolerance)
high_debt_max_age_days: 14  # any open HIGH older than this blocks pin advance
```
`gate.py` exposes both a CLI (`--config <cfg>`, exit 0 = clear / 1 = blocked) and a
function returning a structured verdict `{blocked: bool, count: int, oldest: {id, age} | None,
reasons: [...]}` for reuse by the briefing and hook without reparsing.

### 4.3 Enforcement points (one check, two callers)
- **Primary — `speccraft-ratify`:** before it advances `source_commit` in `inventory.md`,
  it runs `gate.py`. If blocked, it refuses the advance and prints the offending HIGH IDs
  and the override instructions. (Ruling on findings — flipping proposed→confirmed/
  dismissed — is *not* blocked; only the pin advance is.)
- **Hard backstop — `kb-guard.sh` (the existing KB pre-commit lane guard):** extended so
  that any commit whose diff changes the `source_commit:` line runs `gate.py` and refuses
  the commit if blocked (unless a waiver for this pin exists — §4.4). This enforces the
  gate at the git layer regardless of which tool or agent moves the pin.

Both call the same `gate.py` — no duplicated policy.

### 4.4 The logged override
Deferral is allowed but never silent. To advance the pin past open HIGH debt:

```
KB_RATIFY=1  speccraft-ratify … --accept-debt "reason"     # (or the equivalent pin-advance path)
```

This appends an **append-only** waiver to `.speccraft/ledger/DEBT-WAIVERS.md`:
```
- 2026-08-02  pin e5a0944→c3c0770  deferred: BUG-003, BUG-004, BUG-005  — reason: "shipping crypto launch; ledger-drop fix tracked in DIV-00X"
```
The pre-commit guard treats the pin advance as authorized when a waiver line naming the
new pin exists in this commit (or the immediately prior one). The waiver records the pin,
the deferred BUG IDs (the open HIGHs at that moment), the reason, and the date — the audit
trail for the deferral.

### 4.5 The debt banner
`kb-briefing.sh` (SessionStart) — already emitting `N open divergences | M drift signals`
— gains a HIGH-debt line rendered from `gate.py`'s verdict, placed **first** in the
briefing:
- blocked: `⛔ 3 open HIGH findings (oldest BUG-005, 18d > 14d) — pin advance BLOCKED`
- within ceiling: `✓ 1 open HIGH finding (BUG-003, 4d) — within ceiling`
- none: `✓ 0 open HIGH findings`

## 5. Testing

Bash, in the `session-kit/evals/` harness (a focused `test-queue-teeth.sh`, wired into
`self-test.sh` like the Phase-0 suite):

1. **Count block** — fixture with `ceiling` open HIGHs + 1 more → `gate.py` exits nonzero,
   names the extras.
2. **Age block** — fixture with one open HIGH `Raised` older than `max_age_days` → blocked,
   names it; count under ceiling.
3. **Clear** — open HIGHs within ceiling and all younger than max-age → `gate.py` exits 0.
4. **Med/Low ignored** — many open Med/Low findings never block.
5. **Status excludes** — `fixed`/`dismissed` HIGHs don't count.
6. **Override** — `--accept-debt "reason"` appends a well-formed `DEBT-WAIVERS.md` line and
   the pin advance / commit then succeeds; the waiver names the correct pin + BUG IDs.
7. **Pre-commit backstop** — a commit changing `source_commit` while blocked (no waiver) is
   refused; with a waiver naming the new pin it is allowed.
8. **`Raised` stamp + preserve** — `diverge` stamps today's date; a status flip
   (proposed→confirmed) leaves `Raised` unchanged.
9. **Backfill** — `migrate_findings_raised.py` stamps a dated `Raised` for a legacy row
   from git history, falls back to the pin date when `-S` finds nothing.
10. **Banner** — `kb-briefing.sh` prints the blocked / within-ceiling / none line matching
    the fixture state.

## 6. Files touched

| File | Change |
|---|---|
| `gate.py` | **Create** — the HIGH-debt check (CLI + verdict function) |
| `migrate_findings_raised.py` | **Create** — one-time `Raised` backfill |
| `session-kit/skills/speccraft-diverge/SKILL.md` | Stamp `Raised` on append |
| `session-kit/skills/speccraft-ratify/SKILL.md` | Run gate before pin advance; preserve `Raised`; `--accept-debt` waiver flow |
| `session-kit/hooks/kb-guard.sh` | Run `gate.py` on `source_commit` change; honor waiver |
| `session-kit/hooks/kb-briefing.sh` | HIGH-debt banner line (first) |
| `FINDINGS.md` template / header prose | Add `Raised` column to schema + fill-rules |
| `kbforge.yaml` template | `high_debt_ceiling`, `high_debt_max_age_days` defaults |
| `session-kit/evals/test-queue-teeth.sh` | **Create** — the suite above |
| `session-kit/evals/self-test.sh` | Wire in the new suite |

## 7. Risk / rollback
- Blast radius is speccraft tooling + the `FINDINGS.md` schema (a new column, append-only,
  backward-readable — old parsers that split on `|` see one extra column). No product code.
- The gate is escapable by design (logged waiver), so it cannot hard-wedge a founder who
  needs to move.
- Rollback: revert the code; the `Raised` column is additive and harmless if unread; any
  installed KB reverts by dropping the column (or leaving it — it's inert to old tooling).

## 8. Out of scope → next
Phase 2 (seam-aware recall + Confusion Protocol) is the D-half of the spine and the next
spec. The `gate.py` verdict + `DEBT-WAIVERS.md` established here are reusable substrate for
later enforcement (e.g. executable invariants, Phase 4).
