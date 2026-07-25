# Mission Control — Cloud Autonomous Server

**Date:** 2026-07-25
**Status:** Draft for review
**Depends on:** `2026-07-25-mission-control.md` (Phase 1 local dashboard), `docs/agentic-sdlc/09-mixed-input-reality.md`, `15-work-item-taxonomy.md`, `11-execution-view.md`, `08-product-manager-agent.md`

## Problem

Phase 1 Mission Control is a read-only health dashboard for a solo developer. It shows
telemetry but cannot act. The real system — where problems enter as anything from a one-line
ask to a full PRD, get triaged, decomposed, and proactively executed by autonomous agents —
needs a server that *manages* the work, not just displays it. The existing `19-mission-control.md`
spec describes the org-level cockpit but assumes infrastructure (JIRA, Azure DevOps, ACI, Atlas)
that isn't built yet. This spec defines the cloud Mission Control as a practical, buildable
system that works today with speccraft as a pip package and grows into the full `19` vision.

## Scope

This is the **full cloud system** — intake, triage, queue, autonomous execution, observability.
It replaces the Phase 1 local dashboard: the same server binary runs locally (solo dev, one repo)
or in the cloud (team, multiple repos, autonomous). The local mode is a strict subset.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Mission Control Server                        │
│                                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌───────────────┐   │
│  │  Intake   │  │  Queue   │  │ Executor │  │  Observability│   │
│  │  (API +   │→ │ Manager  │→ │ (worker  │→ │  (Phase 1     │   │
│  │   Web UI) │  │          │  │  spawner)│  │   dashboard)  │   │
│  └──────────┘  └──────────┘  └──────────┘  └───────────────┘   │
│       │              │              │               │           │
│       ▼              ▼              ▼               ▼           │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              SQLite (dev) / PostgreSQL (cloud)            │   │
│  │  work_items · runs · stages · telemetry · audit_log      │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              Background Scheduler                         │   │
│  │  picks work_items → spawns runs → advances stages         │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
   ┌──────────┐        ┌──────────┐        ┌──────────┐
   │ Repo 1   │        │ Repo 2   │        │ Repo N   │
   │ .speccraft│        │ .speccraft│        │ .speccraft│
   └──────────┘        └──────────┘        └──────────┘
```

### Single binary, one port

The server is one process, one port (default 2667). It serves the REST API, the web UI, and
runs the background scheduler. No separate worker processes. SQLite for local/dev; PostgreSQL
for cloud/team. The scheduler is a simple in-process loop — no message bus, no external queue.

### How it knows about repos

The registry from Phase 1 (`~/.speccraft/projects.json`) extends to the cloud. The server reads
a config file that lists the repos it manages. In local mode, this is the same `projects.json`.
In cloud mode, this is a `config.yaml`:

```yaml
# ~/.speccraft/config.yaml (local) or /etc/mission-control/config.yaml (cloud)
server:
  port: 2667
  host: 0.0.0.0   # cloud; localhost in local mode

repos:
  - path: /srv/repos/my-app
    name: my-app
  - path: /srv/repos/api-service
    name: api-service

scheduler:
  enabled: true
  poll_interval: 30        # seconds
  max_concurrent_runs: 3   # parallel work items
  max_retries: 2           # per work item before parking
```

---

## Intake — different inputs, one entry point

Every problem enters through the same API. The intake stage classifies it into one of the
four work-item types from `15-work-item-taxonomy.md`:

| Input type | What the user sends | Intake does | Downstream path |
|---|---|---|---|
| **One-liner** | `"Add user authentication"` | Frames problem, asks clarifying questions (PM Agent), produces a Feature | Heavy elicitation → Feature → decompose → N runs |
| **PRD / spec doc** | Markdown/text document | Parses structure, extracts requirements, validates completeness | PM (light) → decompose → N runs |
| **Design doc** | Technical design with components, seams, data model | Extracts acceptance criteria, validates against KB | Spec (light) → builds directly |
| **Bug report** | Symptom + steps to reproduce | Reproduces, classifies root cause/band-aid, scopes fix | Repro → fix → verify → 1 run |
| **Task / enhancement** | Concrete, scoped ask | Validates scope, generates acceptance criteria | Spec → light design → 1 run |

### The intake API

```
POST /api/work-items
{
  "type": "auto" | "one-liner" | "prd" | "design" | "bug" | "task",
  "repo": "my-app",
  "title": "Add user authentication",
  "body": "...",                    # the actual content
  "source": "human" | "monitor" | "drift" | "pm-agent",
  "priority": "auto" | "high" | "normal" | "low"
}
```

- `type: auto` — the intake classifier determines the type from the body content
- `source` — who/what created this (human, monitor agent, drift detector, PM agent)
- `priority: auto` — the queue manager assigns based on type and blast-radius

### The intake pipeline

```
1. Receive input
2. Classify type (if auto)
3. Ground in KB (structure-scoped retrieval)
4. Frame the problem (symptom vs root cause)
5. Validate completeness:
   - One-liner: enough to start PM elicitation? If not, ask clarifying questions.
   - PRD: are acceptance criteria extractable? If not, flag gaps.
   - Bug: is there a repro path? If not, request one.
   - Design/Task: are seams and contracts defined?
6. Create work_item in DB with status INTAKE
7. If type = one-liner → status = ELICITING (PM Agent runs)
8. If type = PRD/design/task → status = TRIAGED
9. If type = bug → status = TRIAGED (fast path)
```

---

## Queue management

### Work item states

```
INTAKE → ELICITING → TRIAGED → QUEUED → RUNNING → AWAITING_HUMAN → RESOLVED
                ↓                    ↓          ↓              ↓
              REJECTED            PARKED     FAILED         CANCELLED
```

- **INTAKE** — input received, being classified
- **ELICITING** — PM Agent is asking clarifying questions (one-liners only)
- **TRIAGED** — classified, prioritized, ready for scheduling
- **QUEUED** — waiting for an execution slot
- **RUNNING** — a worker is executing this
- **AWAITING_HUMAN** — needs human ratification (intent, spec, design review)
- **RESOLVED** — completed successfully
- **PARKED** — failed after max retries, needs human intervention
- **REJECTED** — intake determined this isn't actionable
- **CANCELLED** — human cancelled

### Priority calculation

```
priority_score = base_weight × urgency_multiplier × impact_multiplier

base_weight:
  bug = 10 (fast path, cheap, high value)
  task = 8
  one-liner = 6 (high human load, deferred until elicitation complete)
  prd = 5
  design = 4

urgency_multiplier:
  from monitor/drift = 2.0 (something broke or drifted)
  from human = 1.0
  from pm-agent = 0.8 (proactive, not urgent)

impact_multiplier:
  blast-radius > 50% of repo = 2.0
  blast-radius > 10% = 1.5
  blast-radius <= 10% = 1.0
```

### Scheduling

The background scheduler runs every `poll_interval` seconds:

```
1. Check for work_items in TRIAGED state
2. Sort by priority_score descending
3. If running_count < max_concurrent_runs:
   a. Pick highest-priority item
   b. Transition to QUEUED → RUNNING
   c. Spawn execution context (see next section)
4. Check for stalled runs (running > timeout)
   a. If stalled: transition to PARKED, increment retry_count
   b. If retry_count < max_retries: re-queue
   c. Else: park permanently, notify human
```

---

## Autonomous execution

This is where the server "knocks off tasks." For each running work item, the executor
runs the appropriate pipeline from `11-execution-view.md`:

### Bug fix path (fastest)

```
1. Reproduce — run the reported steps in a sandboxed checkout
2. Diagnose — root cause / boundary-guard / band-aid classification
   (per 20-field-validation-gaps.md)
3. Fix — Coder agent writes the fix
4. Verify — run existing tests + new test for the fix
5. PR — open a pull request with evidence pack
6. If all gates pass + blast-radius <= 10% + fix classified as root-cause → auto-merge
   Else → AWAITING_HUMAN (human reviews PR)
```

### Task/enhancement path

```
1. Spec — generate unit-spec with Gherkin acceptance criteria
2. Light design — implementation plan (files, approach, test strategy)
3. Build — Coder agent writes code + tests
4. Verify — run acceptance tests + regression + lint
5. Gates — spec-conformance, blast-radius, policy
6. PR — open pull request
7. If L3 (all gates green, blast-radius <= 10% of repo, no auth/payments/PII) → auto-merge
   Else → AWAITING_HUMAN
```

### Feature / PRD path (composite)

```
1. Decompose — break into child work_items (stories/tasks)
2. Each child enters the queue independently
3. Parent waits until all children are RESOLVED
4. Then: integration test, cross-cutting verification
5. PR (may be multi-PR for large features)
6. AWAITING_HUMAN for final ratification
```

### One-liner path (heavy human involvement)

```
1. PM Agent frames problem, grounds in evidence
2. PM Agent asks human clarifying questions (batched, closed-form)
3. Human answers → captured as human-asserted KB facts (capture-on-contact)
4. PM Agent produces problem statement with success metric
5. Human ratifies INTENT → becomes a Feature
6. Feature decomposes → enters the Feature path above
```

### Worker isolation

Each run gets:
- A git worktree of the target repo (branch per run, torn down on completion)
- Read-only access to the KB
- No access to other repos, prod data, or secrets
- Token budget cap (enforced by model gateway in cloud, by config in local)
- Timeout (default 30 minutes per run)

---

## Human-in-the-loop

The system proactively works but knows when to stop and ask.

### Automatic escalation points

| Gate | Condition | Action |
|---|---|---|
| **Intent ratification** | one-liner or PRD where intent is ambiguous | AWAITING_HUMAN — human must ratify before build |
| **Design review** | new system, high blast-radius, auth/payments/PII | AWAITING_HUMAN — human reviews design |
| **Code review** | L2 risk level or low confidence | AWAITING_HUMAN — human reviews PR |
| **Band-aid detection** | fix classified as band-aid with high confidence | PARKED — human diagnoses root cause |
| **Max retries** | run failed > max_retries times | PARKED — human investigates |
| **Budget exceeded** | token spend > per-run cap | PARKED — human decides to continue or cancel |

### Human response interface

Humans respond through:
1. **Web UI** — the Mission Control dashboard shows pending human actions. The ELICITING
   state presents the PM Agent's clarifying questions as a form; the human answers inline.
2. **API** — `POST /api/work-items/:id/ratify` with the decision
3. **PR review** — for code review escalations, the human reviews the PR directly
4. **Chat integration** (Phase 2) — Slack/Teams notifications with response

The PM Agent's clarifying questions are batched (10-12 closed-form questions per interaction,
per `09-mixed-input-reality.md`'s "batch and prioritize"). The ELICITING state holds the
work item while the human responds through the web UI or API. The PM Agent does not proceed
until the human answers; the work item remains in ELICITING indefinitely (no timeout — the
human's time is the scarce resource).

---

## Observability

The Phase 1 health dashboard is embedded in the cloud server. The same screens show:

### Dashboard (main screen)

- **Queue overview** — items by status (INTAKE, ELICITING, QUEUED, RUNNING, AWAITING_HUMAN, PARKED)
- **Active runs** — currently executing work items with progress, elapsed time, token spend
- **Recent completions** — resolved items with outcome (merged, parked, rejected)
- **Health indicators** — per-repo recall rate, drift status, guard blocks (from evals telemetry)

### Work item detail

- Full history: intake → triage → execution → gates → outcome
- Telemetry timeline (from `.speccraft/evals/telemetry.jsonl`)
- Token spend breakdown by stage
- Gate results (pass/fail/retry)
- Linked PRs and deploy records
- Audit trail (every action logged)

### Metrics (computed in real-time)

- **Human leverage ratio** — resolved work items per human hour (headline metric per `19`)
- **Failure-touch rate** — % of human interactions that are correcting mistakes
- **Queue depth** — items waiting, by type
- **Cycle time** — time from intake to resolved, by type
- **Cost per change** — actual tokens × model price, by type
- **Autonomy rate** — % of items resolved without human intervention (diagnostic, not target)

---

## Database schema (SQLite/PostgreSQL)

### work_items

```sql
CREATE TABLE work_items (
  id            TEXT PRIMARY KEY,
  repo          TEXT NOT NULL,
  type          TEXT NOT NULL,  -- one-liner, prd, design, bug, task
  status        TEXT NOT NULL,  -- intake, eliciting, triaged, queued, running,
                                -- awaiting_human, resolved, parked, rejected, cancelled
  title         TEXT NOT NULL,
  body          TEXT,
  source        TEXT NOT NULL,  -- human, monitor, drift, pm-agent
  priority      TEXT NOT NULL,  -- high, normal, low
  priority_score REAL,
  parent_id     TEXT REFERENCES work_items(id),
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  resolved_at   TEXT,
  retry_count   INTEGER DEFAULT 0,
  metadata      TEXT  -- JSON blob for type-specific data
);
```

### runs

```sql
CREATE TABLE runs (
  id            TEXT PRIMARY KEY,
  work_item_id  TEXT NOT NULL REFERENCES work_items(id),
  repo          TEXT NOT NULL,
  status        TEXT NOT NULL,  -- pending, running, completed, failed, timed_out
  stage         TEXT NOT NULL,  -- intake, spec, design, build, verify, gates, deploy, monitor
  started_at    TEXT,
  completed_at  TEXT,
  tokens_used   INTEGER DEFAULT 0,
  cost_usd      REAL DEFAULT 0,
  error         TEXT,
  metadata      TEXT  -- JSON: model used, git SHA, PR number, etc.
);
```

### stage_events

```sql
CREATE TABLE stage_events (
  id            TEXT PRIMARY KEY,
  run_id        TEXT NOT NULL REFERENCES runs(id),
  stage         TEXT NOT NULL,
  event         TEXT NOT NULL,  -- started, completed, failed, retried
  ts            TEXT NOT NULL,
  detail        TEXT  -- JSON
);
```

### human_actions

```sql
CREATE TABLE human_actions (
  id            TEXT PRIMARY KEY,
  work_item_id  TEXT NOT NULL REFERENCES work_items(id),
  action_type   TEXT NOT NULL,  -- ratify_intent, approve_design, review_code, diagnose, cancel
  request_at    TEXT NOT NULL,
  responded_at  TEXT,
  decision      TEXT,  -- approve, reject, modify
  detail        TEXT
);
```

---

## CLI

```bash
# Start the server
speccraft dashboard [--port 2667] [--config path/to/config.yaml]

# Manage repos (local mode)
speccraft projects add <path>
speccraft projects remove <path>
speccraft projects list

# Submit work (CLI alternative to API)
speccraft submit --type one-liner --repo my-app "Add user auth"
speccraft submit --type bug --repo my-app --title "Login fails on Safari" --body "Steps: ..."

# Check queue status
speccraft queue status
speccraft queue list [--status running] [--repo my-app]

# Manually advance a work item (for debugging)
speccraft work-item <id> --ratify-intent
speccraft work-item <id> --approve-design
speccraft work-item <id> --park --reason "needs more info"
```

---

## Local vs Cloud — same binary, different config

| Aspect | Local (solo dev) | Cloud (team) |
|---|---|---|
| **Config** | `~/.speccraft/config.yaml` | `/etc/mission-control/config.yaml` |
| **Database** | SQLite (`~/.speccraft/dashboard.db`) | PostgreSQL |
| **Scheduler** | In-process loop | In-process loop (same code) |
| **Worker isolation** | git worktree + temp dir | Docker container per run |
| **Model access** | Local API key (Claude Code) | Model Gateway (metered) |
| **Auth** | None (local only) | IdP (org's SSO) |
| **Repos** | Local filesystem paths | Mounted volumes or git clone |
| **Default concurrency** | 1 | 3 (configurable) |
| **Web UI** | localhost:2667 | same UI, behind auth |

The local mode is a strict subset — same code, same API, same UI, fewer moving parts.
A developer can prototype locally, then deploy the same binary to the cloud when ready.

---

## Transition from Phase 1

Phase 1 (the local health dashboard from `2026-07-25-mission-control.md`) is a subset of this
system. The Phase 1 server binary *is* this server binary, started without the scheduler:

```bash
# Phase 1 (health dashboard only)
speccraft dashboard --read-only

# Phase 2 (full autonomous server)
speccraft dashboard  # scheduler enabled by default
```

The Phase 1 read-only mode disables intake, the scheduler, and execution — it only serves
the observability screens. This is useful for monitoring without autonomous action.

---

## What this changes in earlier docs

- **`19-mission-control.md`:** Phase 1 becomes a read-only subset of this spec. The full
  Mission Control (intake, queue, execution) is this doc.
- **`16-local-dev-in-the-loop.md`:** The developer-in-the-loop model is now a config option
  (scheduler disabled) rather than a separate architecture. The same server serves both.
- **`11-execution-view.md`:** The execution stages are now implemented as methods on the
  executor, not as a conceptual trace. The same stage progression applies.
- **`15-work-item-taxonomy.md`:** The taxonomy is now enforced at intake — the classifier
  routes each input type to the appropriate pipeline.

## Out of scope

- Multi-org cells (per `17` — this is single-org, single-cell)
- JIRA/ADO integration (connectors are adapters, added later)
- Service bus / distributed workers (single-process for now)
- Chat integration (Slack/Teams notifications — Phase 2)
- Audit ledger (git history + DB audit_log suffices for now)
- Model Gateway (local mode uses direct API keys; cloud mode adds Gateway later)
- Canary / feature-flag deploy (PR merge is the deploy seam for now)
