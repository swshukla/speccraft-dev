<div align="center">

# Speccraft

**A trust-graded knowledge base your codebase carries with it —**
**so agents (and you) build on what's *ratified as true*, not on guesses.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Python 3.9+](https://img.shields.io/badge/python-3.9%2B-blue.svg)](pyproject.toml)
[![No LLM required](https://img.shields.io/badge/harvesters-pure%20stdlib-green.svg)](#quickstart)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-supported-6b46c1.svg)](#multi-tool)
[![Codex](https://img.shields.io/badge/Codex-supported-10a37f.svg)](#multi-tool)
[![OpenCode](https://img.shields.io/badge/OpenCode-supported-f97316.svg)](#multi-tool)

</div>

---

Speccraft turns a repo's scattered, half-lost knowledge — intent, invariants, the reasons behind decisions, the gotchas in your dependencies, the bugs nobody wrote down — into a cited, versioned, human-ratified knowledge base that lives *inside the repo* (`.speccraft/`) and stays honest as the code changes.

It's built for the hard case: an **existing (brownfield) codebase** whose design rationale has already evaporated, worked by AI coding sessions across **Claude Code, Codex, and OpenCode**.

<div align="center">

*Cite or it didn't happen. Nothing becomes truth except through a human.*

</div>

## Contents

- [Why it exists](#why-it-exists)
- [Quickstart](#quickstart)
- [What it captures](#what-it-captures)
- [The steady-state loop](#the-steady-state-loop)
- [Enforcement](#enforcement)
- [Layout](#layout)
- [Multi-tool](#multi-tool)
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

## Quickstart

```bash
pipx install speccraft-cli
speccraft init /path/to/your-repo
```

> Want unreleased `main`? `pipx install git+https://github.com/swshukla/speccraft.git` instead.

> **Requirements:** `python3`, `git`. No API keys, no services, no LLM calls in the tooling itself — the harvesters are pure stdlib.

`speccraft init` scaffolds `your-repo/.speccraft/`, runs every harvester (pinned to your last code commit), installs the four `speccraft-*` procedures for Claude Code / Codex / OpenCode, wires `AGENTS.md`/`CLAUDE.md`, arms the git hooks, and writes `KB-STATUS.md`.

From there:

| Step | Action |
|:---:|---|
| 1 | Tune `.speccraft/kbforge.yaml` — set `components` and `risk_paths` (auth / money / truth-critical path patterns). |
| 2 | Run `speccraft-interview` in a Claude Code (or Codex/OpenCode) session — the one irreducibly human step; intent and invariants land in `kb/normative/` and everything downstream grounds in it. |
| 3 | Run the extraction passes, then work through `.speccraft/QUEUE.md` with `speccraft-ratify`. |
| 4 | **It's self-sustaining after that.** Just build — each commit runs the ship loop, drift keeps citations honest, recall grounds each task. |

**Go deeper:** [`speccraft/forge/README.md`](speccraft/forge/README.md) (full walkthrough) · [`speccraft/forge/SPEC.md`](speccraft/forge/SPEC.md) (system reference) · [`speccraft/forge/workflow-execution.html`](speccraft/forge/workflow-execution.html) (visual tour)

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

## Layout

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

<div align="center">

## License

[MIT](LICENSE) — do what you like with it.

</div>
