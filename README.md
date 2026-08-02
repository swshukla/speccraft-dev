# Speccraft — development monorepo

This is the **private working repo** for Speccraft. If you're looking for *what Speccraft is and how to use it*, read the shipped package README:

➡️ **[`kb-forge/README.md`](kb-forge/README.md)** — the product story, quickstart, and reference.

> **Speccraft in one line:** a trust-graded knowledge base your codebase carries with it (`.speccraft/`), so agents (and you) build on what's *ratified as true*, not on guesses. Pure-stdlib harvesters, human-ratified, cited to `path:line @sha`.

This document is for **working on Speccraft itself** — the repo topology, layout, dev loop, and how a release reaches PyPI.

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

## Layout

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

The `.speccraft/` KB layout that Speccraft *produces* in a target repo is documented in the [package README](kb-forge/README.md#layout).

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

## License

[MIT](kb-forge/LICENSE) — do what you like with it.
