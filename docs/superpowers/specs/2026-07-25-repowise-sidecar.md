# Repowise Sidecar Integration — Multi-Repo Code Intelligence for speccraft

**Date:** 2026-07-25
**Status:** Draft for review (rev 2 — decision-sync provenance fix, hook
folded into recall.py, graceful degradation, augments-not-replaces)
**Depends on:** `2026-07-25-mission-control-cloud.md`, `docs/agentic-sdlc/04-seeding-and-verification.md`, `docs/agentic-sdlc/03-drift-reconciler.md`, `docs/agentic-sdlc/18-first-principles-intent.md`

## Problem

speccraft's KB seeding (`seed0.py`), drift detection (`drift.py`), and cross-repo validation rely on custom code analysis that is narrow (basic structure parsing), single-repo, and unvalidated against real defects. Repowise provides a production-grade, self-hosted code intelligence engine with:

- 16-language dependency graph (file + symbol nodes, 3-tier call resolution)
- Git intelligence (hotspots, ownership, co-change, bus factor, bug history)
- Code health scoring (25 deterministic markers, calibrated against defect corpus)
- Cross-repo contracts (HTTP/gRPC/topic matching, breaking-change detection)
- Architecture conformance (declare allowed dependencies, lint cycles)
- Decision mining (8 sources, evidence-backed, staleness tracking)

This spec defines the **sidecar integration** — Repowise runs as a separate process, speccraft calls its CLI/MCP API. No library dependency, license-isolated, replaceable.

## Two ground rules (rev 2)

**1. Graceful degradation is mandatory.** Every Repowise call site (seed0,
drift, recall, Mission Control) must work with the sidecar absent, using
deps0's existing discipline: *"when a scanner is absent it is recorded as a
coverage gap, never silently skipped."* Sidecar missing or timing out →
skip the enrichment, write/print a coverage-gap line, exit clean. speccraft
without Repowise is fully functional; Repowise adds signal, never a
dependency.

**2. Capability audit before implementation.** This spec assumes ~15
CLI/JSON surfaces with specific shapes (`inspect --json`, `risk --diff`,
`decision list --json`, `get_context`, workspace commands). Before any
integration code: verify each against the actually-installed Repowise
version, pin `repowise_min_version:` in kbforge.yaml, and mark any surface
that is roadmap-not-shipped as deferred in this spec. Integration code
checks the version at startup and degrades (rule 1) on mismatch.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    speccraft (agent governance)                  │
│  kbforge.yaml  →  seed0.py  →  .speccraft/kb/                   │
│  drift.py      →  .speccraft/ledger/                            │
│  hooks         →  kb-recall-gate.sh / kb-recall-post.sh         │
│  Mission Control dashboard                                     │
├─────────────────────────────────────────────────────────────────┤
│                    Repowise Sidecar                              │
│  repowise init / update / watch                                │
│  .repowise/          (per-repo index)                          │
│  .repowise-workspace/ (multi-repo contracts, system graph)     │
│  MCP server: repowise mcp                                      │
├─────────────────────────────────────────────────────────────────┤
│                    Code Repos                                    │
└─────────────────────────────────────────────────────────────────┘
```

### Data flow

```
speccraft init
    │
    ├─► seed0.py --config .speccraft/kbforge.yaml
    │       │
    │       ├─► repowise inspect --json (dependency graph)
    │       ├─► repowise health --json (code health scores)
    │       ├─► repowise workspace diagnostics --json (cross-repo)
    │       └─► writes .speccraft/kb/derived/inventory.md
    │
    └─► repowise init (or repowise init . for workspace)
            │
            ├─► builds .repowise/ (or .repowise-workspace/)
            ├─► installs hooks (post-commit → repowise update)
            └─► registers MCP server (repowise mcp)
```

---

## speccraft init — Repowise integration

### Behavior

```bash
speccraft init [repo-path]
```

1. Runs `kbforge-init.sh` as today (scaffold .speccraft/, install hooks/skills)
2. **New**: runs `repowise init` (single repo) or `repowise init .` (workspace) inside the repo
   - Uses `--no-prose -y` by default (free, no API key, no questions)
   - User can pass `--prose` to enable LLM-written wiki pages
3. The kbforge.yaml is extended with a `repowise:` block:
   ```yaml
   repowise:
     enabled: true
     workspace: false          # true if multi-repo workspace
     prose: false              # true = LLM-written wiki (costs $)
     provider: ""              # anthropic|openai|gemini (empty = no-prose)
     health_threshold: 5       # files below this flagged in drift
   ```

### What the user sees

```
$ speccraft init my-project
Initializing speccraft in my-project...
✓ Scaffolded .speccraft/
✓ Installed git hooks
✓ Installed skills and commands
✓ Running repowise init --no-prose -y...
  Scanning repo...
  Parsing 2,847 files across 3 languages...
  Building dependency graph...
  Mining git history (6 months)...
  Computing code health scores...
  Generating wiki from structure...
  ✓ Index complete in 23s
✓ speccraft init complete
```

---

## KB seeding — seed0.py enhanced with Repowise data

### Current seed0.py output

- `kb/derived/inventory.md` — routes, models, tests, churn, modules
- Basic file listing and symbol extraction

### New seed0.py output (extends existing)

```markdown
# kb/derived/inventory.md (extended)

## Dependency Graph (from Repowise)
- File nodes: 2,847
- Symbol nodes: 18,342
- Call edges: 47,291 (resolved)
- Communities (Leiden): 23 modules
- Entry points: 12 (api/server.ts, cli/index.ts, workers/*)

## Git Intelligence (from Repowise)
- Hotspots (top 25% churn × complexity): 71 files
- Ownership silos (>80% single author): 14 files
- Co-change pairs: 312 cross-file correlations
- Bug history: 89 files with fixes in last 6 months
- Bus factor risk: 3 files owned by departed contributors

## Code Health (from Repowise)
- Overall health: 6.2/10
- Files ≤ 5 (review recommended): 234
- Refactoring targets (ranked):
  1. payments/processor.ts — Extract Class (LCOM4=0.21), blast radius 23 files
  2. shared/events/EventBus.ts — Break Cycle, blast radius 41 files
  3. auth/session.ts — Split File, blast radius 12 files

## Cross-Repo Contracts (workspace mode only)
- HTTP contracts: 47 provider/consumer pairs
- gRPC contracts: 12 service/method pairs
- Breaking changes since last index: 0
- Architecture conformance: 0 violations, 0 cycles
```

### Implementation

`seed0.py` calls Repowise CLI and parses JSON:

```python
# seed0.py additions
def collect_repowise_data(kb_root: Path, repo: Path) -> dict:
    # Dependency graph summary
    graph = json.loads(subprocess.run(
        ["repowise", "inspect", "--json"], cwd=repo, capture_output=True
    ).stdout)
    
    # Code health summary
    health = json.loads(subprocess.run(
        ["repowise", "health", "--json"], cwd=repo, capture_output=True
    ).stdout)
    
    # Git intelligence summary
    git_intel = json.loads(subprocess.run(
        ["repowise", "git", "intelligence", "--json"], cwd=repo, capture_output=True
    ).stdout)
    
    # Cross-repo (workspace mode)
    cross_repo = {}
    if is_workspace(repo):
        cross_repo = json.loads(subprocess.run(
            ["repowise", "workspace", "diagnostics", "--json"], cwd=repo, capture_output=True
        ).stdout)
    
    return {**graph, **health, **git_intel, **cross_repo}
```

---

## Drift detection — drift.py uses Repowise change risk

### Current drift.py

- Subtractive drift: cited lines changed
- Additive drift: new integration/assumption surface in diff
- Anchor scope drift: new files under existing anchors

### Enhanced drift.py

Adds **Repowise change risk** as a fourth signal:

```bash
$ python3 drift.py --config .speccraft/kbforge.yaml --queue

ANCHOR SCOPE drift — new files added under anchored paths since pin:
  kb/inferred/06-integrations.md  (anchor: backend/):
    + backend/workers/notify-webhook.py

REPOWISE CHANGE RISK — diff risk score 7.3/10 (90th percentile vs recent commits):
  Directive: will_break
  Missing co-changes: payments/processor.ts, shared/events/EventBus.ts
  Missing tests: payments/processor.ts (0% coverage on new logic)
  Tests to run: pytest tests/payments/ tests/shared/events/
  Impacted consumers: frontend/src/api/payments.ts, mobile/src/services/billing.ts
```

### Implementation

```python
# drift.py additions
def repowise_change_risk(kb_root: Path, repo: Path, base: str, head: str) -> dict:
    # For uncommitted changes, write a temp diff and use risk API
    diff = subprocess.run(
        ["git", "diff", f"{base}..{head}"], cwd=repo, capture_output=True, text=True
    ).stdout
    
    # Write diff to temp file, call repowise risk
    with tempfile.NamedTemporaryFile(mode='w', suffix='.diff') as f:
        f.write(diff)
        f.flush()
        result = subprocess.run(
            ["repowise", "risk", "--diff", f.name, "--json"], cwd=repo, capture_output=True
        )
    
    return json.loads(result.stdout)
```

**For PR mode (Mission Control):**

```bash
repowise risk --diff main..feature/auth --json
# Returns:
# {
#   "score": 7.3,
#   "percentile": 90,
#   "directive": "will_break",
#   "missing_cochanges": ["payments/processor.ts"],
#   "missing_tests": ["payments/processor.ts"],
#   "tests_to_run": ["pytest tests/payments/"],
#   "impacted_consumers": ["frontend/src/api/payments.ts"]
# }
```

---

## Cross-repo contracts — replaces the unbuilt concept registry

### Problem (from `20-field-validation-gaps.md`)

> **Second, genuinely unbuilt everywhere: checking consistency across repos.**
> `18-first-principles-intent.md` proposes a concept registry — canonical domain
> concepts mapped to every place they're implemented, so two repos that implement
> the same concept with different rules get flagged automatically.

### Repowise solution

Repowise workspaces already do this via **contract extraction** and **system graph**:

1. **HTTP/gRPC/topic contracts** are extracted from both producer and consumer repos
2. **Contracts are matched** across repos — provider ↔ consumer links
3. **Breaking-change guard** diffs contracts on every update, flags incompatible changes
4. **Architecture conformance** declares allowed dependencies, lints against them
5. **Co-change detection** finds hidden coupling across repos

### Integration

When `speccraft init` detects a workspace (`.repowise-workspace.yaml` exists or multiple repos under a parent):

1. Runs `repowise init .` for the workspace
2. The workspace config (`.repowise-workspace.yaml`) becomes the **contract registry**
3. `drift.py` and Mission Control query workspace APIs:

```bash
# Cross-repo blast radius
repowise workspace blast-radius --target backend::api --json

# Breaking changes
repowise workspace breaking-changes --json

# Conformance violations
repowise workspace check --json
```

### Mission Control integration

The cloud Mission Control dashboard gets a **Contracts tab** showing:
- System graph (live diagram of services and dependencies)
- Contract view (all provider/consumer pairs, filterable)
- Breaking changes (history of incompatible changes)
- Conformance (dependency matrix with violations)

---

## Decision intelligence — feeds the KB

### Repowise mines decisions from 8 sources

1. ADR files (Nygard/MADR format)
2. CHANGELOG entries
3. PR and squash-commit bodies
4. Inline markers (`# WHY:`, `# DECISION:`, `# TRADEOFF:`)
5. Git archaeology (significant commits per file)
6. README/docs
7. Centrality-bounded code comments
8. LLM doc-generation pass

Each decision is:
- **Evidence-backed** — verbatim source spans
- **Confidence-scored** — exact / fuzzy / unverified
- **Linked to graph nodes** — the code it governs
- **Tracked for staleness** — flags when governed code changes

### Integration with speccraft KB — evidence feeder, never ratifier

Mined decisions are machine-extracted, however evidence-backed — so they
enter the KB the way every other observation does: **graded, below
normative, awaiting the founder.** Rev 1 of this spec wrote them "to
kb/decisions/ or kb/normative/ based on confidence" — that is
self-ratification by sidecar, it violates the system's one non-negotiable
rule (*trust rises only through the founder*), and the lane guard would
block the normative write at runtime anyway. The corrected flow:

- All synced decisions land in `kb/decisions/repowise-mined.md` with
  `status: pending-ratification` (Repowise `exact` confidence) or
  `status: observed` (`fuzzy` / `unverified`). **Never normative, at any
  confidence.**
- Repowise's evidence spans, governed nodes, and staleness flag ride along
  as the fact's evidence block — this is what makes these high-quality
  ratification candidates.
- Promotion to `kb/normative/` happens exactly one way: `speccraft-ratify`.
  Repowise shortens the founder's path to a decision; it never takes the
  decision.

```
# .speccraft/kb/decisions/repowise-mined.md  (session-writable lane)

## DEC-R847: All external API calls wrapped in CircuitBreaker
- status: pending-ratification        # exact-confidence mined decision
- Source: Repowise decision (PR #847, commit a1b2c3d4)
- Evidence: "after payment provider outages in Q3 2024"
- Governs: shared/http/client.ts (PageRank 0.87)
- Staleness: 3 of 14 governed files changed since recorded
- Ratify → kb/normative/01-invariants.md as INV-candidate
```

### Implementation

```python
# New: decision sync in seed0.py or post-commit
def sync_repowise_decisions(kb_root: Path, repo: Path) -> list:
    result = subprocess.run(
        ["repowise", "decision", "list", "--json"], cwd=repo, capture_output=True
    )
    decisions = json.loads(result.stdout)

    STATUS = {"exact": "pending-ratification"}  # fuzzy/unverified → observed
    for d in decisions:
        fact = {
            "id": f"DEC-R{d['id']}",
            "statement": d["summary"],
            "status": STATUS.get(d["confidence"], "observed"),
            "evidence": d["evidence_spans"],
            "confidence": d["confidence"],  # exact/fuzzy/unverified
            "governs": d["governed_nodes"],
            "stale": d["staleness_flag"]
        }
        write_kb_fact(fact, lane="decisions")   # never normative

    # exact-confidence facts also queue for ratification (one digest item
    # per sync run, not one per decision — founder-queue discipline)
```

Sync is idempotent (keyed on `DEC-R<id>`); re-syncs update evidence and
staleness on existing entries, never status — status changes belong to the
founder (upward) and the trust-decay mechanism (downward).

---

## Agent context — Repowise hooks + MCP tools

### Current speccraft hooks

- `kb-briefing.sh` — SessionStart, injects KB summary
- `kb-guard.sh` — PreToolUse, lane guard
- `kb-recall-gate.sh` — PreToolUse, deny-once on normative-anchored files
  (recall-gate spec)
- `kb-recall-post.sh` — PostToolUse, capture-on-contact recall
- `kb-status.sh` — regenerates KB-STATUS.md

### No new hook — Repowise context rides inside recall (rev 2)

Rev 1 proposed a fourth hook on `Edit|Write|MultiEdit`
(`kb-repowise-pre.sh`). Dropped, for three reasons:

1. **It was technically wrong**: it read the file path from `$1` (hooks
   receive JSON on stdin) and echoed plain text (PreToolUse context must go
   through `hookSpecificOutput.additionalContext` — the recall-gate spec
   learned this the hard way).
2. **The matcher is already carrying three hooks.** A fourth process spawn
   plus a sidecar round-trip on every edit is real per-edit latency.
3. **Recall is the injection channel by design.** One channel, one dedup
   cache, one timing story.

Instead, `recall.py` gains an optional Repowise enrichment: when
`repowise.enabled` and the sidecar answers within a **500 ms timeout**,
append a compact context block to the recall output for the target file —
summary, hotspot flag, health score, caller/callee counts, owner, count of
governing mined decisions. Timeout or absent sidecar → recall output
unchanged (ground rule 1); a `repowise: unavailable` line appears at most
once per session. The existing per-session-per-file dedup cache already
prevents repeat lookups. Every existing recall consumer — the post hook,
the recall gate's deny reason, CLI/prompt-driven recall in OpenCode/Codex —
inherits the enrichment with zero new moving parts.

### MCP tools available to agents

When `repowise init` runs, it registers the MCP server. Agents (Claude Code, Codex, OpenCode) get 10 tools:

| Tool | Use in speccraft workflow |
|---|---|
| `get_overview()` | Session briefing — architecture summary |
| `get_context(targets)` | Pre-edit — file/module triage, hotspot warning |
| `get_risk(targets, changed_files)` | Pre-commit — change risk, missing co-changes/tests |
| `get_blast_radius(target)` | Cross-repo impact before editing a provider |
| `get_health(targets, include=["refactoring"])` | Health check, concrete refactoring plans |
| `get_why(query, targets)` | Why is this code structured this way? |
| `get_change_risk(revspec)` | PR review — diff risk score |
| `get_symbol("file::Name")` | Exact symbol source, cheaper than Read |
| `search_codebase(query)` | Semantic search over wiki |
| `get_dead_code()` | Cleanup candidates |

---

## Auto-sync — keeping Repowise current

### speccraft post-commit hook

```bash
# .speccraft/session-kit/post-commit (enhanced)

# ... existing ship loop (drift.py, deps0.py, recall.py) ...

# New: update Repowise index
if [ -f ".repowise/config.yaml" ] || [ -f ".repowise-workspace.yaml" ]; then
  # background, incremental, ~seconds — but never silent: log output, and
  # stamp .repowise/last-update so staleness is detectable
  repowise update >> .speccraft/evals/repowise-update.log 2>&1 &
fi
```

### Watch mode (optional, for active development)

```bash
# Developer runs in background
repowise watch --workspace &
# Or single repo
repowise watch &
```

### Webhook (team/cloud)

GitHub/GitLab webhook calls `repowise update --workspace` on push.

---

## Mission Control dashboard — Repowise views

The cloud Mission Control (from `2026-07-25-mission-control-cloud.md`) embeds Repowise data:

### Per-repo health card (extends existing)

```
┌─────────────────────────────────────────────────────┐
│ my-app                        ● 78% recall  2 blocks│
│ ┌─────────────────────────────────────────────────┐ │
│ │ Health: 6.2/10  ▼ 3 files ≤ 5                   │ │
│ │ Hotspots: 71 files  │  Silos: 14  │ Bugs: 89    │ │
│ │ Refactor targets: 23  │  Declining: 5           │ │
│ └─────────────────────────────────────────────────┘ │
│ Contracts: 47 HTTP  │  12 gRPC  │  0 breaking       │
└─────────────────────────────────────────────────────┘
```

### Workspace Contracts tab (new)

- System graph (live, zoomable)
- Contract list (provider/consumer, type, confidence)
- Breaking changes history
- Conformance matrix (DSM view)

### Architecture metrics panel

- Propagation cost (coupling %)
- Cyclic core size
- Architecture score 1-10
- Service roles (core/shared/control/peripheral)

---

## Configuration

### kbforge.yaml additions

```yaml
repowise:
  enabled: true
  workspace: false
  prose: false
  provider: ""              # anthropic|openai|gemini (for prose mode)
  health_threshold: 5       # drift flags files below this
  sync_decisions: true      # sync mined decisions to kb/decisions/ (graded)
  repowise_min_version: ""  # pinned by the capability audit
  recall_enrich: true       # recall.py appends Repowise context (500ms timeout)
  mcp:
    register: true          # register MCP server on init
```

### Workspace config (.repowise-workspace.yaml)

Managed by Repowise, but speccraft reads it for cross-repo awareness:

```yaml
repos:
  - path: backend
    alias: api
    tags: [service, backend]
  - path: frontend
    alias: web
    tags: [ui, edge]
  - path: shared-libs
    alias: shared
    tags: [library]

conformance:
  rules:
    - source: web
      target: shared
      allow: true
    - source: web
      target: api
      allow: true
    - source: "*"
      target: shared
      allow: true  # shared is a library, can be depended on

contracts:
  detect_http: true
  detect_grpc: true
  detect_topics: true
  detect_data: true
  service_bases:
    API_BASE: api
```

---

## Out of scope

- Repowise UI customization (use `repowise serve` directly)
- LLM provider management (Repowise handles its own)
- Repowise commercial/enterprise features
- Repowise PR Bot (separate GitHub App)
- VS Code extension (separate install)
- Decision capture UI (`repowise decision add` is CLI-only)

---

## What this changes in earlier specs — augments, does not replace

Rev 1 said "replaces" and "supersedes" in places where the rev-2 spec pass
had already assigned precise ownership. Corrected:

- **`2026-07-25-stale-commit-guard.md` (rev 2)**: unchanged. The warning
  tier *may* additionally mention a stale Repowise index (from
  `.repowise/last-update`) — informational, never blocking.
- **`2026-07-25-anchor-scope-drift.md` (rev 2)**: **complements.** Anchor
  scope drift is prefix matching (no blast-radius heuristic exists there to
  replace). Repowise change risk arrives as an additional, clearly labeled
  drift section; anchor-scope findings remain the T2 judge-targeting
  source.
- **`2026-07-25-dep-diff.md` (rev 2)**: **deps0 stays authoritative** for
  version pinning and CVE advisories (Repowise does neither). Repowise adds
  the *dependency graph* dimension (who imports what, cross-repo) — a
  different axis, reported separately.
- **`2026-07-25-trust-decay.md`**: mined-decision sync respects it —
  Repowise staleness flags may feed the queue, but only deterministic
  drift evidence demotes.
- **`docs/agentic-sdlc/04-seeding-and-verification.md`**: seed0.py is
  enriched by Repowise data (with the coverage-gap fallback).
- **`docs/agentic-sdlc/03-drift-reconciler.md`**: drift.py gains Repowise
  risk scoring as a fourth signal (fallback: section absent).
- **`docs/agentic-sdlc/18-first-principles-intent.md`**: cross-repo concept
  registry served by workspace contracts.
- **`2026-07-25-mission-control-cloud.md` (rev 2)**: Mission Control embeds
  Repowise views; the earned-autonomy blast-radius gate uses Repowise when
  present, the conservative files-changed fallback otherwise.
- **`docs/agentic-sdlc/17-multi-org-multi-product.md`**: workspaces are
  per-cell; Repowise runs in-cell.