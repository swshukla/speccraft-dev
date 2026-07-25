# Speccraft

**A trust-graded knowledge base your codebase carries with it — so agents (and you) build on what's *ratified as true*, not on guesses.**

Speccraft turns a repo's scattered, half-lost knowledge — intent, invariants, the reasons behind decisions, the gotchas in your dependencies, the bugs nobody wrote down — into a cited, versioned, human-ratified knowledge base that lives *inside the repo* (`.speccraft/`) and stays honest as the code changes.

It's built for the hard case: an **existing (brownfield) codebase** whose design rationale has already evaporated, worked by AI coding sessions across **Claude Code, Codex, and OpenCode**.

---

## Why it exists

Every codebase knows things nobody wrote down: why a constant is `30`, which alternative was rejected, that lapsed users still get paid features, that this dependency version has a known CVE. Code records the *outcome* of a decision, never the decision. AI agents, lacking that context, confidently repeat known mistakes and drift from intent.

Speccraft's answer is a **grounded ratchet**: seed a knowledge base from human-adjudicated truth, validate every change against it, and let error be *caught* rather than compound. The core discipline:

- **Cite or it didn't happen** — every claim is pinned to `path:line @<commit-sha>`.
- **Provenance is never blurred** — each fact is tagged by *how it's known*: `derived` (machine-harvested), `inferred` (agent hypothesis), `elicited` (your own words), `decision` (an ADR), `external` (dependency knowledge, sub-graded by source).
- **Nothing becomes `ratified` except through a human** — agents propose; you rule. A fact's trust state moves `pending → ratified → challenged`, never silently.
- **Deterministic before generative** — anything a regex or git can harvest is harvested by a no-LLM tool that *cannot hallucinate*; agents only interpret, and their output enters as an unratified hypothesis.

---

## Quickstart

```bash
pipx install git+https://github.com/swshukla/speccraft.git
speccraft init /path/to/your-repo
```

Requirements: `python3`, `git`. No API keys, no services, no LLM calls in the tooling itself — the harvesters are pure stdlib.

`speccraft init` scaffolds `your-repo/.speccraft/`, runs every harvester (pinned to your last code commit), installs the four `speccraft-*` procedures for Claude Code / Codex / OpenCode, wires `AGENTS.md`/`CLAUDE.md`, arms the git hooks, and writes `KB-STATUS.md`.

From there:

1. Tune `.speccraft/kbforge.yaml` — set `components` and `risk_paths` (auth / money / truth-critical path patterns).
2. Run `speccraft-interview` in a Claude Code (or Codex/OpenCode) session — this is the one irreducibly human step; intent and invariants land in `kb/normative/` and everything downstream grounds in it.
3. Run the extraction passes, then work through `.speccraft/QUEUE.md` with `speccraft-ratify`.
4. **It's self-sustaining after that.** Just build — each commit runs the ship loop, drift keeps citations honest, recall grounds each task.

Full walkthrough: [`speccraft/forge/README.md`](speccraft/forge/README.md) · System reference: [`speccraft/forge/SPEC.md`](speccraft/forge/SPEC.md) · Visual tour: [`speccraft/forge/workflow-execution.html`](speccraft/forge/workflow-execution.html)

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

## The steady-state loop

```
session start → speccraft-recall (ground in ratified truth)
   → build → speccraft-decide (log tradeoffs) / speccraft-diverge (on conflict)
   → git commit  ─ pre-commit lane guard ─
   → ship loop: drift → re-pin → re-harvest → kb: commit → KB-STATUS refresh
   → speccraft-ratify (founder rules the queue, occasionally)
   → feeds the next session
```

A git **pre-commit** hook keeps machine-proposed and human-ratified knowledge distinguishable: commits touching the founder/machine lanes (`kb/normative/`, `kb/derived/`, `ledger/`) require an explicit flag — `KB_RATIFY=1` (a human ruling) or `KB_SHIPLOOP=1` (the automatic re-pin). It's not a lock against an intruder — you own the repo — it's a *signature*: when a fact is ratified, the git history shows a human stood behind it, so an agent can run autonomously without quietly promoting its own guesses to truth. A **post-commit** hook runs the ship loop on every code commit.

Sessions write only `QUEUE.md`, `kb/decisions/`, `kb/inferred/`, and `proposed` rows in `findings/`. Everything else is founder/machine.

---

## Multi-tool

One source, three runtimes. Rules live in `AGENTS.md` (Codex & OpenCode read it natively; `CLAUDE.md` imports it). The four procedures ship as Claude skills, the Agent Skills standard, and OpenCode commands. The git hooks enforce identically regardless of which tool — or which human — makes the commit.

---

## License

[MIT](LICENSE)
