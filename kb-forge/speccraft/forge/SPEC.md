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
3. **Cite or it didn't happen** — every claim carries `path:line @<pin>`.
4. **Provenance is never blurred**, and nothing becomes `ratified` except by
   the founder (via QUEUE.md; the ruling commit is the audit record).
5. **Deterministic before generative** — anything harvestable by regex/git is
   harvested by the CLI tools (cannot hallucinate); agents only interpret, and
   their output enters as `pending-ratification` hypotheses.

## KB layout (`<product>/.speccraft/`)

    kbforge.yaml          product profile: repo path, components, risk_paths
    README.md             trust rules
    QUEUE.md              the one adjudication queue (doc 09); founder rulings
    ledger/DIV-*.md       ruled divergences (fix-code / fix-model / accepted-deviation)
    findings/FINDINGS.md  consolidated bug/work list — proposed→confirmed→fixed
                          (agents append `proposed`; only KB_RATIFY sets confirmed)
    kb/derived/           machine-harvested, provenance=derived, regenerated
                          wholesale on re-pin — never hand-edited
    kb/normative/         elicited intent & invariants (founder interviews)
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
| `recall.py` | Structural retrieval: match `anchors:` (path prefixes + `topic:` slugs) against files/topics about to be touched; trust-ordered output; explicit NO-COVERAGE warning (doc 06 Ground step) | no |
| Agent passes | Archaeology / interview / confrontation / extraction — run as Claude Code sessions; read at pin, write `kb/inferred/` or interview → `kb/normative/` | yes |

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

## The ship loop (write-back-on-ship, doc 06, laptop scale)

    finish session → commit in product repo
      → drift.py --queue   (vs the OLD pin — MUST run before re-pin, else
                            pin==HEAD and nothing is ever flagged)
      → seed0.py    (re-pin derived layer)
      → assume0.py + dup0.py  (re-harvest residue & consistency candidates)
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
  edit-time lane deny (friendly early layer before the git guard).

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
