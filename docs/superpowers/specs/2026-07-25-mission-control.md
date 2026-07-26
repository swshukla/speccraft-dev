# Mission Control — Local Health Dashboard for speccraft Projects

**Date:** 2026-07-25
**Status:** Draft for review (rev 2 — stdlib server, health.json contract,
telemetry label discipline, CLI named as prerequisite)

## Problem

speccraft-provisioned projects produce telemetry (recall rates, guard blocks,
drift status, queue/ledger counts) but there is no unified surface to view
it. The data is scattered across each project's `.speccraft/evals/` directory.
A developer with multiple repos must `cd` into each and run scripts to check
health. As speccraft grows toward a team/cloud product, a local dashboard
establishes the server architecture that will later be deployed in a cloud
harness.

## Scope — Phase 1 only

Phase 1 is a **local, solo-developer health dashboard** — single screen,
read-only over filesystem data, one server process serving all registered
projects. Multi-user, auth, roadmap/economics screens, and the intake write
path are deferred to Phase 2 (cloud harness).

## Step 0 — the `speccraft` CLI (prerequisite, its own work item)

There is no `speccraft` CLI today — there is `kbforge-init.sh`. This spec
(and every later phase) assumes a real entry point. Step 0 is a thin Python
CLI (`speccraft`) that wraps the existing shell script:

- `speccraft init [path]` → delegates to `kbforge-init.sh`
- `speccraft projects add|remove|list` → manages `~/.speccraft/projects.json`
- `speccraft dashboard` → starts the server (this spec)

Small, but it is scaffolding work with its own review — not a side effect
of the dashboard task.

## Architecture

```
~/.speccraft/
├── projects.json       ← registry: which repos are tracked
└── dashboard.log       ← server output

speccraft dashboard --port 2667
         │
    stdlib http.server (localhost)
         │
    ┌────┴────┐
    │ REST API│  ← reads filesystem, no DB
    └────┬────┘
         │
    ┌────┼────┐
    ▼    ▼    ▼
  proj1 proj2 proj3
  .speccraft/
    evals/telemetry.jsonl
    evals/health.md
    KB-STATUS.md
```

### Project discovery

When `speccraft init` runs, it writes the project to a central registry:

```json
// ~/.speccraft/projects.json
[
  {
    "path": "/Users/alice/code/my-app",
    "name": "my-app",
    "registered_at": "2026-07-25T12:00:00Z"
  }
]
```

CLI commands for manual management:
- `speccraft projects add <path>` — register a repo
- `speccraft projects remove <path>` — unregister
- `speccraft projects list` — show registered repos

The server reads this registry on startup. No polling — the registry is the
single source of truth.

### REST API (read-only)

| Endpoint | Returns |
|---|---|
| `GET /api/projects` | Project list with per-project health summary (recall rate, guard blocks, drift status, queue/ledger, last activity) |
| `GET /api/projects/<name>` | Full detail for one project |
| `GET /api/projects/<name>/telemetry?since=&event=&limit=` | Raw telemetry events from `.speccraft/evals/telemetry.jsonl`, filtered and paginated |
| `GET /api/projects/<name>/health` | Contents of `evals/health.json` (see Health contract below) |
| `GET /api/projects/<name>/status` | KB-STATUS.md contents |
| `GET /api/health` | Server alive + registered / reachable project count |

### Server startup

```bash
speccraft dashboard [--port 2667] [--host 127.0.0.1]
```

- Default port 2667 (uncommon, unlikely to conflict)
- Binds to localhost only (not exposed to network)
- Opens no browser automatically — the user navigates to `http://localhost:2667`
- Logs to `~/.speccraft/dashboard.log`

### Web UI (single screen)

Vanilla HTML/CSS/JS — no framework, no build step. Single `index.html` served
at `/`.

**Layout (top to bottom):**

```
┌──────────────────────────────────────────────────┐
│  Mission Control             ► Refresh  [5/5 ok] │
├──────────────────────────────────────────────────┤
│ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ │
│ │ my-app   │ │ api-svc  │ │ web-app  │ │ cli-tool │ │  ← project cards
│ │ ● 78%    │ │ ● 92%   │ │ ● 45%   │ │ ◌ no data│ │
│ │ 2 blocks │ │ 0 blocks│ │ 5 blocks │ │          │ │
│ │ drift ok │ │ drift   │ │ drift    │ │          │ │
│ │          │ │ flagged │ │ flagged  │ │          │ │
│ └─────────┘ └─────────┘ └─────────┘ └─────────┘ │
├──────────────────────────────────────────────────┤
│  my-app › Telemetry       [filter: last 14d ▼]   │
│                                                  │
│  ts                  event          detail        │
│  2026-07-25T11:00   recall_ran     files=3       │
│  2026-07-25T10:45   guard_block    lane=normative │
│  2026-07-25T10:44   recall_empty                  │
│  2026-07-25T10:30   kb_status      queue=2 led=5  │
│                                                  │
│  ◀ 1 2 3 ▶                                       │
└──────────────────────────────────────────────────┘
```

- **Refresh button**: manual reload (auto-refresh every 30s via `setInterval`)
- **Project cards**: color-coded (green ▸ yellow ▸ red) by drift flag, guard
  blocks, and oldest open adjudication item age — deterministic signals.
  Click to select → detail panel below.
- **Detail panel**: telemetry event table for the selected project, with
  pagination and date range filter
- **Status strip**: shows project health summary from health.json, including
  the trust counts line (N ratified | N pending | N challenged, per the
  trust-decay spec)

### Telemetry label discipline (inherited from the recall-telemetry spec)

The dashboard is the most visible telemetry surface, so it follows the same
rules as `telemetry-report.sh` rev 2: recall figures are labeled **"tracked
recall"** with the per-harness breakdown available in the detail panel, and
the untracked fraction renders only as **"≤ N% (upper bound)"**. No card or
panel may show an unqualified recall percentage — the "● 78%" in the mock
above renders as "tracked recall 78%". Cards do not color-code on recall
figures at all (the rate is a bound, not a health verdict); coloring uses
the deterministic signals listed above.

### Health contract — health.json, not markdown parsing

`telemetry-report.sh` currently writes `evals/health.md` for humans. Rather
than the server scraping prose, `telemetry-report.sh` gains one step: write
`evals/health.json` alongside it (same fields, structured). The dashboard
reads only the JSON; health.md remains the human artifact. This is a
one-line contract between two components we own — prose-parsing is not.

### Implementation

New subpackage at `kb-forge/dashboard/`:

```
kb-forge/dashboard/
├── __init__.py
├── server.py           # stdlib http.server routes + startup
├── project_store.py    # Read ~/.speccraft/projects.json, discover per-project data
├── telemetry_reader.py # Parse telemetry.jsonl with pagination/filtering
├── static/
│   ├── index.html      # Single-page UI
│   ├── app.js          # Fetch API + rendering
│   └── style.css       # Minimal styling
└── tests/
    └── test_server.py
```

**Dependencies: none.** Everything in kb-forge is stdlib Python + shell —
that discipline is why install is a shell script. Six read-only JSON
endpoints do not justify the first external dependency; `http.server` +
`json` covers them in ~100 lines. Phase 2 (auth, DB, scheduler) is where a
real framework earns its place — that decision is deferred there, made
consciously, not inherited from Phase 1 by default.

Implementation notes:
- Project names arriving in URL paths are validated against the registry
  (never used to build filesystem paths directly).
- `telemetry_reader.py` must handle telemetry-lib's rotation (5 MB /
  10k-line guard): read the current file; if a rotated sibling exists,
  include it when the `since` filter reaches past the current file's oldest
  event.

The existing `speccraft` CLI (currently `kbforge-init.sh`) gains new commands.
The `dashboard` command launches the server. The `projects` commands manage the
registry.

## Telemetry data format

The server reads the same JSONL that `telemetry-lib.sh` produces:

```jsonl
{"ts":"2026-07-25T11:00:00Z","session":"abc","event":"recall_ran","detail":"files=3"}
{"ts":"2026-07-25T10:45:00Z","session":"abc","event":"guard_block","detail":"lane=normative"}
```

No new event types needed. The server parses and serves this directly.

## Relationship to the broader agentic-sdlc Mission Control spec

This spec (`19-mission-control.md`) describes an org-level cockpit with
roadmap boards, economics, and intake. Phase 1 here is a strict subset:
read-only health telemetry for a solo developer, with the same server
architecture that Phase 2 will extend with auth, multi-user, adapter-based
metrics, and the full screen set.

## Telemetry

The server logs to `~/.speccraft/dashboard.log`. No new kb_telemetry events
— the dashboard is a consumer of telemetry, not a producer.

## Out of scope

- Multi-user auth and team views (Phase 2)
- Intake write path (Phase 2)
- Roadmap board / economics screens (Phase 2)
- Adapter-based metrics (Phase 2)
- HTTPS or TLS
- WebSockets — polling is sufficient for Phase 1
- Auto-discovery beyond the registry file
- Modifying telemetry data — the server is read-only
- Web frameworks (Flask etc.) — revisited in Phase 2 where auth/DB/scheduler
  justify one; Phase 1 stays stdlib-only
