# Speccraft

**A trust-graded knowledge base your codebase carries with it — so agents (and you) build on what's *ratified as true*, not on guesses.**

Speccraft turns a repo's scattered, half-lost knowledge — intent, invariants, the reasons behind decisions, the gotchas in your dependencies, the bugs nobody wrote down — into a cited, versioned, human-ratified knowledge base that lives *inside the repo* (`.speccraft/`) and stays honest as the code changes. `kb-forge` (this directory) is the toolkit that builds and maintains it.

It is designed for the hard case: an **existing (brownfield) codebase** whose design rationale has already evaporated, worked by AI coding sessions across **Claude Code, Codex, and OpenCode**. Every greenfield project is a brownfield project in six months — run it from day one and there's nothing to reconstruct later.

---

## Why it exists

Every codebase knows things nobody wrote down: why a constant is `30`, which alternative was rejected, that lapsed users still get paid features, that this dependency version has a known CVE. Code records the *outcome* of a decision, never the decision. AI agents, lacking that context, confidently repeat known mistakes and drift from intent.

Speccraft's answer is a **grounded ratchet**: seed a knowledge base from human-adjudicated truth, validate every change against it, and let error be *caught* rather than compound. The core discipline:

- **Cite or it didn't happen** — every claim is pinned to `path:line @<commit-sha>`.
- **Provenance is never blurred** — each fact is tagged by *how it's known*: `derived` (machine-harvested), `inferred` (agent hypothesis), `elicited` (your own words), `decision` (an ADR), `external` (dependency knowledge, sub-graded by source).
- **Nothing becomes `ratified` except through a human** — agents propose; you rule. A fact's trust state moves `pending → ratified → challenged`, never silently.
- **Deterministic before generative** — anything a regex or git can harvest is harvested by a no-LLM tool that *cannot hallucinate*; agents only interpret, and their output enters as an unratified hypothesis.

---

## What it captures

| Aspect | How | Provenance |
|---|---|---|
| Structure — routes, models, tests, churn, module map | deterministic harvest | derived |
| Product intent, stage, monetization | founder interview | elicited |
| Invariants (the rules that must always hold) | founder interview | elicited |
| Capability map — what's marketed vs what the code does | agent extraction | inferred |
| Data sources — what data already flows in | agent extraction | inferred |
| Integrations — why each 3rd-party exists, what's used, who depends on what | agent extraction | inferred |
| Assumptions & tradeoffs — recovered from code "scars" | residue harvest → hypothesis cards | derived + inferred |
| Consistency — contradictions, duplicates, proposed conventions | harvest + classify | derived + inferred |
| Dependencies + version-pinned best-practices / gotchas | inventory + **sourced** cards | derived + external |
| Decisions — captured at the moment a tradeoff is made | ADR-lite lane | decision |
| Findings — the consolidated bug / work list | flows from rulings | mixed |

---

## The tools (`kb-forge/`)

All are pure-stdlib Python (deps: **python3 + git**, optionally `ruff`). None call an LLM.

| Tool | Role |
|---|---|
| `seed0.py` | Harvest structure → `kb/derived/`, set the pin |
| `assume0.py` | Harvest decision residue (constants, swallowed excepts, reverts…) |
| `dup0.py` | Harvest duplicate / contradiction candidates + lint |
| `deps0.py` | Dependency inventory + security advisories |
| `drift.py` | Two-directional drift vs the pin (stale citations **and** new uncovered surface) + dependency-version drift |
| `recall.py` | Structural retrieval — the facts governing the files you're about to touch, in trust order |
| `kbforge-init.sh` | Scaffold + seed + install, end to end |
| `session-kit/install.sh` | Re-arm a fresh clone |

Agent passes (interview, extraction, confrontation) run as Claude Code / Codex / OpenCode sessions, reading the repo **only at the pin**, never your working tree.

---

## Setup

```bash
pipx install speccraft-cli                    # published release
# or, developing kb-forge itself:
pipx install -e /path/to/kb-forge            # editable, from this checkout
```
Installs the `speccraft` command and, on first `speccraft init`, links
`~/.speccraft/kb-forge` to the installed toolkit. Requirements: `python3`,
`git`. That's it — no API keys, no services.

## Using it on a repo

**1 — Bootstrap the mechanical layers (one command):**
```bash
speccraft init /path/to/your-repo
```
(equivalent to running `~/.speccraft/kb-forge/kbforge-init.sh /path/to/your-repo` directly, if you'd rather skip the pip install)
This scaffolds `your-repo/.speccraft/`, runs every harvester (pinned to your last code commit), installs the four `speccraft-*` procedures for all three tools, wires `AGENTS.md`/`CLAUDE.md`, arms the git + session hooks, and writes `KB-STATUS.md`.

**2 — Tune one file:** edit `.speccraft/kbforge.yaml` — set `components` and `risk_paths` (the auth / money / truth-critical path patterns). Commit the scaffold.

**3 — Do the judgment work in a Claude Code (or Codex/OpenCode) session:**
- **Interview** (`speccraft-interview`) → intent + invariants land in `kb/normative/` (`elicited`). This is the one irreducibly human step; everything downstream grounds in it. Do it first on a fresh KB.
- **Extraction passes** → capability map, data sources, integrations, dependency gotchas land in `kb/inferred/` as `pending-ratification`.
- **Confrontation batches** → answer the evidence-anchored questions in `.speccraft/QUEUE.md`; `speccraft-ratify` promotes facts to `ratified`, rules bugs into `findings/`.

**4 — Then it's self-sustaining.** Just build. Each commit runs the ship loop; drift keeps citations honest; recall grounds each task.

---

## The steady-state loop

```
session start → speccraft-recall (ground in ratified truth)
   → build → speccraft-decide (log tradeoffs) / speccraft-diverge (on conflict)
   → git commit  ─ pre-commit lane guard ─
   → ship loop: drift → re-pin → re-harvest → kb: commit → KB-STATUS refresh
   → speccraft-ratify (founder rules the queue, occasionally)
   → feeds the next session
```

**When a ship-loop step fails.** The loop is detached and logs to `$TMPDIR`, so
a broken step cannot reach your terminal. Every step's exit code is collected
and banners into `.speccraft/KB-STATUS.md` — committed, and injected into every
agent session at startup — with the per-step detail in the untracked
`.speccraft/.shiploop-failure.log`. The loop still re-pins and commits (the pin
must keep advancing), but a partially refreshed KB can no longer read as clean.
The banner clears itself on the next clean run. Two env vars:

- `KBFORGE_PYTHON` — interpreter for the forge steps. Defaults to the one
  speccraft was installed with, read off its console-script shebang. The forge
  never imports repo code, so this is independent of your project's Python; it
  wants the *newest* available, because an old one silently under-analyzes
  (`ast.parse` skips newer syntax, `tomllib` is absent before 3.11).
- `KB_SHIPLOOP_SYNC=1` — run the loop in the foreground instead of detached.
  For debugging a bad run and for the eval suite; commits never wait on it.

- **`speccraft-recall`** — before touching a module, pull its ratified facts, invariants, existing integrations, and known bugs (injected automatically on file-edit in Claude Code).
- **`speccraft-decide`** — record a tradeoff *at decision time*, so it's never lost to archaeology later.
- **`speccraft-diverge`** — never silently violate a ratified fact; file it for a ruling.
- **`speccraft-ratify`** — the founder ruling session; the only door into ratified truth.

---

## Enforcement — a provenance boundary, not a wall

A git **pre-commit** hook keeps machine-proposed and human-ratified knowledge distinguishable: commits touching the founder/machine lanes (`kb/normative/`, `kb/derived/`, `ledger/`) require an explicit flag — `KB_RATIFY=1` (a human ruling) or `KB_SHIPLOOP=1` (the automatic re-pin). This isn't a lock against an intruder — you own the repo — it's a *signature*: when a fact is ratified, the git history shows a human stood behind it, so an autonomous agent can run without quietly promoting its own guesses to truth. A **post-commit** hook runs the ship loop on every code commit.

**Write lanes:** sessions write only `QUEUE.md`, `kb/decisions/`, `kb/inferred/`, and `proposed` rows in `findings/`. Everything else is founder/machine.

---

## Layout (`your-repo/.speccraft/`)

```
kbforge.yaml       product profile: repo, components, risk_paths
KB-STATUS.md       auto-refreshed briefing (pin, open queue, invariants)
QUEUE.md           the one adjudication queue — rulings are git commits
kb/derived/        machine-harvested, regenerated each commit (never hand-edited)
kb/inferred/       agent hypotheses (pending-ratification)
kb/normative/      ratified intent, invariants, conventions (human-only)
kb/decisions/      ADR-lite, captured at decision time (append-only)
ledger/DIV-*.md    ruled divergences (fix-code / fix-model / accepted-deviation)
findings/FINDINGS.md   the consolidated bug / work list
```

---

## Multi-tool

One source, three runtimes. Rules live in `AGENTS.md` (Codex & OpenCode read it natively; `CLAUDE.md` imports it). The four procedures ship as Claude skills (`.claude/skills/`), the Agent Skills standard (`.agents/skills/`, read by Codex + OpenCode), and OpenCode commands. The git hooks enforce identically regardless of which tool — or which human — makes the commit.

---

## See also

- `SPEC.md` — the full system reference (design rules, drift semantics, fact lifecycle).
- `workflow-execution.html` — a visual walkthrough: installation, KB building, and the steady-state loop.
