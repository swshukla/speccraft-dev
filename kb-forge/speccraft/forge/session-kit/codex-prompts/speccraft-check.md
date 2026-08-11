---
description: Use when someone asks to run the product's deterministic checks, author a new one (a grep-ban convention or a custom check script), or wire strict enforcement into CI — runs check.py, which turns ratified conventions and hand-written scripts into pass/fail checks against the code, lenient by default.
argument-hint: [--strict]
---

Extra flags for this run: $ARGUMENTS

# speccraft-check — deterministic product checks

(Applies to repos with the .speccraft KB layout. The canonical procedure
also lives at `.agents/skills/speccraft-check/SKILL.md`.)

`check.py` is a plain Python script, not a Claude hook — run it the same way
under Codex, OpenCode, Claude Code, or CI, with no self-apply caveat. It
never mutates the product repo; it only reports.

1. **Run it.**
   ```
   python3 <forge>/check.py --config <kbroot>/kbforge.yaml [--strict]
   ```
   `<kbroot>` is the directory holding `kbforge.yaml` (normally
   `.speccraft/`). Fold `$ARGUMENTS` in as extra flags (e.g. `--strict`) if
   given. It prints a report grouped by check id and exits `0` (nothing
   strict-effective failed) or nonzero (≥1 strict-effective violation) —
   see mode 2 below for what "strict-effective" means.

2. **Two sources feed the report** — pick the one that matches what you're
   encoding:
   - **Source A — a ratified convention's `avoid_pattern`.** Any
     `kb/normative/conventions/CONV-NN-<slug>.md` written by
     **speccraft-ratify** MAY carry `avoid_pattern:` (a grep regex, quoted)
     alongside its `seam:`. `check.py` greps every path in that
     convention's `anchors:` for the pattern; each matching line is a
     violation, and the convention's `seam:` is shown as the fix
     (`→ USE: <seam>`). A convention with no `avoid_pattern:` is inert to
     `check.py` — it's still recallable by `recall.py`, it's just not
     enforced.
   - **Source B — a custom check script.** Drop an executable at
     `kb/normative/checks/CHK-NN-<slug>.sh` (any language, `chmod +x`).
     `check.py` runs it with `cwd=<repo>`, `SPECCRAFT_REPO=<repo>` set, and
     a 120s timeout. Exit `0` = pass, no violation. Exit nonzero = one
     violation whose text is the script's stdout (or stderr, or `exit N`
     if both are empty). Give it a header comment block before the first
     real line so `check.py` can read metadata:
     ```
     #!/usr/bin/env bash
     # check-for: INV-1
     # strict: true
     ```
     `check-for:` is shown as the report's `→ USE:` line (which invariant
     or claim the script is enforcing); `strict:` is one of the three ways
     to opt a single check into strict mode (see below). Both header lines
     are optional. See `session-kit/evals/fixtures/kb-check-examples/kb/normative/checks/CHK-01-alembic-metadata.sh`
     for a worked example (a real, runnable script kept as documentation —
     it is not wired into any product's checks).

3. **Two modes, three levers.** Lenient is the default: violations are
   reported but the exit code stays 0. A violation is **strict-effective**
   — and makes `check.py` exit nonzero — iff *either* the run is globally
   strict *or* that specific check opted in:
   - **Global, per-run:** pass `--strict` on the command line.
   - **Global, persistent:** set `check_mode: strict` in `kbforge.yaml`.
   - **Per-check:** `strict: true` in a convention's frontmatter (Source A)
     or a `# strict: true` header line in a check script (Source B) — that
     one check fails the build even when the run itself is lenient.
   The report tags every violation `[strict]` or `[lenient]` so it's clear
   which ones are gating the exit code right now.

4. **Author a new check** — decide Source A vs Source B first:
   - Reach for Source A when the violation is "this literal pattern
     shouldn't appear outside its seam" — it rides on a convention you (or
     **speccraft-ratify**) already wrote, no code to maintain.
   - Reach for Source B when the check needs real logic (cross-referencing
     two files, parsing structure, anything a single regex can't express).
     Keep it fast (well under the 120s timeout), keep its stdout on
     failure short and actionable (it's what the report shows), and don't
     assume any env beyond `SPECCRAFT_REPO` + the script's own `cwd`.

5. **Wire it into CI** (GitHub Actions example — standalone; `check.py` is
   NOT part of the product repo's `pre-commit` hook):
   ```yaml
   - name: speccraft-check
     run: python3 kb-forge/speccraft/forge/check.py --config .speccraft/kbforge.yaml --strict
   ```
   Run it strict in CI even if the team develops lenient locally — CI is
   where "reported" should become "blocking".
