# Single-Source Cure (Phase 5)

**Date:** 2026-08-12
**Type:** Design / spec
**Roadmap:** Phase 5 (final) of `docs/roadmaps/2026-08-01-drift-prevention-roadmap.md`
**Builds on:** Phase 2's seam conventions + Phase 4's `speccraft-check` (lenient/strict exit contract) + `dup0.py`'s AST clone primitive.
**Status:** approved design (both forks confirmed) → ready for writing-plans

---

## 1. Problem

Phase 4 made conventions enforceable, but only *textually*: a grep-ban (`avoid_pattern`) catches a known anti-pattern string. It cannot catch a **copy-pasted clone** — the seam's implementation duplicated elsewhere, which no single grep pattern anticipates but is the very duplication the seam exists to prevent (the audit's Telegram-send ×10, tier-gate ×3, cue-band ×2, Razorpay ×2). `dup0.py` already *detects* such clones by AST body-hash, but only writes them to a passive `kb/derived/dup-residue.md` residue report — it never fails anything, and it is blind to which seam is *ratified* as the single source.

**What "clone" means precisely here (`dup0.body_hash`):** it hashes `ast.dump(body, annotate_fields=False)` with the leading docstring dropped — so the match is an **identical AST including identifier names and literals** (a literal copy-paste, insensitive only to the docstring and formatting). A copy whose variables were *renamed*, or that was *reworded/refactored*, diverges and is **not** caught (see §4.4). This targets the copy-paste case — which is exactly how the audit's duplicates propagated — not fuzzy near-clones.

Phase 5 turns clone-detection into a **build-failing gate scoped to ratified seams**: once a convention declares the one true implementation of a seam, a new structural clone of it is a violation.

**Scope note (two halves of the roadmap item):**
- **Product-side** — actually collapsing the duplicated implementations in a product repo is the product team's manual refactor. **Out of scope** for this speccraft-tool change.
- **Tool-side** — the enforcement mechanism below. **This is the deliverable.**

## 2. What exists (grounding)

- **`dup0.py`** — `body_hash(node)` returns `(sha1_hex[:12], nstmt)` for a `FunctionDef`/`AsyncFunctionDef`, dropping the leading docstring. dup0 walks `.py` files (skipping `SKIP_DIRS`, files with `test` in the path, and `__dunder__`/`BORING` names) and treats a function as clone-worthy only at **`nstmt >= 4`** (its trivial-body guard). It runs read-only at the pin snapshot and only reports.
- **`check.py`** (Phase 4) — Source A (grep-bans) + Source B (custom scripts) both flow into one `report()` that computes `strict_eff` (`global_strict or v["strict"]`) and exits nonzero iff ≥1 strict-effective violation. Violation dict keys: `check, file, line, text, seam, strict`. Reuses `from drift import load_config` + `from recall import frontmatter`.
- **Phase 2 convention schema** — `kb/normative/conventions/CONV-NN-*.md` frontmatter: `status`, `anchors`, `seam`, `avoid`, `avoid_pattern`. Phase 5 adds one optional field: `canonical`.

## 3. Goals / non-goals

**Goals**
- A **clone-ban** check (Source C) in `speccraft-check`: for a ratified seam with a `canonical:` implementation, a new structural clone anywhere in the repo is a violation.
- Reuse `dup0`'s `body_hash` primitive and its `nstmt >= 4` trivial-body guard — no new clone algorithm.
- Flow through the **same lenient/strict exit contract + report** as Sources A & B (per-check `strict: true` supported).

**Non-goals**
- Collapsing the product's actual duplicated code (manual product work).
- Fuzzy / near-clone similarity — exact `body_hash` only (see §4.4); a renamed or reworded copy diverges and is not caught. Honest, narrow guarantee: literal copy-paste.
- Non-Python languages — `dup0`'s AST clone detection is Python-only; JS/others are a documented limitation (dup0 only same-names JS, doesn't body-hash it).
- Changing `dup0`'s residue report or making dup0 itself a gate (fork decided: the gate lives in `speccraft-check`, dup0 stays a passive harvester).

## 4. Design

### 4.1 The `canonical:` field
A ratified seam convention MAY declare its one true implementation:
```yaml
seam: "effective_tier(user)"
canonical: "backend/entitlements.py::effective_tier"
```
`canonical` = `<repo-relative-path>::<function-name>`. Read via `frontmatter()` (a plain scalar — no regex/bracket hazard). A convention with no `canonical` is skipped by Source C (grep-ban-only or coaching-only seam).

### 4.2 Source C — the clone-ban (in `check.py`)
For each convention with `canonical`:
1. Parse the canonical file, find the `FunctionDef`/`AsyncFunctionDef` named `<function-name>` (first match via `ast.walk`); compute `body_hash` → `(chash, cn)`.
2. **Trivial-seam guard:** if `cn < 4` (dup0's threshold) or the canonical symbol can't be found, emit ONE diagnostic violation (`"canonical <sym> not found"` / `"seam too trivial to clone-ban (nstmt<4)"`) rather than silently scanning — a mis-declared canonical must be visible, not a false green.
3. Walk the repo's `.py` files (reuse `check.py`'s `SKIP_DIRS`, skip `test`-path files + `__dunder__`/`BORING` like dup0); for each function compute `body_hash`; if `h == chash` AND its `(rel, lineno)` is not the canonical site → a **clone violation**: `check: CONV-NN`, `file:line`, `text: "re-implements the <seam> seam"`, `seam: "call <canonical> instead"`, `strict:` from the convention.
4. Scans the **working tree** (`repo`), consistent with Sources A & B (current code), not dup0's pin snapshot.

Reuse: `from dup0 import body_hash, BORING`. (If importing `dup0` proves to have import side-effects, lift `body_hash`/`BORING` into a shared helper — decide in the plan after reading dup0's module top.)

### 4.3 Modes
Identical to Phase 4 — a clone violation is strict-effective iff global (`--strict` / `check_mode: strict`) OR the convention's `canonical` seam is marked `strict: true`. Lenient (default) reports; strict fails the build. So you declare `canonical`, watch it report clones while you collapse the existing copies, then flip `strict: true` to hold the line — the graduated path.

### 4.4 Why exact `body_hash` (not fuzzy)
A literal copy-paste is byte-identical in AST → same `body_hash` → caught the moment it lands. `body_hash` includes identifier names and literals (it hashes `ast.dump(..., annotate_fields=False)`), so the guarantee is deliberately narrow: **identical copy, docstring/formatting aside.** A renamed or reworded copy diverges — that's the fuzzy-clone space we explicitly don't chase (false-positive risk, and drift is the other phases' job). Exact-hash keeps false positives near zero and reuses dup0 as-is; scoping to the *declared canonical hash only* (not all clone clusters) means an unrelated function never trips it. The honest framing for docs/users: this catches copy-paste, not disguised reimplementation.

## 5. Testing

Extend `session-kit/evals/test-check.sh` (Source C block), wired via the existing `check` section:
1. **Clone caught** — a CONV with `canonical: f.py::seam_fn` (nstmt≥4) + a second file with an **identical copy** of that function → a clone violation naming the convention + the canonical.
2. **Canonical itself not flagged** — the canonical site is excluded (no self-violation).
2b. **Renamed copy NOT flagged (boundary)** — a copy of the seam with variables renamed → no violation, documenting the honest limit (`body_hash` is name-sensitive).
3. **No clone → clean** — only the canonical exists → 0 violations, exit 0.
4. **Trivial seam guard** — `canonical` pointing at a <4-statement function → a visible diagnostic violation, not a silent skip.
5. **Missing canonical** — `canonical` naming a symbol that doesn't exist → diagnostic violation.
6. **Modes** — a lenient `canonical` clone → reported, exit 0; the same with `strict: true` (or `--strict`) → exit nonzero, tagged `[strict]`.
7. **No `canonical`** — a seam convention without the field is skipped by Source C (no false clone).

## 6. Files touched

| File | Change |
|---|---|
| `check.py` | **Add Source C** (clone-ban) — reuse `dup0.body_hash`; new-clone-of-canonical → violation, same report/exit |
| `session-kit/skills/speccraft-check/SKILL.md` + codex/opencode mirrors | Document the `canonical:` field + clone-ban (third source) |
| `session-kit/skills/speccraft-ratify/SKILL.md` | Note a seam may declare `canonical:` to enable the structural clone-ban |
| `SPEC.md` | Document the clone-ban source + `canonical:` |
| `session-kit/evals/fixtures/…` | A canonical-seam fixture + a clone fixture |
| `session-kit/evals/test-check.sh` | Source C assertions (folds into the existing `check` section) |

## 7. Risk / rollback
- Blast radius: a new source inside the existing `check.py` + docs + fixtures. No change to `dup0`, existing checks, or hooks.
- **Default lenient** → declaring a `canonical` can't break a build; strict is opt-in per seam.
- False-positive control: exact-hash + `nstmt >= 4` + canonical-only scope; the trivial/missing-canonical guard makes a mis-declared seam loud, never a silent pass.
- Rollback: remove Source C; `canonical` becomes an inert field.

## 8. Out of scope → roadmap complete
Phase 5 is the last roadmap phase. After it, the C+D spine is whole: **convergence** (Phase 0 queue, per-commit drift), **prevention** (Phase 2 seams, Phase 3 write-lane freeze), and **durable enforcement** (Phase 1 trust gate, Phase 4 executable checks, Phase 5 structural clone-ban). The seam a human ratifies is now defended three ways: textually (grep-ban), behaviorally (custom check), and structurally (clone-ban).
