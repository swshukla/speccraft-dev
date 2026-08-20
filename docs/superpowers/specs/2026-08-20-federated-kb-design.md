# Federated KBs — Linking Knowledge Across Repos and Monorepo Modules

**Date:** 2026-08-20
**Status:** Draft for review (rev 1)
**Depends on:** `2026-07-25-repowise-sidecar.md` (workspace declaration, seam
discovery — itself unbuilt; see "Repowise as a first-class dependency"),
`2026-07-25-stale-commit-guard.md` (staleness vocabulary),
`2026-07-25-trust-decay.md` (demotion),
`2026-08-02-queue-teeth-forcing-function-design.md` (`ratified_through` as the
trust boundary)
**Informs:** `2026-08-12-single-source-cure-design.md` — federation must not
reintroduce a second home for a fact

## Problem

A speccraft KB governs exactly one repo root. `kbforge.yaml` carries a single
`repo:` path (`seed0.py:90`), every fact's `anchors:` are repo-relative paths
matched by prefix (`recall.py:94-103`), and trust state is one `source_commit` /
`ratified_through` pin with one QUEUE and one ratify loop.

Real work is not shaped like that. It is either several repos worked on together
— a few backends, a web frontend, a couple of mobile apps — or one large
monorepo where only a handful of modules are relevant to the change at hand.
Today each of those gets a disconnected KB, which costs four things:

1. **Invariants are re-litigated per repo.** "Money is minor-unit integers" is
   ratified in the backend and unknown to the web app.
2. **Seams are invisible.** Editing a provider surfaces nothing about its
   consumers' expectations, and vice versa.
3. **Attention is fragmented.** N repos means N briefings and N queues for one
   founder with one attention budget.
4. **Every new repo starts cold.** The shared domain model is re-derived from
   scratch instead of inherited.

This spec defines **federation**: a KB may read facts from peer KBs, so a fact
is ratified once at its home and referenced everywhere it governs.

## Decisions taken (and the ones deliberately not taken)

- **Federation, not a central store.** No system-KB repo, no new artifact to
  maintain, no version-skew story between a parent and its members.
- **Reference, ratified once.** A peer's normative fact is normative here by
  reference. It is never copied into a consumer, and consumers never re-ratify.
  Duplication is what `2026-08-12-single-source-cure-design.md` exists to kill;
  federation must not reintroduce it.
- **Fetched, not read.** Peers are named by git remote and fetched into a local
  cache, rather than requiring a sibling checkout. Hooks run in CI and on fresh
  clones; nobody keeps five repos checked out consistently.
- **One mechanism for both shapes.** A monorepo module is a peer whose locator
  is the local working tree. There is no second code path for monorepos.
- **Repowise is assumed, not optional.** The sidecar supplies the workspace
  declaration and seam discovery. See "Repowise as a first-class dependency"
  below for the one place this is bounded.

## The two boundaries

The central distinction in this design, and the one that took a correction to
get right:

- **A KB is a unit of anchoring.** It scopes what a fact is about, what recall
  loads, and where a seam sits. This is per *module*.
- **A repo is a trust boundary.** It owns the pin, `ratified_through`, the
  ledger, the ratify loop, and the queue. This is per *git repo*, because that
  is what has one commit clock and one founder.

**A repo may contain many KBs but has exactly one queue, one pin, one ledger,
and one ratify loop.**

Conflating these produces a 200-module monorepo with 200 queues — N ratify loops
inside a single git history, which is not a benefit but an artifact of the
conflation. It also contradicts the fact that local peers have zero staleness by
construction, which is only true because the trust boundary is the repo.

In a monorepo:

- Module KBs are co-located with their code: `services/payments/.speccraft/kb/`.
  The KB moves with the module, CODEOWNERS applies, ownership is obvious, and
  extracting a module into its own repo later is a directory move rather than a
  migration.
- Trust artifacts live once at the repo root: `.speccraft/QUEUE.md`,
  `.speccraft/peers.lock`, the ledger, the pin.

---

## 1. The peer model

A peer is a quadruple:

```
(alias, locator, kb_path, pin)
```

- **alias** — the label that qualifies anchors (`api`, `web`, `payments`).
- **locator** — either `remote:` (a git URL, fetched) or `path:` (this working
  tree or a sibling, read directly).
- **kb_path** — where the KB sits **relative to the locator root**, defaulting to
  `.speccraft/kb`. A monorepo module's locator is `services/payments`, so its
  `kb_path` stays `.speccraft/kb` rather than repeating the module path.
- **pin** — the peer's `ratified_through` SHA this repo currently reads at.

### Configuration

Aliases and locators derive from `.repowise-workspace.yaml` when present. Its
`repos:` block already declares `path`, `alias`, and `tags` — that is nearly the
peer table, and maintaining a second copy in `kbforge.yaml` would guarantee
drift between them.

`kbforge.yaml` gains:

```yaml
alias: web                  # this repo's own alias — how peers refer to it
peers:
  from_workspace: true      # derive aliases/locators from .repowise-workspace.yaml
  extra:                    # peers not in the workspace (consumed, not indexed)
    - alias: billing
      remote: git@github.com:acme/billing.git
      kb_path: .speccraft/kb
  exclude: [mobile-ios]     # workspace members not in this repo's working set
```

`alias:` for self is required for federation. Without it, a peer's seam fact
qualified `web::` cannot be matched against this repo's files. The workspace file
makes aliases agree by construction; an anchor qualified to an alias nobody
claims produces a coverage-gap line at sync, never a silent miss.

### The lockfile

`.speccraft/peers.lock` holds resolved pins and **is committed**:

```yaml
peers:
  - alias: api
    remote: git@github.com:acme/api.git
    kb_path: .speccraft/kb
    pin: a1b2c3d4e5f6...        # api's ratified_through at last sync
    synced_at_commit: 9f8e7d6    # this repo's HEAD when the pin was written
  - alias: payments
    path: services/payments      # locator root
    kb_path: .speccraft/kb       # relative to the locator root
    pin: LOCAL                   # local peers track the working tree
    synced_at_commit: 9f8e7d6
```

The lockfile is both the record of what this repo enforces and the cache key.
Because it is committed, the federation a repo is subject to is visible in that
repo's own git history.

---

## 2. Fetch and cache

### What moves

Only `.speccraft/kb/**` and the peer's `kbforge.yaml`. Never source. Implemented
as a blobless partial fetch with sparse-checkout:

```bash
git init <tmp>
git -C <tmp> remote add origin <url>
git -C <tmp> config core.sparseCheckout true
git -C <tmp> sparse-checkout set <kb_path> .speccraft/kbforge.yaml
git -C <tmp> fetch --filter=blob:none --depth 1 origin <sha>
git -C <tmp> checkout FETCH_HEAD
```

A peer costs kilobytes regardless of repo size. Auth is inherited: we shell out
to `git`, which uses the user's existing credential helper. No new secret
handling; private repos work on day one.

### Two-step pin resolution

The lockfile pins each peer at its `ratified_through`, not its HEAD — that is the
trust boundary established by `2026-08-02-queue-teeth-forcing-function-design.md`
and the correct thing to read across a federation. Since `ratified_through` cannot be known without looking, sync is two
steps:

1. Fetch the branch tip's `.speccraft` (blobless, cheap) and read the peer's
   `ratified_through` anchor.
2. Materialize that SHA into the cache.

**Constraint:** fetching an arbitrary SHA requires the server to permit
reachable-SHA fetches. GitHub and GitLab do; some self-hosted setups do not. The
fallback is to fetch the branch and resolve the commit locally. If that also
fails, sync emits a coverage gap and leaves the existing pin in place. It must
**never** fall back to the branch tip: using a commit newer than the pin would
enforce facts the founder has not ratified.

### Cache layout

```
~/.kbforge/peers/<sha256(remote_url)[:16]>/<sha>/
```

Outside every working tree, so nothing is duplicated into repos. Content-
addressed by commit, therefore immutable — a new pin is a new directory and there
is no invalidation logic to get wrong. Keyed by URL rather than alias so several
repos in a federation share one cache entry.

Materialization writes to a temp directory and atomically renames. Parallel agent
fan-out (see `2026-08-10-edit-scope-freeze-design.md`) means concurrent readers
are a realistic scenario, and a half-written peer KB would present as an
intermittent.

GC prunes cache entries referenced by no lockfile, bounded by age.

### Local peers

Skip all of the above. Read the working tree directly; the pin is recorded as
`LOCAL` with the repo's HEAD stored for provenance only. The monorepo case has
zero staleness by construction, because the module and its consumer share one
commit clock.

### Sync points

- `speccraft init`
- the post-commit ship loop, backgrounded and logged, mirroring how the sidecar
  spec handles `repowise update`
- an explicit `speccraft sync`

**Never inside a PreToolUse hook.** The hook path must not touch the network: a
gate that denies on one machine and passes on another destroys the determinism
that makes the gates worth having. This constraint is what selects sync-at-
boundaries over lazy fetch.

### Staleness

Detected at sync, when the network is already in hand: lockfile pin versus the
peer's current `ratified_through`. Reported through the stale-commit-guard's
existing warning tier and its `KB_ACK_STALE`-style acknowledgement rather than a
second staleness vocabulary. Warning only — never blocking.

---

## 3. The read path

### Anchor grammar

A qualified anchor is `alias::path`:

```yaml
anchors: [api::src/payments/, web::src/api/payments.ts]
```

Bare anchors remain repo-local and match exactly as they do today. The grammar is
purely additive; no existing fact changes behavior and there is no migration.

### Matching

`match()` (`recall.py:101`) gains one rule:

- strip a leading `<self-alias>::` before prefix-matching
- ignore anchors qualified to any other alias
- bare anchors match as today

That is the entire change to matching semantics.

### Loading

Fact loading walks the local KB plus each peer's cache directory from the
lockfile, tagging every fact with its origin alias and pin. Peer KBs are
kilobytes of markdown and the existing per-session-per-file dedup cache
suppresses repeats, so this remains a local-file read at approximately current
cost.

### Rendering

A peer fact renders with its lane and provenance:

```
INV-3  money is always minor-unit integers
       api@a1b2c3d (normative, by reference)
```

Because a peer's normative fact is normative here, it has teeth in the recall
gate.

### Fail open

**If a peer's cache is missing or its pin unresolvable, the gate fails open and
emits a coverage gap. It does not deny.**

Two precedents both arrived here the hard way: the Confusion Protocol denies only
on exit 3, and `kb-freeze` treats a blank lane file as fail-open rather than
block-all. A federation that turned a missing cache directory into a
deny-everything would be the same defect a third time.

### Briefing

`kb-briefing.sh` gains a federation block beneath the existing two-anchor KB
status:

```
Federation (self: web — 3 peers)
  api        a1b2c3d   current    47 facts   12 queue items
  payments   LOCAL     —          23 facts    (same trust boundary)
  billing    7f3e2d1   STALE (peer ratified 4 commits ahead)
  coverage gap: mobile-ios unreachable (no network)
```

Peer queue counts are read-only aggregation. This is the single session-start
surface covering the whole federation.

---

## 4. The write path

### The invariant

**Writes never cross a repo boundary.** No speccraft command writes into a peer's
KB, queue, or ledger. Everything below follows from this, and it is what keeps
the lane guard, the trust boundary, and the single-source work intact — a
federated write would give a fact two homes.

### Queue

Each repo keeps its own `QUEUE.md` at the trust boundary (repo root). The "one
queue" experience comes from the briefing *reading* peer queues, not merging
them: you see the federation's whole founder-attention backlog in one place and
act where the fact lives.

A monorepo has exactly one queue regardless of module count — see "The two
boundaries."

**Open detail for the plan:** a single root queue with parallel agent fan-out
means concurrent appends to one file. The two-lane split and
`migrate_split_queue.py` establish precedent for queue file mechanics; the exact
append strategy (atomic `O_APPEND` versus per-agent fragments merged at sync)
should be settled in the implementation plan rather than invented here.

### Seam ownership

A seam fact is owned by the **provider** — the repo defining the API — because
breaking changes originate there, and repowise's provider/consumer matching
assigns this automatically. Mined seams land `pending-ratification` in the
provider's decisions lane, per the sidecar spec's rev-2 rule that mined material
never enters normative without `speccraft-ratify`.

Attempting to ratify a referenced fact from a consumer repo names the owning repo
and stops. It does not pretend, and it does not write remotely.

### Consent is the pin

A peer's commit cannot change what this repo enforces without a commit here.
Reads go through the cache at the pinned SHA; the pin moves only when sync
rewrites `.speccraft/peers.lock`, which is committed. Every change in this repo's
enforced set therefore arrives as a reviewable diff in this repo's history.

Ratification happens once, at the home. Adoption is the lockfile bump. One
founder decision, one visible local consent, no second ratify loop.

### Decay across the seam

Local code drifting against a peer's fact cannot demote that fact — this repo
does not own it. It raises a local finding and a queue item naming the owning
repo, and the consumer retains the real lever: refusing to advance the pin.

Demotion happens only where the fact lives, driven by that repo's own
deterministic drift evidence, exactly as `2026-07-25-trust-decay.md` specifies.

---

## 5. Seeding, evals, phase-in

### Warm start requires no new machinery

A repo joining a federation does not re-derive the domain — it references it.
`seed0.py` continues to do only local structural work (inventory, routes,
models); the shared normative layer arrives by reference from peers and is in
force from the first session. Repowise's workspace pass proposes the seams at
join time.

The only addition: `speccraft init` detects an existing workspace and offers to
join it (write `alias:`, `peers:`, and an initial `peers.lock`) rather than
starting cold.

### Evals

`evals/test-federation.sh`, wired into `self-test.sh`, following the pattern used
by every phase since the queue split. Fixtures pin the behaviors this design
reasoned about, not the happy path:

| Fixture | Asserts |
|---|---|
| two-repo | consumer matches a provider's seam fact against its own path via the qualified anchor |
| monorepo | root trust artifacts, two module KBs, exactly one queue and one pin |
| stale-pin | lockfile behind peer's `ratified_through` → warn, never block |
| missing-cache | gate **fails open**, coverage gap emitted |
| no-repowise | `PATH` without the sidecar → seam discovery skipped, coverage gap, suite green |
| unknown-alias | anchor qualified to an unclaimed alias → coverage-gap line, not a silent miss |
| sha-fetch-denied | server refuses reachable-SHA fetch → existing pin retained, never falls forward to tip |

Plus a behavioral tripwire in `evals/behavioral/` asserting an absent peer never
produces a denial.

### Phase-in

Existing single-repo installs see zero change:

- no `peers:`, no `alias:`, no lockfile → no federation
- bare anchors match exactly as today; the `alias::` grammar is additive, so no
  fact migration
- trust artifacts already sit at `.speccraft/` root, so nothing moves

Federation is opt-in by declaring peers.

The one upgrade path that must not be silent is repowise. New inits run
`repowise init`; **existing installs get a nudge and a coverage-gap line, not an
unrequested index build across someone's repo on a version bump.**

---

## Repowise as a first-class dependency

Repowise is assumed rather than optional. It supplies the workspace declaration
(one topology, two consumers) and seam discovery, which is the difference between
cross-repo coverage being a function of the founder's diligence and being a
function of a scan. `speccraft init` runs `repowise init`, in workspace mode when
peers exist.

Two bounds, both from the sidecar spec's own ground rules:

**The capability audit is the first task of the plan.** Ground rule 2 requires
every CLI/JSON surface — `workspace diagnostics`, `workspace breaking-changes`,
`decision list --json` — verified against the installed Repowise version with
`repowise_min_version` pinned, and anything roadmap-not-shipped marked deferred.
A hard dependency raises the stakes rather than removing the requirement: an
unaudited surface that turns out not to exist becomes a hard failure instead of a
degraded one. The audit's findings may shrink what seam discovery promises before
any of this is built.

**Degradation narrows but does not disappear.** It is no longer a co-equal path;
it is a narrow, loud degraded mode. Sidecar missing, wrong version, or offline →
federation still reads peer KBs (plain files in a cache; repowise is not
involved), seam *discovery* is skipped, and a coverage-gap line says so. Fresh
clones, CI containers, and offline work all reach this state regardless of
opinion. The no-repowise fixture exists to prove the degraded mode is real rather
than aspirational.

Federation modules never invoke repowise. Sidecar enrichment stays where the
sidecar spec put it — inside `recall.py`, behind `repowise.enabled`, on a
timeout.

---

## Out of scope

- Cross-repo writes of any kind
- A central or parent KB repo
- Re-ratification of referenced facts in consumer repos
- Merging peer queues into a single physical file
- Fetching peer *source* (only KB material moves)
- Automatic peer discovery by directory convention
