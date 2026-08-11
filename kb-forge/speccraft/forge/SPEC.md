# kb-forge — system spec

Laptop-scale implementation of the agentic-SDLC knowledge layer
(`~/.speccraft/docs/agentic-sdlc/`, chiefly docs 03/04/05/06) for a solo
developer and one product. Point it at a product repo; it builds and maintains
a trust-graded knowledge base in a **tracked folder inside that repo**
(`<product>/.speccraft/`). From the import commit onward the product repo's git
history is the KB audit ledger — code and the judgment that shaped it can land
atomically in one commit, and one clone/push carries both. First deployment:
`~/stocktickerapp/.speccraft/`.

## Design rules (non-negotiable)

1. **Tooling writes only inside `.speccraft/`.** Product code is never touched
   by kb-forge; ship-loop commits are `kb:`-prefixed and pathspec-limited to
   `.speccraft/`.
2. **Read the product only at the pin** — the sha recorded in
   `kb/derived/inventory.md` (`git show`/`git grep`/`git archive` at that sha),
   never the working tree. A dirty mid-session tree is invisible to the KB;
   uncommitted code is not a fact. The pin is the **last code commit**
   (`git log -1 -- . ':(exclude).speccraft'`), so KB-only commits never move it.

   `kb/derived/inventory.md` carries two anchors, not one:
   - `source_commit` — the mechanical pin above; advanced every commit by the
     ship loop (`seed0.py`), ungated. What `drift.py` diffs the working tree
     against.
   - `ratified_through` — the trust boundary; advanced only by `ratify`
     (`gate.py`), which refuses the advance while open HIGH findings exceed
     `high_debt_ceiling` or `high_debt_max_age_days` (waivable, logged to
     `ledger/DEBT-WAIVERS.md`). "The KB is reviewed-and-clean through here."
     The KB is caught up when `ratified_through == source_commit` and no HIGH
     debt is open; otherwise commits between the two anchors are unreviewed.
3. **Cite or it didn't happen** — every claim carries `path:line @<pin>`.
4. **Provenance is never blurred**, and nothing becomes `ratified` except by
   the founder (via QUEUE.md; the ruling commit is the audit record).
5. **Deterministic before generative** — anything harvestable by regex/git is
   harvested by the CLI tools (cannot hallucinate); agents only interpret, and
   their output enters as `pending-ratification` hypotheses.

## KB layout (`<product>/.speccraft/`)

    kbforge.yaml          product profile: repo path, components, risk_paths

- `high_debt_ceiling` (default 3) — max open HIGH findings before a
  `ratified_through` advance is refused. Set 0 for zero-tolerance.
- `high_debt_max_age_days` (default 14) — any open HIGH finding older than this
  (by its `Raised` date) refuses a `ratified_through` advance. `source_commit`
  (the mechanical pin) is never gated — see the two-anchor note above.

    README.md             trust rules
    QUEUE.md              the one adjudication queue (doc 09); founder rulings
    ledger/DIV-*.md       ruled divergences (fix-code / fix-model / accepted-deviation)
    findings/FINDINGS.md  consolidated bug/work list — proposed→confirmed→fixed
                          (agents append `proposed`; only KB_RATIFY sets confirmed)
                          `Raised` column (ISO date, stamped on append, never changed);
                          open HIGH findings gate `ratified_through` advance (see `gate.py`)
    kb/derived/           machine-harvested, provenance=derived, regenerated
                          wholesale on re-pin — never hand-edited
    kb/normative/         elicited intent & invariants (founder interviews)
    kb/normative/conventions/CONV-NN-<slug>.md
                          one ratified convention per file: `status`,
                          `anchors` (paths / `topic:` slugs), and — for a
                          canonical-symbol seam — `seam:` (the symbol to
                          use) / `avoid:` (the anti-pattern it replaces) /
                          optional `avoid_pattern:` (grep regex; when
                          present, `check.py` enforces it as a grep-ban —
                          see "Executable checks" below). `recall.py`
                          renders a seam match as
                          `→ USE: <seam>` / `→ AVOID: <avoid>` under the
                          fact. `03-conventions.md` stays a human-maintained
                          index (ratify adds one line per CONV by hand);
                          recall matches against the per-file frontmatter,
                          not the index.
    kb/inferred/          agent-drafted claims, status=pending-ratification
    kb/decisions/         (planned) ADR-lite capture-at-decision-time lane

## Aspects covered

| # | Aspect | File | Provenance |
|---|--------|------|------------|
| 1 | Inventory, routes, models, tests, churn, modules | `kb/derived/*` | derived (seed0) |
| 2 | Product intent, stage, monetization | `kb/normative/00` | elicited |
| 3 | Invariants INV-1..5 | `kb/normative/01` | elicited/observed |
| 4 | Social/content engine strategy | `kb/normative/02` | elicited |
| 5 | PM-strategy rationale | `kb/inferred/03` | inferred |
| 6 | Tier promises vs code (capability map) | `kb/inferred/04` | inferred |
| 7 | Data sources (external + internal derived datasets) | `kb/inferred/05` | inferred |
| 8 | Integrations: why each exists, capabilities used, recursive component→3P dependency rollup | `kb/inferred/06` | inferred |
| 9 | Assumptions/tradeoffs: residue → hypothesis cards → confrontation | `kb/derived/assumption-residue.md` + `kb/inferred/07` | derived + inferred |
| 10 | Consistency: contradictions, duplicates, lint triage, proposed conventions (norms bind only once ratified) | `kb/derived/dup-residue.md` + `kb/derived/lint-report.md` + `kb/inferred/08` | derived + inferred |
| 11 | Tech dependencies + version-pinned best-practices/gotchas (sourced, not invented) | `kb/derived/dependencies.md` + `kb/inferred/09` | derived + **external** |

## Tools

| Tool | Role | LLM? |
|------|------|------|
| `seed0.py` | Harvest structure: routes, models, tests, churn, module map w/ risk tags; writes `kb/derived/`, sets the pin | no |
| `assume0.py` | Harvest decision residue: TODO/HACK, swallowed excepts, frozen constants, timing/retry values, thresholds, deleted files, reverts → `kb/derived/assumption-residue.md` | no |
| `dup0.py` | Harvest duplicate/contradiction candidates: same-name multi-module functions (ast + regex), identical-body clones, same-constant-different-values, shared hardcoded hosts → `kb/derived/dup-residue.md`; plus ruff F/B/S at the pin → `kb/derived/lint-report.md` | no |
| `drift.py` | Two-directional drift vs pin (below) | no |
| `deps0.py` | Harvest dependency inventory + pinned versions → `kb/derived/dependencies.md`; runs security scanners (pip-audit / npm audit) on a **7-day cadence** (off the per-commit path — see ship loop) and queues advisories that are NEW against unchanged pins | no |
| `dep-diff.py` | Per-commit: correlate manifest version changes vs the pinned table, flag version-pinned gotcha cards in `kb/inferred/09` that a bump may invalidate; `--queue` tiers card-matched + risk-tagged changes as work (routine bumps stay report-only) | no |
| `recall.py` | Structural retrieval: match `anchors:` (path prefixes + `topic:` slugs) against files/topics about to be touched; trust-ordered output; explicit NO-COVERAGE warning (doc 06 Ground step) | no |
| Agent passes | Archaeology / interview / confrontation / extraction — run as Claude Code sessions; read at pin, write `kb/inferred/` or interview → `kb/normative/` | yes |
| `check.py` | Deterministic product checks: convention `avoid_pattern` grep-bans + custom `kb/normative/checks/` scripts — see "Executable checks" below. Standalone, not part of the ship loop or pre-commit | no |

## Drift detection (drift.py)

**SUBTRACTIVE** — the KB cites code that changed. Citation ∩ diff-hunk
intersection against the pin. Refresh policy by provenance:
derived → re-run seed0+assume0; inferred → demote claim to `challenged`,
re-verify; elicited → intent survives code change, flag for the confrontation
pass only. Severities: cited-file-DELETED / cited-lines-changed /
file-changed-elsewhere (weak).

**ADDITIVE** — code gained surface the KB doesn't cover. Scans added diff
lines for aspect signatures:
- *integration surface*: external URLs, HTTP/SDK client imports, beat-schedule
  entries, api-key config → refresh `05-data-sources.md` + `06-integrations.md`
- *assumption surface*: new UPPER_CASE numeric constants, timing/retry values,
  swallowed exceptions → re-run assume0; new residues become new hypothesis
  cards in `07-assumptions.md`

`--queue` appends both directions to QUEUE.md so refresh flows through
adjudication like everything else.

## Executable checks (check.py)

`python3 <forge>/check.py --config <kbroot>/kbforge.yaml [--strict]` runs
deterministic product checks and prints a report grouped by check id.
Standalone — invoked by hand, by the `speccraft-check` procedure, or by CI;
it is NOT wired into the product repo's `pre-commit` hook or the ship loop.

Two sources feed it:
- **Grep-bans** — any `kb/normative/conventions/CONV-NN-*.md` that carries
  `avoid_pattern:` (a grep regex, read raw — not through the `#`-splitting
  `frontmatter()` parser, so the regex survives intact). `check.py` greps
  that convention's `anchors:` paths for the pattern; each matching line
  is a violation, reported with the convention's `seam:` as the fix
  (`→ USE: <seam>`). A convention without `avoid_pattern:` is skipped.
- **Custom check scripts** — an executable at
  `kb/normative/checks/CHK-NN-<slug>.sh` (any language). Run with
  `cwd=<repo>`, `SPECCRAFT_REPO=<repo>` in its env, 120s timeout. Exit 0 =
  pass; exit nonzero = one violation whose text is the script's stdout
  (falling back to stderr, then `exit N`). An optional header —
  `# check-for: INV-N` / `# strict: true` before the first real line — is
  parsed for the report's `→ USE:` line and the strict lever below.

Two modes: **lenient** (default) reports violations but exits 0; **strict**
exits nonzero if ≥1 violation is *strict-effective*. A violation is
strict-effective iff the run is globally strict (`--strict` on the CLI, or
`check_mode: strict` in `kbforge.yaml`) OR that individual check opted in
(`strict: true` in the convention's frontmatter, or a script's
`# strict: true` header) — so one check can fail the build even inside an
otherwise-lenient run. The report tags each violation `[strict]` or
`[lenient]` accordingly.

CI wiring (GitHub Actions):
```yaml
- name: speccraft-check
  run: python3 kb-forge/speccraft/forge/check.py --config .speccraft/kbforge.yaml --strict
```

Example fixtures (documentation, not wired into any product's checks):
`session-kit/evals/fixtures/kb-check-examples/kb/normative/conventions/CONV-11-*.md`
(a grep-ban) and
`session-kit/evals/fixtures/kb-check-examples/kb/normative/checks/CHK-01-alembic-metadata.sh` (a custom script).

## The ship loop (write-back-on-ship, doc 06, laptop scale)

    finish session → commit in product repo
      → drift.py --queue --demote  (vs the OLD pin — MUST run before re-pin,
                                    else pin==HEAD and nothing is ever flagged)
      → dep-diff.py --queue  (manifest bumps vs pinned gotcha cards; parsers
                              only — network scanners never on this path)
      → decay.py             (age out stale trust)
      → seed0.py             (re-pin derived layer)
      → assume0.py + dup0.py (re-harvest residue & consistency candidates)
      → deps0.py --queue     (re-pin dependency inventory; the security
                              scanners run + queue NEW advisories only when the
                              last scan is >7d old — weekly cadence riding
                              commit activity, no external cron needed. Force
                              anytime / in CI: `deps0.py --advisories-only
                              --queue`)
      → answer QUEUE items when convenient (rulings are commits)

Automated by `session-kit/post-commit` (git hook in the product repo).
Guards: commits touching only `.speccraft/` never re-trigger the loop (kills
self-recursion from the loop's own `kb:` commit); linked-worktree commits are
skipped (the loop fires when work lands on the main tree); a lockfile
collapses rapid commit bursts into one run. Code-only history view:
`git log -- ':(exclude).speccraft'`.

## Session integration (session-kit/) — multi-agent

Three layers, by decreasing guarantee strength; all hooks are repo-relative
(`git rev-parse --show-toplevel` → `<root>/.speccraft/`), so one kit serves
every product. kb-forge location override: `KBFORGE_HOME` env.

**Guarantees (git chokepoint — every tool, every human):**
- `pre-commit` lane guard: commits touching `kb/normative/`, `kb/derived/`,
  `ledger/` are REJECTED unless `KB_RATIFY=1` (founder ruling) or
  `KB_SHIPLOOP=1` (the loop's own re-pin commit). Instruction conflicts in
  prose can degrade compliance, never correctness.
- `post-commit` ship loop (see above): fires on any tool's commit.

**Awareness (static files every agent loads):**
- `AGENTS.md` KB section (Codex + OpenCode read AGENTS.md natively;
  `CLAUDE.md` = `@AGENTS.md` import since Claude Code does not): rules,
  write lanes, pointer to KB-STATUS.md and the speccraft-* procedures. Appended as
  one delimited section; developers own the rest of the file.
- `.speccraft/KB-STATUS.md`: agent-agnostic briefing (pin, sync, open queue
  count, invariants) — regenerated by the ship loop only when content
  changes, so it is current-as-of-last-commit in every tool.

**Procedures (invocable, per tool) + Claude live extras:**
- Four procedures, single source `session-kit/skills/*/SKILL.md`:
  `speccraft-recall` (ground the task; trust-class interpretation; no-coverage
  stop), `speccraft-decide` (ADR-lite at decision time), `speccraft-diverge` (file
  conflict, never self-ratify), `speccraft-ratify` (founder ruling session; commits
  with KB_RATIFY=1). Installed to `.claude/skills/` (Claude Code) and
  `.agents/skills/` (the Agent Skills standard — Codex and OpenCode both read
  it natively), plus `.opencode/commands/` for explicit `/speccraft-*` invocation
  and `~/.codex/prompts/` (user-global, deprecated-but-working parity).
  Note: OpenCode prefers AGENTS.md and ignores CLAUDE.md when both exist —
  another reason the rules live in AGENTS.md.
- Claude-only live hooks (`.claude/settings.local.json`, untracked):
  SessionStart briefing injection; PostToolUse recall-on-contact (anchored
  facts injected after each Edit/Write, deduped, incl. subagents); PreToolUse
  edit-time lane deny (friendly early layer before the git guard) —
  `kb-recall-gate.sh` denies-once on a ratified-fact match, and, as a second
  branch, denies-once under the **Confusion Protocol**: a risk-tagged path
  (`risk_paths` in `kbforge.yaml`) with NO KB coverage in any lane
  (`recall.py --no-coverage-check`, exit 3) is denied once, instructing the
  agent to run recall, elicit intent, or file a coverage-gap divergence
  (`speccraft-diverge`) before re-issuing — never guess-and-clone a seam it
  can't see. The ratified-match branch takes precedence; non-risk or
  covered paths are never denied by this branch. Also in the same PreToolUse
  chain, between the git-guard layer and `kb-recall-gate.sh`: `kb-freeze.sh`
  (edit-scope freeze — see the `speccraft-freeze` procedure below).
- **Edit-scope freeze** (`speccraft-freeze` procedure, orchestrator-facing):
  confines a fanned-out sub-agent's edits to an assigned lane of the repo.
  The orchestrator sets `SPECCRAFT_FREEZE="<space-separated repo-relative
  path prefixes>"` in the sub-agent's launch env; `kb-briefing.sh`
  (SessionStart) materializes it into that session's lane file at
  `${TMPDIR:-/tmp}/speccraft-freeze-<session-id>`; `kb-freeze.sh`
  (PreToolUse) hard-denies any Edit/Write/MultiEdit outside the lane. A path
  is in-lane iff it equals a lane prefix exactly or starts with
  `<prefix>/`. A running session's lane can be widened via `kb-freeze.sh
  --set --sid <id> <paths…>`. Dormant unless a lane is assigned (no env, no
  lane file → fails open, all edits allowed) — freezing is opt-in, per
  session, orchestrator-controlled. Under Codex/OpenCode there is no
  PreToolUse hook, so the mirrors direct the agent to self-apply the
  lane boundary as discipline rather than enforcement. Documented as the
  `speccraft-freeze` skill (`session-kit/skills/speccraft-freeze/SKILL.md`),
  single-sourced and installed to Claude/Codex/OpenCode via the same
  `speccraft-*` glob as the other procedures; the automatic deny is the
  Claude-Code `kb-freeze.sh` PreToolUse hook.

**Entry points:** `kbforge-init.sh <repo>` scaffolds .speccraft/ + seeds +
installs (new product, phases 1–4; phase 5 = judgment bootstrap is
human-paced). `session-kit/install.sh [repo]` re-arms a fresh clone (git
hooks and settings.local.json do not travel with clones; tracked artifacts —
skills, AGENTS.md section, OpenCode commands — do).

Before starting work: `recall.py --files <paths you'll touch>` — the facts,
invariants, and existing integrations for that locus, in trust order.

## Fact lifecycle

    derived (mechanical, certain at pin)
    inferred / pending-ratification (agent hypothesis, cited)
      → ratified (founder ruling via QUEUE)
      → challenged (drift or contradiction) → re-verified | demoted
    elicited (founder's own words) — invalidated only by the founder
    external (knowledge from outside the repo — dependency practices, gotchas)
      sub-graded by source: external:doc (official doc URL + version) /
      external:advisory (CVE/GHSA) / external:model-prior (LLM, UNVERIFIED —
      never trusted until ratified). Hard rule: a gotcha is sourced or marked
      unverified; never invented. Version-pinned — a dep version bump
      challenges its cards (see drift, third signal).
    divergences (intent ≠ code) → ledger/DIV-* with ruling + revisit trigger
