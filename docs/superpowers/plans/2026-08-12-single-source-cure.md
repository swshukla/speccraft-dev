# Single-Source Cure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a **clone-ban** (Source C) to `speccraft-check`: a ratified seam convention declares its one true implementation via a `canonical:` field, and `check.py` flags any literal copy-paste of it elsewhere in the repo — flowing through Phase 4's lenient/strict exit contract.

**Architecture:** A new source in `check.py` reuses `dup0`'s `body_hash` AST primitive. For each convention with `canonical: <rel>.py::<func>`, resolve the canonical function's `body_hash`, then walk the repo once and flag every OTHER function whose `body_hash` matches. Violations join Sources A & B in the existing `report()` / strict-effective / exit path. `dup0` is unchanged (stays a passive harvester).

**Tech Stack:** Python 3.9+ (stdlib only, `ast`), the existing `session-kit/evals/` bash harness.

## Global Constraints

- **Python ≥ 3.9, stdlib only.** File IO `encoding="utf-8", errors="ignore"`.
- **Imports (add to `check.py`'s existing stanza):** `import ast` at top; and after the `sys.path.insert(...)`, `from dup0 import body_hash, BORING` (both are module-level in `dup0.py`; `main()` is `__name__`-guarded → importing is side-effect-free). Keep the existing `from drift import load_config` and `from recall import frontmatter`.
- **`canonical` field:** read via `frontmatter()` (a plain `<rel>.py::<func>` scalar — no regex/bracket hazard). A convention with no `canonical` is skipped by Source C.
- **`body_hash` is name-sensitive** (it hashes `ast.dump(..., annotate_fields=False)`, which includes identifiers): the match is a **literal copy-paste** (identical AST, docstring/formatting aside). A renamed/reworded copy will NOT match — this is the documented, honest boundary, and a test pins it.
- **Trivial-body guard:** reuse dup0's `nstmt >= 4` rule. If the canonical function has `nstmt < 4`, OR the canonical file/symbol can't be resolved, emit ONE **diagnostic violation** (visible, not a silent skip) so a mis-declared canonical is loud.
- **Scan scope:** the working tree (`repo`), like Sources A & B. Walk `.py` only; reuse `check.py`'s `SKIP_DIRS`; skip files with `test` in the rel path and functions whose name starts with `__` or is in `BORING` — matching dup0's own filters.
- **Strict-effective:** unchanged from Phase 4 — a clone violation fails the build iff global (`--strict` / `check_mode: strict`) OR the convention's `strict: true`. Violation dict keys stay `check, file, line, text, seam, strict` (so `report()` handles them unchanged).
- **Tests:** extend `session-kit/evals/test-check.sh` (already wired into `self-test.sh` via the `check` section — new assertions fold in automatically). End state unchanged: `check: N passed, 0 failed`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `check.py` | Add Source C (clone-ban): `clone_bans()`, `_find_func_hash()`, `run_clone_bans()`; wire into `main()` | **Modify** |
| `session-kit/evals/test-check.sh` | Source C assertions | **Modify** |
| `session-kit/skills/speccraft-check/SKILL.md` + codex/opencode mirrors | Document `canonical:` + the clone-ban (third source) | **Modify** |
| `session-kit/skills/speccraft-ratify/SKILL.md` | Note a seam may declare `canonical:` to enable the structural clone-ban | **Modify** |
| `SPEC.md` | Document the clone-ban source + `canonical:` | **Modify** |
| `session-kit/evals/fixtures/kb-check-examples/…` | A canonical-seam convention fixture + a clone fixture | **Create** |

---

## Task 1: `check.py` — Source C (clone-ban)

**Files:** Modify `check.py`; Modify `session-kit/evals/test-check.sh`.

**Interfaces:**
- Consumes: conventions with `canonical:`; `dup0.body_hash`; the product repo's `.py` files.
- Produces: clone violations (`check`/`file:line`/`text`/`seam`/`strict`) folded into the existing report + exit.

- [ ] **Step 1: Write the failing test** — append this block to `test-check.sh` BEFORE the final `echo "check: …"` / `[ "$fail" -eq 0 ]`:

```bash
echo "== clone-ban: literal copy of a canonical seam is flagged =="
KBC="$TMP/kbc"; mkdir -p "$KBC/kb/normative/conventions"
CREPO="$TMP/crepo"; mkdir -p "$CREPO/app"
printf 'repo: %s\n' "$CREPO" > "$KBC/kbforge.yaml"
# canonical seam (5 statements, nstmt>=4)
cat > "$CREPO/app/entitlements.py" <<'EOF'
def effective_tier(user):
    base = user.plan
    bonus = user.credits * 2
    total = base + bonus
    ok = total >= 10
    return ok
EOF
mkconv_canon() { # $1=kb $2=id $3=canonical $4=strict(true/"")
  { echo '---'; echo 'status: ratified'; echo 'anchors: [app]';
    echo 'seam: "effective_tier(user)"'; echo "canonical: \"$3\"";
    [ "$4" = "true" ] && echo 'strict: true';
    echo '---'; echo "## $2 — one entitlement seam"; } > "$1/kb/normative/conventions/$2.md"
}
mkconv_canon "$KBC" CONV-11 'app/entitlements.py::effective_tier' ""
# an identical copy elsewhere
cat > "$CREPO/app/dupe.py" <<'EOF'
def compute_access(user):
    base = user.plan
    bonus = user.credits * 2
    total = base + bonus
    ok = total >= 10
    return ok
EOF
OUT=$(python3 "$FORGE/check.py" --config "$KBC/kbforge.yaml" 2>&1) || true
printf '%s' "$OUT" | grep -q 'app/dupe.py' && ok "clone flagged at file:line" || bad "clone flagged"
printf '%s' "$OUT" | grep -q 'CONV-11' && ok "clone names the convention" || bad "clone names conv"
printf '%s' "$OUT" | grep -q 'effective_tier' && ok "clone points at the canonical" || bad "clone points canonical"
printf '%s' "$OUT" | grep -q 'app/entitlements.py' && bad "canonical itself flagged (should not be)" || ok "canonical itself not flagged"

echo "== clone-ban: renamed copy is NOT flagged (honest boundary) =="
KBR="$TMP/kbr"; mkdir -p "$KBR/kb/normative/conventions"
RREPO="$TMP/rrepo"; mkdir -p "$RREPO/app"
printf 'repo: %s\n' "$RREPO" > "$KBR/kbforge.yaml"
cp "$CREPO/app/entitlements.py" "$RREPO/app/entitlements.py"
mkconv_canon "$KBR" CONV-11 'app/entitlements.py::effective_tier' ""
cat > "$RREPO/app/renamed.py" <<'EOF'
def compute_access(u):
    b = u.plan
    x = u.credits * 2
    t = b + x
    y = t >= 10
    return y
EOF
python3 "$FORGE/check.py" --config "$KBR/kbforge.yaml" 2>&1 | grep -q 'app/renamed.py' && bad "renamed copy flagged (body_hash should differ)" || ok "renamed copy not flagged"

echo "== clone-ban: no clone → clean, exit 0 =="
KBK="$TMP/kbk"; mkdir -p "$KBK/kb/normative/conventions"
KREPO="$TMP/krepo"; mkdir -p "$KREPO/app"
printf 'repo: %s\n' "$KREPO" > "$KBK/kbforge.yaml"
cp "$CREPO/app/entitlements.py" "$KREPO/app/entitlements.py"
mkconv_canon "$KBK" CONV-11 'app/entitlements.py::effective_tier' ""
python3 "$FORGE/check.py" --config "$KBK/kbforge.yaml" 2>&1 | grep -q 'speccraft-check: 0 violations' && ok "no clone → 0 violations" || bad "clean clone-ban"

echo "== clone-ban: trivial canonical (nstmt<4) → diagnostic, not silent =="
KBT="$TMP/kbt"; mkdir -p "$KBT/kb/normative/conventions"
TREPO="$TMP/trepo"; mkdir -p "$TREPO/app"
printf 'repo: %s\n' "$TREPO" > "$KBT/kbforge.yaml"
printf 'def tiny(u):\n    return u.plan\n' > "$TREPO/app/entitlements.py"
mkconv_canon "$KBT" CONV-11 'app/entitlements.py::tiny' ""
python3 "$FORGE/check.py" --config "$KBT/kbforge.yaml" 2>&1 | grep -qi 'trivial' && ok "trivial canonical → diagnostic" || bad "trivial diagnostic"

echo "== clone-ban: missing canonical symbol → diagnostic =="
KBM="$TMP/kbm"; mkdir -p "$KBM/kb/normative/conventions"
MREPO="$TMP/mrepo"; mkdir -p "$MREPO/app"
printf 'repo: %s\n' "$MREPO" > "$KBM/kbforge.yaml"
cp "$CREPO/app/entitlements.py" "$MREPO/app/entitlements.py"
mkconv_canon "$KBM" CONV-11 'app/entitlements.py::does_not_exist' ""
python3 "$FORGE/check.py" --config "$KBM/kbforge.yaml" 2>&1 | grep -qi 'not found' && ok "missing symbol → diagnostic" || bad "missing symbol diagnostic"

echo "== clone-ban: modes (lenient exit 0; strict exits nonzero) =="
python3 "$FORGE/check.py" --config "$KBC/kbforge.yaml" >/dev/null 2>&1 && ok "clone lenient → exit 0" || bad "clone lenient exit 0"
python3 "$FORGE/check.py" --config "$KBC/kbforge.yaml" --strict >/dev/null 2>&1 && bad "clone --strict exit nonzero" || ok "clone --strict exit nonzero"
KBS="$TMP/kbs"; mkdir -p "$KBS/kb/normative/conventions"
printf 'repo: %s\n' "$CREPO" > "$KBS/kbforge.yaml"
mkconv_canon "$KBS" CONV-11 'app/entitlements.py::effective_tier' true
OUT=$(python3 "$FORGE/check.py" --config "$KBS/kbforge.yaml" 2>&1); RC=0; python3 "$FORGE/check.py" --config "$KBS/kbforge.yaml" >/dev/null 2>&1 || RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '\[strict\]' && ok "per-check strict clone → nonzero + [strict]" || bad "per-check strict clone"

echo "== clone-ban: convention without canonical is skipped by Source C =="
KBN="$TMP/kbn"; mkdir -p "$KBN/kb/normative/conventions"
printf 'repo: %s\n' "$CREPO" > "$KBN/kbforge.yaml"
{ echo '---'; echo 'status: ratified'; echo 'anchors: [app]'; echo 'seam: "x()"'; echo '---'; echo '## CONV-9'; } > "$KBN/kb/normative/conventions/CONV-9.md"
python3 "$FORGE/check.py" --config "$KBN/kbforge.yaml" 2>&1 | grep -q 'speccraft-check: 0 violations' && ok "no canonical → Source C skips" || bad "no-canonical skip"
```

- [ ] **Step 2: Run to verify it fails** — `bash kb-forge/speccraft/forge/session-kit/evals/test-check.sh` → FAIL (Source C not implemented; check.py ignores `canonical`).

- [ ] **Step 3: Implement Source C** in `check.py`.

Add `import ast` to the top imports, and `from dup0 import body_hash, BORING` to the import stanza (below `from recall import frontmatter`). Then add:

```python
def clone_bans(kbroot):
    """Conventions that declare a canonical seam implementation."""
    cdir = os.path.join(kbroot, "kb", "normative", "conventions")
    out = []
    if not os.path.isdir(cdir):
        return out
    for fn in sorted(os.listdir(cdir)):
        if not fn.endswith(".md"):
            continue
        meta = frontmatter(os.path.join(cdir, fn))
        canon = meta.get("canonical", "")
        if not canon:
            continue
        out.append({"id": fn[:-3], "canonical": canon,
                    "seam": meta.get("seam", ""),
                    "strict": str(meta.get("strict", "")).lower() == "true"})
    return out


def _find_func_hash(repo, canonical):
    """(chash, cn, rel, lineno), None  — or  None, reason."""
    if "::" not in canonical:
        return None, f"canonical must be '<path>::<func>', got {canonical!r}"
    rel, sym = canonical.split("::", 1)
    fp = os.path.join(repo, rel)
    if not os.path.isfile(fp):
        return None, f"canonical file not found: {rel}"
    try:
        tree = ast.parse(open(fp, encoding="utf-8", errors="ignore").read())
    except (SyntaxError, OSError) as e:
        return None, f"canonical file unparseable ({rel}): {e}"
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == sym:
            h, n = body_hash(node)
            return (h, n, rel, node.lineno), None
    return None, f"canonical symbol not found: {sym} in {rel}"


def run_clone_bans(repo, bans):
    out = []
    targets = {}   # chash -> (ban, canon_rel, canon_line)
    for b in bans:
        res, err = _find_func_hash(repo, b["canonical"])
        if err:
            out.append({"check": b["id"], "file": "(canonical)", "line": 0,
                        "text": err, "seam": b["seam"], "strict": b["strict"]})
            continue
        chash, cn, canon_rel, canon_line = res
        if cn < 4:
            out.append({"check": b["id"], "file": canon_rel, "line": canon_line,
                        "text": f"seam too trivial to clone-ban (nstmt={cn}, need >=4)",
                        "seam": b["seam"], "strict": b["strict"]})
            continue
        targets[chash] = (b, canon_rel, canon_line)
    if not targets:
        return out
    for root, dirs, files in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if not f.endswith(".py"):
                continue
            fp = os.path.join(root, f)
            rel = os.path.relpath(fp, repo)
            if "test" in rel.lower():
                continue
            try:
                tree = ast.parse(open(fp, encoding="utf-8", errors="ignore").read())
            except (SyntaxError, OSError):
                continue
            for node in ast.walk(tree):
                if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    continue
                if node.name.startswith("__") or node.name in BORING:
                    continue
                h, _ = body_hash(node)
                if h not in targets:
                    continue
                b, canon_rel, canon_line = targets[h]
                if rel == canon_rel and node.lineno == canon_line:
                    continue   # the canonical itself
                out.append({"check": b["id"], "file": rel, "line": node.lineno,
                            "text": f"re-implements the {b['seam'] or b['id']} seam "
                                    f"(clone of {b['canonical']})",
                            "seam": f"call {b['canonical']} instead",
                            "strict": b["strict"]})
    return out
```

Wire into `main()` — extend the violations line:
```python
violations = (run_grep_bans(repo, grep_bans(kbroot))
              + run_check_scripts(repo, kbroot)
              + run_clone_bans(repo, clone_bans(kbroot)))
```
(Note the degenerate case: two conventions whose canonical functions have the *same* body_hash would collide in `targets` — acceptable, they are literally identical code; a comment suffices.)

- [ ] **Step 4: Run to verify pass** — `bash kb-forge/speccraft/forge/session-kit/evals/test-check.sh` → `check: N passed, 0 failed` (N = prior 13 + the new clone-ban assertions).

- [ ] **Step 5: Full suite** — `bash kb-forge/speccraft/forge/session-kit/evals/self-test.sh 2>&1 | tail -1` → `self-test: N passed, 0 failed` (N ≥ 212 + new). Report N.

- [ ] **Step 6: Commit**
```bash
git add kb-forge/speccraft/forge/check.py kb-forge/speccraft/forge/session-kit/evals/test-check.sh
git commit -m "feat(speccraft): check.py — clone-ban source (canonical seam, reuse dup0.body_hash)"
```

---

## Task 2: docs — `canonical:` field + clone-ban (third source)

**Files:** Modify `session-kit/skills/speccraft-check/SKILL.md` + `codex-prompts/speccraft-check.md` + `opencode-commands/speccraft-check.md`; Modify `session-kit/skills/speccraft-ratify/SKILL.md`, `SPEC.md`; Create fixtures under `session-kit/evals/fixtures/kb-check-examples/`.

- [ ] **Step 1:** `speccraft-check/SKILL.md` — add the **clone-ban** as the third check source: a convention MAY declare `canonical: <path>.py::<func>`; `speccraft-check` flags any literal copy-paste of that function elsewhere (reusing dup0's AST body-hash). State the honest boundary explicitly: it catches an **identical copy** (docstring/formatting aside), NOT a renamed or reworded reimplementation; and it is Python-only. Same lenient/strict modes as the other sources.

- [ ] **Step 2:** Mirror the addition to `codex-prompts/speccraft-check.md` + `opencode-commands/speccraft-check.md`, harness-adapted (compare the existing pair; check.py is a plain script → no self-apply caveat, consistent with Phase 4).

- [ ] **Step 3:** `speccraft-ratify/SKILL.md` — where it notes `avoid_pattern`/`strict:`, add that a seam MAY also declare `canonical: <path>::<func>` to enable the **structural clone-ban** (flags literal copies of the seam's implementation). Brief, consistent with the existing seam-field notes.

- [ ] **Step 4:** `SPEC.md` — document the clone-ban source + the `canonical:` field (three sources now: grep-bans, custom scripts, clone-ban), including the literal-copy-paste boundary and Python-only scope.

- [ ] **Step 5:** Fixtures under `session-kit/evals/fixtures/kb-check-examples/`: add a convention `CONV-11-entitlement-tier.md` variant (or a sibling) carrying a `canonical:` field, and an example showing a canonical seam file + a clone — a documented illustration of the third source (do NOT wire into a product's real checks / self-test product run).

- [ ] **Step 6:** Verify + commit. `grep -l 'canonical\|clone-ban' kb-forge/speccraft/forge/SPEC.md kb-forge/speccraft/forge/session-kit/skills/speccraft-check/SKILL.md` (both listed); each mirror mentions the clone-ban + the literal-copy boundary; docs match the code (`canonical:` `<path>::<func>` syntax, `nstmt>=4`, Python-only, lenient/strict). Run `bash kb-forge/speccraft/forge/session-kit/evals/self-test.sh 2>&1 | tail -1` (stays green — docs/fixtures only).
```bash
git add kb-forge/speccraft/forge/session-kit/skills/speccraft-check kb-forge/speccraft/forge/session-kit/codex-prompts/speccraft-check.md kb-forge/speccraft/forge/session-kit/opencode-commands/speccraft-check.md kb-forge/speccraft/forge/session-kit/skills/speccraft-ratify/SKILL.md kb-forge/speccraft/forge/SPEC.md kb-forge/speccraft/forge/session-kit/evals/fixtures
git commit -m "docs(speccraft): canonical seam field + clone-ban (third check source)"
```

---

## Self-Review

**Spec coverage** (against `2026-08-12-single-source-cure-design.md`):
- §4.1 `canonical:` field (via frontmatter) → Task 1 `clone_bans()` ✓
- §4.2 Source C (resolve canonical hash, one-walk match, exclude canonical site, diagnostics) → Task 1 `_find_func_hash`/`run_clone_bans` ✓
- §4.3 modes (strict-effective via same report) → Task 1 wiring + mode tests ✓
- §4.4 literal-copy-paste boundary → Task 1 renamed-copy test + Task 2 docs ✓
- §5 tests (clone caught, canonical excluded, renamed not flagged, clean, trivial guard, missing symbol, modes, no-canonical skip) → Task 1 test block ✓
- §6 files → Tasks 1–2 ✓

**Placeholder scan:** all Task 1 code is literal (clone_bans/_find_func_hash/run_clone_bans + wiring). Task 2 is read-and-adapt docs/fixtures with exact target behavior. No vague-in-code placeholders.

**Type/name consistency:** clone violations use the same dict keys (`check/file/line/text/seam/strict`) as Sources A & B, so `report()`/`strict_eff`/exit are unchanged. `body_hash` returns `(hash, nstmt)` — used as `(h, n)`. `canonical` parsed as `<rel>::<sym>` consistently in `_find_func_hash`.

---

## Execution Handoff

Plan complete. Task 1's Source C is literal code reusing `dup0.body_hash` + `BORING`; the one subtlety — `body_hash` is name-sensitive, so the guarantee is literal copy-paste — is pinned by the renamed-copy boundary test and stated in Global Constraints. Task 2 is docs/fixtures (read-and-adapt) with the honest-boundary language called out. After Task 1, the check suite (already wired into self-test) folds the new assertions in automatically.
