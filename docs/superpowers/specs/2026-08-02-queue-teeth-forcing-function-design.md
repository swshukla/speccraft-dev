# Queue Teeth — HIGH-Debt Forcing Function + Debt Banner (Phase 1)

**Date:** 2026-08-02 (revised 2026-08-09)
**Type:** Design / spec
**Roadmap:** Phase 1 of `docs/roadmaps/2026-08-01-drift-prevention-roadmap.md` (C+D spine)
**Builds on:** Phase 0 (two-lane queue — `SIGNALS.md` projection + drift-debt header)
**Status:** approved design → ready for writing-plans

---

## 0. Revision note (2026-08-09) — split the anchor

The first implementation gated **`source_commit`** (the pin). The final whole-branch
review found this defeats the feature: `source_commit` is a *mechanical* marker that the
**ship loop advances on every code commit** (`post-commit` → `seed0.py` re-pins → commits
with `KB_SHIPLOOP=1`, which short-circuits `pre-commit` before the gate). So the pin
auto-advances past any HIGH debt, and by ratify time there is usually no `source_commit`
diff to gate. Verified against the code (`seed0.py:56-62`, `post-commit:31,37`,
`pre-commit:6`).

**Root cause:** we conflated *"what has drift.py mechanically processed"* (the pin, owned
by the ship loop) with *"what has the founder reviewed as caught-up"* (a human judgment).
Those are different anchors. This revision splits them and gates the **trust boundary**,
not the mechanical pin. `gate.py`'s debt computation, the `Raised` column, the banner, and
the waiver mechanism from the first pass all carry forward unchanged in substance.

---

## 1. Problem

Phase 0 made drift *visible* but nothing makes it *cost* anything. HIGH-severity defects
sat open for weeks in the case study because the loop has an inbox but no forcing function.
Phase 1 makes advancing the **trust boundary** — the founder's declaration that the KB is
reviewed-and-clean through a given commit — refused while HIGH-severity findings are open
past a ceiling, escapable only via a logged waiver; and it surfaces a red/green KB status
at every SessionStart so the cost of ignored HIGH debt is a KB that can never show
"caught up."

## 2. Where severity lives (grounding)

Severity is tracked in `.speccraft/findings/FINDINGS.md`:
`| ID | Sev | Raised | Finding | Evidence (@pin) | Source | Status |` (the `Raised` column
is added by this phase, §4.2). **Open HIGH finding** ≡ `Sev=High` and
`Status ∈ {proposed, confirmed}`.

## 3. Goals / non-goals

**Goals**
- Refuse advancing the *trust boundary* while open HIGH debt exceeds a count ceiling or any
  open HIGH has aged past a limit — with a logged waiver.
- Make ignoring HIGH debt cost a visible, growing **red KB status** (never "caught up"),
  without blocking day-to-day development.
- Keep the mechanical pin (`source_commit`) and the ship loop working exactly as today.

**Non-goals (later phases)**
- Seam-aware recall / Confusion Protocol (Phase 2).
- Gating Med/Low severity (only HIGH gates; Med/Low remain advisory).
- Hard-blocking ordinary code commits (dev keeps flowing; the cost is the status, not a
  blocked commit).

## 4. Design

### 4.1 Two anchors (`kb/derived/inventory.md`)

| Field | Meaning | Advanced by | Gated? |
|---|---|---|---|
| `source_commit:` | Mechanical pin — the SHA `drift.py` has harvested/projected through. | The ship loop (`seed0.py`) on every code commit. | **No** — mechanical, must stay current or drift breaks. |
| `ratified_through:` | **New.** The SHA the founder has ratified the KB reviewed-and-clean through. | **Only** `ratify` (a `KB_RATIFY=1` commit). | **Yes** — the HIGH-debt gate guards its advance. |

Initialization: at KB init / migration, `ratified_through` is set equal to the current
`source_commit` (baseline: the seed is the starting reviewed point).

**Ship-loop change (the only touch to the mechanical path):** `seed0.py` rewrites derived
frontmatter every commit; it must **preserve the existing `ratified_through` value** (read
it, keep it) while advancing `source_commit`. No gating, no freezing — it simply stops
clobbering the trust boundary. If `ratified_through` is absent (legacy KB), `seed0`
initializes it to the new `source_commit`.

### 4.2 The `Raised` date on findings (enables age)

Age cannot come from git-blame (a status flip edits the row and resets the blame date).
So findings carry an explicit date: add a `Raised` (ISO `YYYY-MM-DD`) column after `Sev`,
stamped when a row is first appended (as `proposed`) and **never** changed on status flips.
Existing rows backfilled once from git history via `migrate_findings_raised.py`
(`git log -S 'BUG-NNN'` → earliest commit date; fallback the pin's commit date; final
fallback today). `diverge`/extraction stamp it; `ratify` preserves it.

### 4.3 The gate — `gate.py`

A stdlib script reading `FINDINGS.md` + `inventory.md` + `kbforge.yaml`. Over open HIGH
findings it computes `open_high_count` and `oldest_open_high_age_days`, and **blocks** when
either trips:
- `open_high_count > high_debt_ceiling`
- `oldest_open_high_age_days > high_debt_max_age_days`

Config (`kbforge.yaml`) defaults **`high_debt_ceiling: 3`**, **`high_debt_max_age_days: 14`**
(0 for zero-tolerance). Modes:
- `--check` → exit 0 clear / 1 blocked (used when advancing `ratified_through`).
- `--banner` → the KB status line (§4.5), reading both anchors + debt.
- `--waive "reason"` → append a waiver authorizing one `ratified_through` advance (§4.4).

The debt computation is unchanged from the first pass; what changed is *what it guards*
(the `ratified_through` advance) and that `--banner` now reflects the two-anchor status.

### 4.4 Enforcement (one check, re-pointed to the trust boundary)

- **Primary — `speccraft-ratify`:** after adjudicating findings, the founder advances
  `ratified_through` to the current `source_commit` ("reviewed clean through here"). Before
  doing so it runs `gate.py --check`; if blocked, fix the HIGH findings or record a waiver.
  This **replaces** the old, now-vestigial "advance `source_commit`" step (the ship loop
  already keeps `source_commit` current).
- **Hard backstop — `session-kit/pre-commit` (`KB_RATIFY` branch):** re-pointed to fire when
  a commit's diff changes **`ratified_through:`** (not `source_commit:`). If the gate blocks
  and no staged `DEBT-WAIVERS.md` line names the new `ratified_through`, refuse the commit.
  Ship-loop `source_commit` changes (under `KB_SHIPLOOP`) are never gated — correct, they're
  mechanical.

### 4.5 KB status + debt banner

`gate.py --banner` emits the KB status, read by `kb-briefing.sh` as the first briefing line:
- 🟢 caught up — `ratified_through == source_commit` AND no open HIGH debt:
  `✓ KB caught up — 0 open HIGH findings`
- 🔴 behind / blocked — otherwise:
  `⛔ KB behind: N commit(s) unreviewed · 3 open HIGH (oldest BUG-005, 18d) — ratify BLOCKED`
  or (unreviewed gap but debt clear): `⚠ KB behind: N commit(s) unreviewed — ratify to catch up`

The cost of ignoring HIGH debt is this line staying red with the unreviewed gap growing
every commit, and the gate refusing to let `ratified_through` catch up.

### 4.6 The logged override

Deferral is allowed but never silent. To advance `ratified_through` past open HIGH debt,
`gate.py --waive "reason"` appends an **append-only** line to
`.speccraft/ledger/DEBT-WAIVERS.md`:
```
- 2026-08-09  ratified_through <old>-><new>  deferred: BUG-003, BUG-004  — reason: "…"
```
naming the `ratified_through` advance it authorizes, the deferred BUG ids, and the reason.
`--waive` **creates `ledger/` if absent and `git add`s the file** so the ratify commit's
pathspec includes it (see §6 fixes I1/I2). The pre-commit backstop authorizes the advance
when a staged waiver names the new `ratified_through`.

## 5. Testing

Bash, `session-kit/evals/test-queue-teeth.sh`, wired into `self-test.sh`:

1. Count block / age block / clear (gate over open HIGH debt) — unchanged compute.
2. Med/Low ignored; `fixed`/`dismissed` excluded.
3. **`ratified_through` gate:** a `KB_RATIFY=1` commit advancing `ratified_through` under debt
   (no waiver) is refused; with a waiver naming the new `ratified_through` it is allowed.
4. **Ship loop is NOT gated:** a `KB_SHIPLOOP=1` commit advancing `source_commit` under HIGH
   debt succeeds (the mechanical pin is never blocked).
5. **`seed0` preserves `ratified_through`:** running `seed0.py` advances `source_commit` but
   leaves `ratified_through` unchanged (and initializes it if absent).
6. **Status banner:** green when `ratified_through==source_commit` and no HIGH debt; red with
   the unreviewed-gap + HIGH-debt otherwise.
7. `Raised` stamp + preserve across a status flip; backfill from git history (unchanged).
8. Override writes a well-formed, **tracked** (`git add`ed) `DEBT-WAIVERS.md` line and unblocks.
9. **Robustness:** `--waive` on a fresh KB (no `ledger/`) does NOT crash (I1); a corrupt
   `FINDINGS.md` fails **closed** (M1).

## 6. Files touched

| File | Change |
|---|---|
| `gate.py` | Read both anchors; `--check`/`--banner`(two-anchor status)/`--waive`(targets `ratified_through`, `makedirs`+`git add`) |
| `migrate_findings_raised.py` | One-time `Raised` backfill (unchanged) |
| `seed0.py` | Preserve existing `ratified_through` when re-pinning `source_commit`; init it if absent |
| `session-kit/pre-commit` | Gate on **`ratified_through`** change (not `source_commit`); honor waiver |
| `session-kit/hooks/kb-briefing.sh` | KB status banner (first line) from `gate.py --banner` |
| `session-kit/skills/speccraft-diverge/SKILL.md` | Stamp `Raised` on append |
| `session-kit/skills/speccraft-ratify/SKILL.md` | Advance `ratified_through` (gated); `--waive` flow; preserve `Raised` |
| KB init (seed0 / init path) | Initialize `ratified_through = source_commit` |
| `FINDINGS.md` schema prose | `Raised` column + fill-rules |
| `kbforge.yaml` template / `SPEC.md` | `high_debt_ceiling`, `high_debt_max_age_days` |
| `session-kit/evals/test-queue-teeth.sh` + `self-test.sh` | The suite above |

**Carried-over fixes from the first pass (final-review findings):**
- **I1 (must):** `--waive` `os.makedirs(ledger, exist_ok=True)` before writing — no crash on fresh KB.
- **I2 (must):** `--waive` `git add`s `DEBT-WAIVERS.md` so the ratify pathspec commit includes it.
- **M1:** a corrupt/unparseable `FINDINGS.md` fails **closed** (treat as blocked), not open.

## 7. Risk / rollback
- Blast radius: speccraft tooling + a new inventory field + the `FINDINGS.md` column. No
  product code. Dev is never blocked (only the trust-boundary advance + status).
- `seed0` change is minimal (preserve one field); if `ratified_through` is dropped, the
  status just reads "never ratified" and the gate has nothing to guard — degrades safe.
- Rollback: revert the code; the new field/column are additive and inert to old tooling.

## 8. Out of scope → next
Phase 2 (seam-aware recall + Confusion Protocol) is the next spec. The `gate.py` verdict,
the two-anchor status, and `DEBT-WAIVERS.md` are reusable substrate for later enforcement.
