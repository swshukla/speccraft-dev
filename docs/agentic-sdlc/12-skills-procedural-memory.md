# Agentic SDLC — Skills as the Procedural-Memory Layer

**Date:** 2026-07-12
**Purpose:** Where Agent Skills (superpowers, gstack, awesome-agent-skills) fit in the system — as the **procedural-memory / capability layer** the stage agents draw on — and how to adopt them safely given they run code and steer autonomous-to-prod agents.

## The placement: skills are the third memory type

Doc `05` gave the system two of the three cognitive memory types. Skills are the missing third:

| Memory type | Answers | In our system |
|---|---|---|
| **Semantic** | "What *is* the code/spec?" | the KB — Serena graph + Atlas index + spec store (`04`/`05`) |
| **Episodic** | "What *happened* — what did we try, what failed?" | episodic lessons (`05`) |
| **Procedural** | "*How* do I perform this class of task well?" | **Skills** ← this doc |

> A skill is codified procedure — a reusable "how to do X well" playbook (write a spec, debug systematically, review for security, plan a change) that an agent **loads on demand**. It's not knowledge *about* the product (semantic) or *experience* from past runs (episodic); it's **know-how**. That's exactly what turns a generic stage agent into an expert at its stage.

## What a skill is (grounded)

A folder with a `SKILL.md`: YAML frontmatter (`name` + a `description` written as a **routing rule** — the only part always in context) and a markdown body of *how*, plus optional reference files and **executable scripts**. **Progressive disclosure** loads it in three levels — description (always, ~100 tokens) → body (on match) → bundled files/scripts (on demand) — so a large library costs almost nothing until a skill earns its place. It's an **open standard** (Claude Code, Codex, Gemini) and skills **can execute code**.

Two properties matter for us:
- **Token-efficient by construction** — progressive disclosure is the same "layered/incremental loading" we adopted from MemPalace (`05`) and it pairs with the **Model Gateway** budgets (`03`). You can mount 50+ skills without bloating context.
- **Behavior-steering + code-executing** — a skill changes what an autonomous agent *does* and can *run scripts*. That makes it powerful **and** a governance surface (below).

## How skills attach to the architecture

- **Stage agents mount skills.** In `03`, a stage agent = prompt + tools + output schema. Skills become the modular, versioned *procedure* the agent draws on — far better than a monolithic mega-prompt. Each stage declares which skills it may load.
- **Skills-as-code in the repo.** Like spec-as-code and Rego-as-code, skills live **versioned in the repo, PR-reviewed, human-governed, in the isolated plane** (`02`). This fits our doctrine exactly.
- **Auto-routed by description.** The agent selects a skill by reasoning over descriptions, so description quality *is* routing accuracy — we curate descriptions as routing rules.

### Skill → stage map

| Stage agent | Skills it mounts (examples) | Source |
|---|---|---|
| **PM** (`08`) | problem-framing, brainstorming, PRD/shaping | superpowers · gstack PM role |
| **Spec** (`06`) | spec-writing, acceptance-criteria/Gherkin, requirements elicitation | superpowers:brainstorming · gstack plan |
| **Plan/Design** (`11` A3) | architecture/design, change-planning, migration | gstack `/plan-*` skills |
| **Coder** | systematic-debugging, TDD, language/framework idioms | superpowers:systematic-debugging · awesome-agent-skills |
| **Verifier / Reviewer** | code-review, **security-review**, test-strategy | gstack security-officer · trailofbits secure-contracts |
| **Deployer** | deploy/release runbooks, canary procedure | gstack build · bespoke |

## Build-vs-buy

| Option | What it is | Verdict |
|---|---|---|
| **superpowers** | proven *process*-skill library (brainstorming, systematic-debugging) | **ADOPT** — general, high-quality, maps straight onto PM/Spec/Coder. Already available in-house. |
| **gstack** (Garry Tan) | opinionated SDLC skill+role stack — Plan/Build, PM/designer/security roles | **HARVEST / ADAPT** — best source of SDLC-shaped skills & workflows. But its *operating model* is "run Claude like an eng team" (human-orchestrated, ≈ Approach A / the on-ramp), **not** our governed autonomous-to-prod pipeline. Take the skills, not the operating model. Vet each. |
| **awesome-agent-skills** (VoltAgent) | catalog of 1000+ cross-platform skills | **CURATED SOURCE** — cherry-pick specific vetted skills (e.g. security review). Treat every entry as untrusted-until-reviewed. |

## Governance — skills are an attack & quality surface (the non-negotiable part)

Because a skill **runs code** and **steers an agent that ships to prod**, a bad or malicious skill is worse than a bad dependency — it's a **prompt-injection + supply-chain vector aimed at the autonomous pipeline.** So:

1. **Third-party skills are untrusted until reviewed.** No auto-install. Each skill from gstack / awesome-agent-skills is read, **pinned to a version/hash**, security-reviewed (especially its scripts), and merged via PR — same supply-chain caution we applied to MemPalace (`05`).
2. **A skill change is a deploy → regression-gate it with evals.** Skills silently change agent behavior, so editing a skill must pass the eval suite (`07`) before it goes live — CI for cognition applies to procedural memory too.
3. **Provenance on every skill** — source, version/hash, reviewer, last-eval-pass (`05` provenance discipline).
4. **Least privilege** — a skill runs inside the ephemeral sandbox (`11` B2) with the stage's scoped identity; it inherits the isolation invariant and can reach only the seams, never app data.
5. **Scope skills per stage** — the Coder shouldn't mount the Deployer's release skill. One skill, one verb; mounted only where it belongs.

## Doctrine

1. **Skills = procedural memory** — the third memory type, alongside semantic (KB) and episodic (lessons).
2. **Skills-as-code** — versioned, PR-reviewed, human-governed, in the isolated plane.
3. **Description is the routing rule** — curate it; it's the only part always in context.
4. **A skill change is a deploy** — pin it, review it, eval-gate it.
5. **Untrusted until reviewed** — third-party skills run code and steer prod agents; vet before mounting.
6. **Adopt process, harvest stacks, cherry-pick catalogs** — superpowers wholesale; gstack's skills (not its operating model); awesome-agent-skills selectively.

## What this changes in the build

- **Add a Skill Library** to the net-new inventory (`03`) as a *memory-keeper* sibling — but it's light: a repo folder of skills-as-code + a per-stage mount config + a **skill-vetting + eval-gate** step in the agentic CI. No new runtime component; skills load inside the existing workers.
- **Extend evals** (`07`) to treat skill edits as regression-gated changes.
- **Phase 0:** mount a *small, trusted* set immediately — superpowers `brainstorming` (Spec/PM) and `systematic-debugging` (Coder) — since they're proven and cut straight to quality. Defer harvesting gstack / awesome-agent-skills until the **vetting + eval-gate pipeline** exists, so no unreviewed third-party skill ever steers an autonomous run.

---

*Sources:* [Anthropic — Equipping agents with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) · [Claude Agent Skills docs](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview) · [VoltAgent/awesome-agent-skills](https://github.com/VoltAgent/awesome-agent-skills) · [gstack (garrytan/gstack)](https://github.com/garrytan/gstack) · [gstack explainer](https://agentnativedev.medium.com/garry-tans-gstack-running-claude-like-an-engineering-team-392f1bd38085)
