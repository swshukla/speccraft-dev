# Executable Checks (Phase 4)

**Date:** 2026-08-11
**Type:** Design / spec
**Roadmap:** Phase 4 of `docs/roadmaps/2026-08-01-drift-prevention-roadmap.md` (the **A** — durable enforcement)
**Builds on:** Phase 2's `avoid_pattern` (a grep regex on conventions, "captured for later enforcement, not read today").
**Status:** approved design → ready for writing-plans

---

## 1. Problem

Invariants and seams are still *advice*. Phase 2 surfaces "use `effective_tier()`, avoid raw
`User.tier`" and even lets a convention carry an `avoid_pattern` regex — but nothing runs it.
The audit's scariest bugs were mechanically checkable and slipped through anyway (a migration
that could `drop_table` the immutable ledger; three worker tasks gating on raw `User.tier`).
Phase 4 turns mechanically-checkable invariants into **deterministic checks** a product can run
— reporting by default, failing the build when it opts in.

## 2. What exists (grounding)

- **`avoid_pattern`** — documented on `kb/normative/conventions/CONV-NN-<slug>.md` as a grep
  regex, alongside `seam`/`avoid`/`anchors`/`status`; **nothing reads it** (`speccraft-ratify`
  SKILL.md:36 says "not read today"; grep confirms no consumer).
- **`speccraft-prove`** — an LLM-judge (`prove.sh` shells to `claude -p`), pull-based,
  never wired to CI. Phase 4's checks are **deterministic and complementary**, not an extension
  of prove.
- **`gate.py`** — the only deterministic build-failing check, but scoped to KB governance
  (HIGH-debt), not product code. **No `speccraft-check` entrypoint exists; no CI runs checks.**
- Shared parser: `recall.py`'s `frontmatter()` (reused via `from recall import frontmatter`,
  as `drift.py` does); config via `from drift import load_config`.
- The two "steal-now" checks are inherently product-specific — instances a product KB defines,
  not shipped speccraft code.

## 3. Goals / non-goals

**Goals**
- A single deterministic entrypoint (`speccraft-check`) that runs all product checks and
  reports violations with `file:line` + the fix.
- **Two modes: lenient (default, report-only, exit 0) and strict (opt-in, exit nonzero).**
  Strict is granular: global, per-run, or per-check.
- Two check sources: convention **grep-bans** (`avoid_pattern`) and product **custom scripts**.

**Non-goals**
- Auto-wiring checks into `pre-commit` (deliberately un-intrusive — checks are a command the
  product runs where it wants).
- Diff/changed-files scoping (the lenient/strict axis handles "don't wedge a drifted repo,"
  not diff logic).
- Structural clone detection — that's Phase 5 (`dup0` fails on a new clone of a seam).
- Shipping product-specific checks; speccraft ships the engine + one *example* custom check.

## 4. Design

### 4.1 The engine — `check.py`
Stdlib script, invoked `python3 <forge>/check.py --config <kbroot>/kbforge.yaml [--strict]`.
`kbroot = dirname(config)`, `repo = expanduser(cfg["repo"])`. It collects violations from two
sources, prints a report, and exits per mode.

### 4.2 Source A — convention grep-bans
For each `kb/normative/conventions/CONV-NN-*.md` whose frontmatter has `avoid_pattern`
(a regex) and `anchors` (repo-relative path prefixes):
- Walk the product `repo` under each anchor prefix; for each source file, scan lines for
  `avoid_pattern` (Python `re`).
- Each match → a violation: `{check: CONV-NN, file:line, matched text, avoid: <desc>, seam: <fix>}`.
- The `seam:` field (Phase 2) is rendered as the suggested fix. The pattern is authored to match
  only the anti-pattern (not the canonical seam) — the convention author's responsibility.
- A convention with no `avoid_pattern` is skipped (it's a coaching-only seam).

### 4.3 Source B — custom check scripts
A product drops executables in `kb/normative/checks/CHK-NN-<slug>.sh` (any executable file).
Each: runs with `repo` as `cwd` (and `$SPECCRAFT_REPO` set), **exits 0 = pass / nonzero =
violation**, and prints its findings to stdout. An optional header comment ties it to an
invariant and sets strictness:
```sh
#!/usr/bin/env bash
# check-for: INV-1 (immutable ledger)
# strict: true
# Fail if any model is absent from Alembic target_metadata (would drop_table the ledger).
```
`check.py` discovers all executables under `checks/`, runs each, and turns a nonzero exit into
a violation carrying the script's stdout + its `check-for`/`strict` header.

### 4.4 The two modes
- **Lenient (default):** collect and print ALL violations (grouped by check, with file:line and
  fix), then exit **0**. Non-blocking — informative.
- **Strict:** exit **nonzero** if any *strict-effective* violation exists.

A violation is **strict-effective** iff any of: global `check_mode: strict` in `kbforge.yaml`
(default `lenient`); the `--strict` CLI flag (what CI passes); or the individual check's
`strict: true` (convention frontmatter, or a script's `# strict: true` header). So a single
critical invariant can hard-fail while everything else stays advisory. The report always marks
each violation `[strict]` or `[lenient]`; exit is nonzero iff ≥1 `[strict]` violation.

### 4.5 Wiring (deliberately un-intrusive)
- `speccraft-check` is standalone — **not** registered in `pre-commit`.
- Docs ship a CI snippet: a GitHub-Actions step (or make target) running
  `python3 <forge>/check.py --config .speccraft/kbforge.yaml --strict`. The product opts in.
- Optional: `kb-briefing.sh` shows a lenient count line (`✎ N check violations (lenient)`) when
  any exist, for visibility — non-blocking.

### 4.6 The two steal-now checks as instances
- **raw-tier ban** → a `CONV-NN` with `avoid_pattern` (e.g. `\bUser\.tier\b` in worker tasks,
  scoped to the worker anchors) + `seam: effective_tier()`. Works through Source A, no new code.
- **Alembic-metadata guard** → a `checks/CHK-01-alembic-metadata.sh` (Source B) asserting every
  model is in `target_metadata`. Phase 4 ships this as a **documented example/fixture** of the
  mechanism; the real one lives in the product KB.

## 5. Testing

Bash, `session-kit/evals/test-check.sh`, wired into `self-test.sh`:
1. **Grep-ban finds a violation** — a CONV with `avoid_pattern` + an anchored fixture file
   containing the pattern → reported with file:line and the seam.
2. **Clean passes** — same CONV, no matching code → no violation, exit 0.
3. **No `avoid_pattern`** — a seam-only convention is skipped (no false violation).
4. **Custom script** — a `checks/CHK-*.sh` exiting nonzero + printing findings → reported;
   an exit-0 script → no violation.
5. **Modes/exit codes:** lenient (violations present) → exit 0 with report; `--strict` → exit
   nonzero; global `check_mode: strict` → nonzero; per-check `strict: true` (one convention)
   with global lenient → exit nonzero (that check strict-effective), and the report marks the
   others `[lenient]`.
6. **Report shape** — violations grouped by check, each with file:line + fix + `[strict|lenient]`.

## 6. Files touched

| File | Change |
|---|---|
| `check.py` | **Create** — the engine (grep-bans + custom scripts, lenient/strict) |
| `session-kit/skills/speccraft-check/SKILL.md` + codex/opencode mirrors | **Create** — run checks, author a check, enable strict, CI snippet |
| `session-kit/skills/speccraft-ratify/SKILL.md` | Note: a convention may carry `avoid_pattern` (+ `strict:`) to make a seam an executable grep-ban |
| `session-kit/hooks/kb-briefing.sh` | Optional lenient check-violation count line |
| `SPEC.md` | Document `speccraft-check`, the two sources, the two modes, the CI snippet |
| `session-kit/evals/fixtures/…` | An example `CHK-01-alembic-metadata.sh` + a grep-ban CONV fixture |
| `session-kit/evals/test-check.sh` + `self-test.sh` | The suite + wire-in |

## 7. Risk / rollback
- Blast radius: a new stdlib script + docs + a KB sub-lane (`checks/`). No product code, no
  change to existing checks/hooks.
- **Default lenient** → adopting the feature can't break anyone's build; strict is opt-in.
- Custom scripts run product-authored code — but only ones the product itself dropped in its KB
  (same trust boundary as the rest of `.speccraft`), invoked only by an explicit `speccraft-check`.
- Rollback: remove `check.py` + the docs; `avoid_pattern`/`checks/` become inert again.

## 8. Out of scope → next
- **Phase 5** — single-source cure: `dup0` fails CI on a *new structural clone* of a ratified
  seam (consumes `seam`/`avoid_pattern`). Phase 4's `--strict` exit contract + the `checks/`
  convention are the substrate Phase 5's clone-check plugs into.
