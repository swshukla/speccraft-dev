<div align="center">

# Speccraft

**A trust-graded knowledge base your codebase carries with it —**
**so agents (and you) build on what's *ratified as true*, not on guesses.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](kb-forge/LICENSE)
[![Python 3.9+](https://img.shields.io/badge/python-3.9%2B-blue.svg)](kb-forge/pyproject.toml)
[![No LLM required](https://img.shields.io/badge/harvesters-pure%20stdlib-green.svg)](#getting-started)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-supported-6b46c1.svg)](#multi-tool)
[![Codex](https://img.shields.io/badge/Codex-supported-10a37f.svg)](#multi-tool)
[![OpenCode](https://img.shields.io/badge/OpenCode-supported-f97316.svg)](#multi-tool)

</div>

---

Speccraft turns a repo's scattered, half-lost knowledge — intent, invariants, the reasons behind decisions, the gotchas in your dependencies, the bugs nobody wrote down — into a cited, versioned, human-ratified knowledge base that lives *inside the repo* (`.speccraft/`) and stays honest as the code changes.

It's built for the hard case — an **existing (brownfield) codebase** whose design rationale has already evaporated — worked by AI coding sessions across **Claude Code, Codex, and OpenCode**. Every greenfield project is a brownfield project in six months; run it from day one and there's nothing to reconstruct later.

<div align="center">

*Cite or it didn't happen. Nothing becomes truth except through a human.*

</div>

> **This repo is `speccraft-dev`** — the private development monorepo. The published package (`pip install speccraft-cli`) is built from [`kb-forge/`](kb-forge/) alone. Everything above the divider is how to *use* Speccraft; everything below it is how to *work on it*. See [Repository topology](#repository-topology-read-this-first).

---

## Contents

**Using Speccraft**

- [Why it exists](#why-it-exists)
- [Getting started](#getting-started)
- [What gets checked in](#what-gets-checked-in)
- [The commands](#the-commands)
- [What it captures](#what-it-captures)
- [The steady-state loop](#the-steady-state-loop)
- [Enforcement](#enforcement)
- [The KB layout](#the-kb-layout)
- [Multi-tool](#multi-tool)

**Developing Speccraft**

- [Repository topology](#repository-topology-read-this-first)
- [Repo layout](#repo-layout)
- [Working in this repo](#working-in-this-repo)
- [Releasing](#releasing)
- [Roadmap](#roadmap)
- [License](#license)

---

## Why it exists

Every codebase knows things nobody wrote down: why a constant is `30`, which alternative was rejected, that lapsed users still get paid features, that this dependency version has a known CVE. Code records the *outcome* of a decision, never the decision. AI agents, lacking that context, confidently repeat known mistakes and drift from intent.

Speccraft's answer is a **grounded ratchet**: seed a knowledge base from human-adjudicated truth, validate every change against it, and let error be *caught* rather than compound.

<table>
<tr><td width="30"><b>1</b></td><td><b>Cite or it didn't happen</b><br/>Every claim is pinned to <code>path:line @&lt;commit-sha&gt;</code>.</td></tr>
<tr><td><b>2</b></td><td><b>Provenance is never blurred</b><br/>Each fact is tagged by <i>how it's known</i>: <code>derived</code> (machine-harvested), <code>inferred</code> (agent hypothesis), <code>elicited</code> (your own words), <code>decision</code> (an ADR), <code>external</code> (dependency knowledge, sub-graded by source).</td></tr>
<tr><td><b>3</b></td><td><b>Nothing becomes <code>ratified</code> except through a human</b><br/>Agents propose; you rule. A fact's trust state moves <code>pending → ratified → challenged</code>, never silently.</td></tr>
<tr><td><b>4</b></td><td><b>Deterministic before generative</b><br/>Anything a regex or git can harvest is harvested by a no-LLM tool that <i>cannot hallucinate</i>; agents only interpret, and their output enters as an unratified hypothesis.</td></tr>
</table>

---

## Getting started

### 1. Install the CLI

```bash
pipx install speccraft-cli     # or: pip install --user speccraft-cli
speccraft --help
```

> **Requirements:** `python3` ≥ 3.9 and `git`. `jq` is used only to merge Claude Code hook settings into a `.claude/settings.local.json` you already have. No API keys, no services, no LLM calls in the tooling itself — the harvesters are pure stdlib, and speccraft has zero runtime dependencies.

> Want unreleased `main`? `pipx install git+https://github.com/swshukla/speccraft.git` instead.

Upgrading later is `pipx upgrade speccraft-cli`. The CLI is a thin launcher: the substance lives in a `forge/` tree inside the installed package, and `speccraft init` points `~/.speccraft/kb-forge` at it via a symlink so your repo's hooks and skills always resolve to the version you have installed.

### 2. Initialize your repo

```bash
cd /path/to/your-repo
speccraft init            # or: speccraft init /path/to/your-repo
```

The target **must be a git repo with at least one commit** — the knowledge base pins every claim to a commit SHA, so there has to be something to pin to. On a brand-new project, commit your starter code first:

```bash
git init && git add -A && git commit -m "init: snapshot before speccraft"
```

`init` is **idempotent** — re-running it on a repo that already has `.speccraft/` re-runs the harvesters and re-arms this clone without touching your ratified facts. It never overwrites a git hook or hook-settings block it didn't write; it prints a warning and asks you to merge by hand instead.

What it does, in order:

| | |
|---|---|
| **Scaffolds the KB** | `.speccraft/` with `kbforge.yaml` (the product profile), `QUEUE.md` (the single adjudication queue), and the `kb/derived`, `kb/inferred`, `kb/normative`, `kb/decisions`, `ledger/` lanes. |
| **Harvests ground truth** | Runs `seed0` (structure/routes/models/churn), `assume0` (assumption "scars"), `dup0` (duplication & contradictions), `deps0` (dependency inventory) into `kb/derived/`, all pinned to your current `HEAD`. |
| **Installs the procedures** | The seven `speccraft-*` skills into `.claude/skills/` (Claude Code), `.agents/skills/` (Codex + OpenCode, via the Agent Skills standard), and `.opencode/commands/`; plus `~/.codex/prompts/` once per machine. |
| **Wires the agent context** | Appends the KB section to `AGENTS.md` and ensures `CLAUDE.md` imports it with `@AGENTS.md`. |
| **Arms this clone** | Hook config into `.claude/settings.local.json`, and `pre-commit` / `post-commit` into `.git/hooks/`. |
| **Writes status** | `.speccraft/KB-STATUS.md`, the at-a-glance briefing every new agent session reads. |

If the [superpowers](https://github.com/anthropics/claude-plugins-official) plugin isn't detected, `init` says so — speccraft's skills assume that workflow discipline (brainstorming, TDD, systematic-debugging) is available, but nothing breaks without it.

### 3. Tune the profile, then commit

Open `.speccraft/kbforge.yaml` and set the two fields marked `EDIT ME`:

```yaml
components: backend, frontend          # rough hints; the harvesters are heuristic
test_command: "pytest"
risk_paths: "auth|login|session|token|payment|billing|subscri"   # paths that deserve paranoia
```

Then commit the KB and the procedures — see [What gets checked in](#what-gets-checked-in):

```bash
git add .speccraft .claude/skills .agents .opencode AGENTS.md CLAUDE.md .gitignore
git commit -m "chore: bootstrap speccraft KB"
```

### 4. Bootstrap the knowledge (the human-paced part)

Steps 1–3 are mechanical. What follows is the part only you can do, in an agent session (Claude Code, Codex, or OpenCode) opened on the repo:

| Step | Action |
|:---:|---|
| 1 | Run **`speccraft-interview`** — the one irreducibly human step. Intent and invariants land in `kb/normative/` in your own words, and everything downstream grounds in them. |
| 2 | Run the extraction passes (capability map, data sources, integrations, assumptions, consistency) → `kb/inferred/` as *unratified hypotheses*. |
| 3 | Work through `.speccraft/QUEUE.md` with **`speccraft-ratify`**. Nothing becomes ratified truth except here, by you. |
| 4 | **It's self-sustaining after that.** Just build — each commit runs the ship loop, drift keeps citations honest, `speccraft-recall` grounds each task. |

### Joining a repo that already has a KB

Skills, `AGENTS.md` and the KB itself are tracked, so they arrive with the clone. Git hooks and `settings.local.json` are *not* versioned by git — every new clone (and every new machine) has to arm itself:

```bash
pipx install speccraft-cli
cd the-repo && speccraft init .        # detects the existing KB, installs hooks only
```

**Go deeper:** [`kb-forge/speccraft/forge/README.md`](kb-forge/speccraft/forge/README.md) (full walkthrough) · [`kb-forge/speccraft/forge/SPEC.md`](kb-forge/speccraft/forge/SPEC.md) (system reference) · [`kb-forge/speccraft/forge/workflow-execution.html`](kb-forge/speccraft/forge/workflow-execution.html) (visual tour)

---

## What gets checked in

**Yes — commit `.speccraft/`.** The knowledge base is the point: it's versioned truth that travels with the code, reviewable in pull requests, and pinned to the same history. A KB outside the repo would drift the moment someone else pushed.

| Path | Commit it? | Why |
|---|:---:|---|
| `.speccraft/` (KB, queue, ledger, decisions) | **yes** | The knowledge base. Its diffs are the audit record of what was ratified, when, by whom. |
| `.claude/skills/`, `.agents/skills/`, `.opencode/commands/` | **yes** | The `speccraft-*` procedures. Tracking them means teammates and CI agents get the same behavior. |
| `AGENTS.md`, `CLAUDE.md` | **yes** | Cross-agent rules that point sessions at the KB. |
| `.gitignore` (one added line) | **yes** | Excludes the telemetry log below. |
| `.speccraft/evals/telemetry.jsonl` | no — auto-ignored | Per-machine usage log; `init` adds it to `.gitignore` for you. |
| `.claude/settings.local.json` | no | Per-clone hook wiring, machine-specific by convention. |
| `.git/hooks/pre-commit`, `post-commit` | can't | Git never versions hooks. Re-run `speccraft init .` per clone. |
| `~/.speccraft/kb-forge`, `~/.codex/prompts/` | n/a | Outside the repo — created per machine by `init`. |

The `post-commit` ship loop makes its own `kb: ship-loop re-pin @<sha>` commits touching only `.speccraft/`. That's expected: it re-pins citations, flags drift, and refreshes `KB-STATUS.md` after each of your commits. It is guarded against recursion, skips linked worktrees, and never blocks you — it runs in the background.

---

## The commands

The CLI itself has exactly one subcommand — everything else is a **procedure your agent runs**, installed by `init` and invoked by name in a session.

```
speccraft init [repo]     scaffold / re-arm a .speccraft/ KB   (default repo: .)
```

In Claude Code the skills fire by name (or automatically, when their description matches what you're doing). In Codex and OpenCode, `/speccraft-<name>`.

| Procedure | When to run it |
|---|---|
| **`speccraft-recall`** | **Before touching any module**, and before adding an integration or data fetch. Pulls the trust-graded facts governing the code you're about to change. This is the one you'll use every session. |
| **`speccraft-decide`** | The moment you make a tradeoff — fixing a threshold, rejecting an alternative, picking a library. Writes an ADR-lite card to `kb/decisions/`, append-only. |
| **`speccraft-diverge`** | When the task requires contradicting a ratified fact or `INV-*` invariant — or when you find code that already does. Stops and files it for your ruling instead of proceeding silently. |
| **`speccraft-interview`** | Bootstrapping the KB, and again whenever product direction shifts. Elicits intent and invariants from you; no code scan can produce these. |
| **`speccraft-ratify`** | *Founder-only.* Walk `QUEUE.md` and rule on items one at a time. The commit is the audit record. |
| **`speccraft-prove`** | When someone asks you to prove one named invariant still holds. Re-verifies against current code and renders a cited proof — or refuses and files a divergence if the code contradicts it. |
| **`speccraft-eval`** | *Founder-only.* Check whether the system is actually working: loop usage, KB truth, behavioral lift. |

Day to day, the shape is: **recall → build → decide/diverge as they come up → commit** (the ship loop handles re-pinning), with **ratify** occasionally when the queue fills up.

---

## What it captures

| Aspect | How | Provenance |
|---|---|:---:|
| Structure — routes, models, tests, churn, module map | deterministic harvest | `derived` |
| Product intent, stage, monetization | founder interview | `elicited` |
| Invariants (the rules that must always hold) | founder interview | `elicited` |
| Capability map — what's marketed vs what the code does | agent extraction | `inferred` |
| Data sources — what data already flows in | agent extraction | `inferred` |
| Integrations — why each 3rd-party exists, what's used, who depends on what | agent extraction | `inferred` |
| Assumptions & tradeoffs — recovered from code "scars" | residue harvest → hypothesis cards | `derived` + `inferred` |
| Consistency — contradictions, duplicates, proposed conventions | harvest + classify | `derived` + `inferred` |
| Dependencies + version-pinned best-practices / gotchas | inventory + **sourced** cards | `derived` + `external` |
| Decisions — captured at the moment a tradeoff is made | ADR-lite lane | `decision` |
| Findings — the consolidated bug / work list | flows from rulings | mixed |

---

## The steady-state loop

```
 session start
      │
      ▼
 speccraft-recall ─── ground in ratified truth
      │
      ▼
   build  ───────────  speccraft-decide (log tradeoffs)
      │                speccraft-diverge (on conflict)
      ▼
 git commit ─── pre-commit lane guard
      │
      ▼
 ship loop: drift → re-pin → re-harvest → kb: commit → KB-STATUS refresh
      │
      ▼
 speccraft-ratify ─── founder rules the queue, occasionally
      │
      ▼
 feeds the next session
```

---

## Enforcement

A git **pre-commit** hook keeps machine-proposed and human-ratified knowledge distinguishable: commits touching the founder/machine lanes (`kb/normative/`, `kb/derived/`, `ledger/`) require an explicit flag — `KB_RATIFY=1` (a human ruling) or `KB_SHIPLOOP=1` (the automatic re-pin).

It's not a lock against an intruder — you own the repo — it's a **signature**: when a fact is ratified, the git history shows a human stood behind it, so an agent can run autonomously without quietly promoting its own guesses to truth. A **post-commit** hook runs the ship loop on every code commit.

Sessions write only `QUEUE.md`, `kb/decisions/`, `kb/inferred/`, and `proposed` rows in `findings/`. Everything else is founder/machine.

---

## The KB layout

```
your-repo/.speccraft/
├── kbforge.yaml       product profile: repo, components, risk_paths
├── KB-STATUS.md       auto-refreshed briefing (pin, open queue, invariants)
├── QUEUE.md           the one adjudication queue — rulings are git commits
├── kb/
│   ├── derived/       machine-harvested, regenerated each commit (never hand-edited)
│   ├── inferred/      agent hypotheses (pending-ratification)
│   ├── normative/     ratified intent, invariants, conventions (human-only)
│   └── decisions/     ADR-lite, captured at decision time (append-only)
├── ledger/DIV-*.md    ruled divergences (fix-code / fix-model / accepted-deviation)
└── findings/FINDINGS.md   the consolidated bug / work list
```

---

## Multi-tool

One source, three runtimes.

| | Claude Code | Codex | OpenCode |
|---|:---:|:---:|:---:|
| Rules file | `CLAUDE.md` (imports `AGENTS.md`) | `AGENTS.md` | `AGENTS.md` |
| Procedures | `.claude/skills/` | Agent Skills standard | OpenCode commands |
| Git hooks | identical | identical | identical |

The git hooks enforce identically regardless of which tool — or which human — makes the commit.

---

# Developing Speccraft

Everything from here down is about working on Speccraft itself — repo topology, the dev loop, and how a release reaches PyPI.

---

## Repository topology (read this first)

There are **two GitHub repos**, and they are related in a way that is easy to get wrong:

| Repo | Remote | Role |
|---|---|---|
| **`speccraft-dev`** (this repo) | `origin` → `swshukla/speccraft-dev` (private) | The dev monorepo. Everything lives here: the package source, docs, roadmaps, specs, the publish tooling. |
| **`speccraft`** (package target) | `speccraft` → `swshukla/speccraft` (public) | Package-only. This is what PyPI builds from (`speccraft-cli`). It contains **only** a snapshot of `kb-forge/`. |

**The two repos share no git history.** Publishing is therefore *not* a `git push` between them — it's a **snapshot-on-top-of-tip + tag**: [`publish.sh`](publish.sh) copies the current `kb-forge/` tree onto the package repo's latest commit and pushes a `vX.Y.Z` tag, which triggers the PyPI workflow. See [Releasing](#releasing).

```
 this repo (speccraft-dev)              package repo (speccraft)            PyPI
 ┌───────────────────────┐  publish.sh  ┌──────────────────────┐  tag CI  ┌──────────────┐
 │ kb-forge/  ───────────┼─ snapshot ──▶│ (kb-forge/ contents) │ ───────▶ │ speccraft-cli│
 │ docs/  roadmaps/ …    │  + tag vX.Y.Z│  = the pip package    │          │  X.Y.Z        │
 └───────────────────────┘              └──────────────────────┘          └──────────────┘
```

---

## Repo layout

```
speccraft-dev/
├── kb-forge/            ← THE PACKAGE (published to PyPI as speccraft-cli)
│   ├── README.md            product README (ships to PyPI)
│   ├── pyproject.toml       package metadata + version (bumped by publish.sh)
│   ├── speccraft/
│   │   ├── cli.py           `speccraft` entrypoint (init, …)
│   │   └── forge/           the engine — see below
│   └── .github/workflows/   the PyPI publish workflow (runs on tag in the package repo)
├── docs/
│   ├── agentic-sdlc/        strategy / thesis docs
│   ├── roadmaps/            forward plans (e.g. drift-prevention roadmap)
│   └── superpowers/         specs, plans, reviews (brainstorm → plan → execute artifacts)
├── site/                    marketing site
├── publish.sh              snapshot kb-forge/ → package repo + tag (the release tool)
└── whiteboard-notes.md      scratch
```

### Inside `kb-forge/speccraft/forge/`

The engine. Pure-stdlib, no LLM calls in the tooling itself.

| Area | Files |
|---|---|
| **Harvesters** (deterministic, no-LLM) | `seed0.py` (structure), `assume0.py` (assumption residue), `dup0.py` (duplication), `deps0.py` (dependencies + advisories) |
| **Drift & hygiene** | `drift.py` (subtractive/additive/anchor drift → `SIGNALS.md`), `dep-diff.py`, `decay.py`, `signals.py` (the mechanical-lane projection), `migrate_split_queue.py` |
| **Recall / grounding** | `recall.py` |
| **Session kit** | `session-kit/skills/` (the `speccraft-*` procedures), `session-kit/hooks/` (git + SessionStart hooks), `session-kit/evals/` (the test suite) |
| **Reference** | `README.md` (walkthrough), `SPEC.md` (system reference) |

The `.speccraft/` KB layout that Speccraft *produces* in a target repo is documented above, under [The KB layout](#the-kb-layout).

---

## Working in this repo

**Requirements:** `python3` (3.9+), `git`. No API keys, no services — the harvesters and hooks are pure stdlib.

**Run the test suite** (bash-based eval harness, the source of truth for the engine):

```bash
bash kb-forge/speccraft/forge/session-kit/evals/self-test.sh        # full suite
bash kb-forge/speccraft/forge/session-kit/evals/test-queue-split.sh # focused: two-lane queue
```

`self-test.sh` builds hermetic fixture KBs, invokes the real CLIs, and asserts on file content. Green means the engine's behavior is intact — keep it green before publishing.

**Dev workflow.** Feature work here follows the brainstorm → spec → plan → execute loop (the [superpowers](https://github.com/obra/superpowers) skills), with artifacts landing in `docs/superpowers/{specs,plans,reviews}/`. Larger arcs are tracked in `docs/roadmaps/`.

**Try unreleased changes** without publishing:

```bash
pipx install git+https://github.com/swshukla/speccraft.git   # installs the package repo's main
# or run the engine directly against a KB:
python3 kb-forge/speccraft/forge/drift.py --config /path/to/.speccraft/kbforge.yaml --queue
```

---

## Releasing

`publish.sh` is the only supported path to PyPI. It requires a clean tree, a `speccraft` remote, and a semver version.

```bash
./publish.sh 0.3.0 --dry-run    # validate: bumps nothing on the remotes, pushes/tags NOTHING
./publish.sh 0.3.0              # real: bump kb-forge/pyproject.toml, commit to dev,
                                #       snapshot kb-forge/ → speccraft/main, push tag v0.3.0
                                #       (the tag triggers the PyPI publish workflow)
./publish.sh 0.3.0 --yes        # same, skips the interactive confirm (for automation)
```

What it does, in order: bump the version in `kb-forge/pyproject.toml` → commit `chore(release): …` to this repo → snapshot `kb-forge/` onto the package repo's tip → push + tag `vX.Y.Z` (fires the PyPI workflow) → push the dev bump to `origin`. It refuses to republish an existing tag.

**Always dry-run first**, and confirm the suite is green — a PyPI version is permanent.

---

## Roadmap

Active direction lives in [`docs/roadmaps/`](docs/roadmaps/). Current focus: the **drift-prevention roadmap** — a closed convergence loop (two-lane queue → forcing function → seam-aware recall → executable invariants). Phase 0 (the two-lane queue) shipped in `0.3.0`.

---

<div align="center">

## License

[MIT](kb-forge/LICENSE) — do what you like with it.

</div>
