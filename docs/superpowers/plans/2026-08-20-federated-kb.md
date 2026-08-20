# Federated KBs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a speccraft KB read facts from peer KBs, so a fact is ratified once at its home repo and referenced everywhere it governs — across separate repos and across modules of a monorepo.

**Architecture:** Two new sibling modules with a hard boundary between them. `peers.py` is pure and offline: it parses config and the lockfile, resolves peers to local directories, and collects facts tagged with their origin alias. `peersync.py` owns every network operation: fetching peer KBs into a content-addressed cache and writing the lockfile. `recall.py` imports `peers` and never imports `peersync` — that import graph is what structurally guarantees no network call can reach a PreToolUse hook.

**Tech Stack:** Python 3.9+ stdlib only (no third-party imports — `pyproject.toml` declares no dependencies), `git` CLI via `subprocess`, bash eval suites for behavior, pytest for module shape and packaging.

**Spec:** `docs/superpowers/specs/2026-08-20-federated-kb-design.md`

## Global Constraints

- **Stdlib only.** `kb-forge/pyproject.toml` declares no `dependencies`. Never `import yaml`, `requests`, or anything third-party. Config parsing is hand-rolled.
- **Python floor is 3.9** (`requires-python = ">=3.9"`). No `X | Y` type unions, no `match` statements, no `dict |` merge operator.
- **Every file open passes `encoding="utf-8"`.** Commit `f6e5150` pinned UTF-8 across the forge for Windows; new code must not regress it.
- **Fail open, never silent.** A missing, unreachable, or unresolvable peer produces a coverage-gap line and exit 0. It never denies an edit and never blocks a commit.
- **No network below a sync point.** `recall.py`, `gate.py`, and anything on a PreToolUse path must not import `peersync` or shell out to `git fetch`.
- **Writes never cross a repo boundary.** No code in this plan writes into a peer's KB, queue, or ledger.
- **Bare anchors are unchanged.** `alias::` is additive grammar. No existing fact is migrated, and every existing eval must stay green.
- **Default `kb_path` is `.speccraft/kb`** and is not configurable in this phase (deliberate YAGNI — the lockfile carries the field so a later phase can expose it).

## Deviation from the spec, decided during planning

The spec sketched `peers.lock` as YAML and a nested `peers:` block in `kbforge.yaml`. With no YAML library available, nested structures would mean hand-writing a real parser. Two refinements keep the same semantics with trivial parsing:

- **`.speccraft/peers.lock` is JSON.** It is machine-written and machine-read, never hand-edited (the `package-lock.json` precedent). `json` is stdlib.
- **`peers:` in `kbforge.yaml` is a one-level list of `alias = locator` strings.** That is exactly the shape `frontmatter()` already parses. A locator starting with `./` or `/` is a path peer; anything else is a git remote.

Task 12 updates the spec to match.

---

## File Structure

**Create:**

- `kb-forge/speccraft/forge/peers.py` — offline federation: config + lockfile parsing, peer resolution, federated fact collection, self-alias stripping. No network, no subprocess.
- `kb-forge/speccraft/forge/peersync.py` — network federation: peer fetch, two-step pin resolution, cache materialization, GC, lockfile writes.
- `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh` — behavior suite.
- `kb-forge/tests/test_peers.py` — pure-unit tests for parsing and resolution.
- `docs/superpowers/reviews/2026-08-20-repowise-capability-audit.md` — Task 1 output.

**Modify:**

- `kb-forge/speccraft/forge/recall.py` — `frontmatter`/`collect` move to `peers.py`; matching gains self-alias stripping; rendering gains provenance.
- `kb-forge/speccraft/forge/session-kit/hooks/kb-briefing.sh` — federation block.
- `kb-forge/speccraft/forge/session-kit/evals/self-test.sh` — wire the `federation` section.
- `kb-forge/speccraft/forge/session-kit/post-commit` — background sync.
- `kb-forge/speccraft/cli.py` — `speccraft sync` subcommand.

`recall.py` is at 199 lines and already carries parsing, matching, rendering, telemetry, and five CLI modes. Moving KB-reading into `peers.py` is not gratuitous restructuring — `peers.py` needs those functions, and importing them back from `recall.py` would make the pure module depend on the CLI module.

---

## Phasing

- **Phase A (Tasks 1–2)** — audit and foundations. Task 1 gates Task 11 only.
- **Phase B (Tasks 3–7)** — the offline read path. Delivers working federation for path peers (the monorepo case) with no network at all.
- **Phase C (Tasks 8–10)** — the network path: fetch, cache, staleness, sync.
- **Phase D (Tasks 11–12)** — repowise seam discovery and docs.

Phase B alone is shippable and useful.

---

### Task 1: Repowise capability audit

Ground rule 2 of `2026-07-25-repowise-sidecar.md` requires every CLI surface verified against the installed Repowise before integration code exists. This task writes no product code; its output constrains Task 11.

**Files:**
- Create: `docs/superpowers/reviews/2026-08-20-repowise-capability-audit.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a verdict table, and a pinned `REPOWISE_MIN_VERSION` string consumed by Task 11.

- [ ] **Step 1: Record the installed version**

```bash
repowise --version 2>&1 | tee /tmp/repowise-version.txt
which repowise
```

If `repowise` is not installed, stop and report to the user. Do not proceed to Task 11; Tasks 2–10 and 12 are unaffected and should continue.

- [ ] **Step 2: Probe each surface the spec assumes**

Run each, recording exit code and whether stdout parses as JSON:

```bash
for c in "inspect --json" "health --json" "git intelligence --json" \
         "workspace diagnostics --json" "workspace breaking-changes --json" \
         "workspace check --json" "workspace blast-radius --target x --json" \
         "risk --diff /dev/null --json" "decision list --json"; do
  echo "=== repowise $c"
  # shellcheck disable=SC2086
  repowise $c >/tmp/out.json 2>/tmp/err.txt; echo "exit=$?"
  head -c 200 /tmp/out.json; python3 -c "import json,sys;json.load(open('/tmp/out.json'))" \
    && echo " [valid json]" || echo " [NOT json]"
done
```

- [ ] **Step 3: Write the audit document**

Create `docs/superpowers/reviews/2026-08-20-repowise-capability-audit.md` with this exact structure, filling the table from Step 2:

```markdown
# Repowise Capability Audit

**Date:** 2026-08-20
**Installed version:** <from step 1>
**Verdict:** <SUFFICIENT | PARTIAL | INSUFFICIENT>

`REPOWISE_MIN_VERSION = "<version>"`

| Surface | Exists | Valid JSON | Notes |
|---|---|---|---|
| `inspect --json` | | | |
| `health --json` | | | |
| `git intelligence --json` | | | |
| `workspace diagnostics --json` | | | |
| `workspace breaking-changes --json` | | | |
| `workspace check --json` | | | |
| `workspace blast-radius --json` | | | |
| `risk --diff --json` | | | |
| `decision list --json` | | | |

## Deferred

Surfaces that do not exist or do not emit parseable JSON. Task 11 must not
call these; seam discovery's promise shrinks accordingly.

## Impact on Task 11

<one paragraph: what seam discovery can and cannot do with this version>
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/reviews/2026-08-20-repowise-capability-audit.md
git commit -m "docs(review): repowise capability audit for federation seam discovery"
```

---

### Task 2: Config and lockfile parsing

**Files:**
- Create: `kb-forge/speccraft/forge/peers.py`
- Create: `kb-forge/tests/test_peers.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `parse_block(lines) -> dict` — scalars and one-level `- ` lists.
  - `load_kbforge(path) -> dict` — parsed `kbforge.yaml`.
  - `self_alias(kbroot) -> str or None`
  - `declared_peers(kbroot) -> list` of dicts `{"alias": str, "kind": "path"|"remote", "locator": str, "kb_path": str}`
  - `load_lock(kbroot) -> dict` — `{"version": 1, "peers": [...]}`, `{"version": 1, "peers": []}` when absent or malformed.
  - `write_lock(kbroot, entries) -> None`
  - `LOCK_NAME = "peers.lock"`, `DEFAULT_KB_PATH = ".speccraft/kb"`, `LOCAL_PIN = "LOCAL"`

- [ ] **Step 1: Write the failing test**

Create `kb-forge/tests/test_peers.py`:

```python
import json, os, sys, tempfile, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "speccraft" / "forge"))
import peers


def _kbroot(tmp, kbforge_text):
    kbroot = os.path.join(tmp, ".speccraft")
    os.makedirs(kbroot, exist_ok=True)
    with open(os.path.join(kbroot, "kbforge.yaml"), "w", encoding="utf-8") as fh:
        fh.write(kbforge_text)
    return kbroot


def test_self_alias_read_from_config():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, "product: acme\nalias: web\n")
        assert peers.self_alias(kbroot) == "web"


def test_self_alias_absent_is_none():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, "product: acme\n")
        assert peers.self_alias(kbroot) is None


def test_declared_peers_splits_path_and_remote():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, (
            "product: acme\n"
            "alias: web\n"
            "peers:\n"
            "  - api = git@github.com:acme/api.git\n"
            "  - payments = ./services/payments\n"
        ))
        got = peers.declared_peers(kbroot)
        assert got == [
            {"alias": "api", "kind": "remote",
             "locator": "git@github.com:acme/api.git", "kb_path": ".speccraft/kb"},
            {"alias": "payments", "kind": "path",
             "locator": "./services/payments", "kb_path": ".speccraft/kb"},
        ]


def test_declared_peers_empty_when_no_block():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, "product: acme\n")
        assert peers.declared_peers(kbroot) == []


def test_load_lock_missing_returns_empty():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, "product: acme\n")
        assert peers.load_lock(kbroot) == {"version": 1, "peers": []}


def test_load_lock_malformed_returns_empty_not_raise():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, "product: acme\n")
        with open(os.path.join(kbroot, "peers.lock"), "w", encoding="utf-8") as fh:
            fh.write("{not json")
        assert peers.load_lock(kbroot) == {"version": 1, "peers": []}


def test_write_then_load_lock_roundtrips():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, "product: acme\n")
        entries = [{"alias": "api", "kind": "remote", "locator": "git@x:a.git",
                    "kb_path": ".speccraft/kb", "pin": "abc123",
                    "synced_at_commit": "def456"}]
        peers.write_lock(kbroot, entries)
        assert peers.load_lock(kbroot)["peers"] == entries
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd kb-forge && python3 -m pytest tests/test_peers.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'peers'`

- [ ] **Step 3: Write minimal implementation**

Create `kb-forge/speccraft/forge/peers.py`:

```python
#!/usr/bin/env python3
"""kb-forge federation (offline half) — reading peer KBs.

A KB may read facts from peer KBs so a fact is ratified once at its home and
referenced wherever it governs (spec 2026-08-20-federated-kb-design.md).

This module is deliberately pure: no network, no subprocess. Every network
operation lives in peersync.py. recall.py imports this module and never
imports peersync — that import graph is what guarantees a PreToolUse hook
cannot reach the network.
"""
import json, os

LOCK_NAME = "peers.lock"
DEFAULT_KB_PATH = ".speccraft/kb"
LOCAL_PIN = "LOCAL"


def parse_block(lines):
    """Scalars plus one-level '- ' lists. Same shape frontmatter() accepts."""
    meta, key = {}, None
    for line in lines:
        if line.startswith((" ", "\t")) and line.strip().startswith("- "):
            if key:
                meta.setdefault(key, []).append(
                    line.strip()[2:].strip().strip('"'))
        elif ":" in line:
            k, v = line.split(":", 1)
            key = k.strip()
            v = v.split("#")[0].strip().strip('"')
            if v:
                if v.startswith("[") and v.endswith("]"):
                    meta[key] = [x.strip().strip('"').strip("'")
                                 for x in v[1:-1].split(",") if x.strip()]
                else:
                    meta[key] = v
                key = None
    return meta


def load_kbforge(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return parse_block(fh.readlines())
    except OSError:
        return {}


def self_alias(kbroot):
    cfg = load_kbforge(os.path.join(kbroot, "kbforge.yaml"))
    a = cfg.get("alias")
    return a if isinstance(a, str) and a else None


def declared_peers(kbroot):
    """Parse `peers:` entries of the form `alias = locator`."""
    cfg = load_kbforge(os.path.join(kbroot, "kbforge.yaml"))
    raw = cfg.get("peers") or []
    if isinstance(raw, str):
        raw = [raw]
    exclude = set(cfg.get("peers_exclude") or [])
    out = []
    for item in raw:
        if "=" not in item:
            continue
        alias, locator = item.split("=", 1)
        alias, locator = alias.strip(), locator.strip()
        if not alias or not locator or alias in exclude:
            continue
        kind = "path" if locator.startswith("./") or locator.startswith("/") \
            else "remote"
        out.append({"alias": alias, "kind": kind, "locator": locator,
                    "kb_path": DEFAULT_KB_PATH})
    return out


def load_lock(kbroot):
    empty = {"version": 1, "peers": []}
    try:
        with open(os.path.join(kbroot, LOCK_NAME), encoding="utf-8") as fh:
            data = json.load(fh)
        if not isinstance(data, dict) or not isinstance(data.get("peers"), list):
            return empty
        data.setdefault("version", 1)
        return data
    except (OSError, ValueError):
        return empty


def write_lock(kbroot, entries):
    path = os.path.join(kbroot, LOCK_NAME)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"version": 1, "peers": entries}, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd kb-forge && python3 -m pytest tests/test_peers.py -v`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/peers.py kb-forge/tests/test_peers.py
git commit -m "feat(speccraft): peers.py — federation config and lockfile parsing"
```

---

### Task 3: Peer resolution to local directories

Turns lockfile entries into readable KB directories, or into coverage gaps. Pure: a remote peer resolves only if its cache directory already exists — populating it is Task 8's job.

**Files:**
- Modify: `kb-forge/speccraft/forge/peers.py`
- Modify: `kb-forge/tests/test_peers.py`

**Interfaces:**
- Consumes: `load_lock`, `LOCAL_PIN`, `DEFAULT_KB_PATH` (Task 2).
- Produces:
  - `cache_root() -> str` — `$KBFORGE_HOME/peers` or `~/.kbforge/peers`.
  - `cache_dir(locator, sha) -> str`
  - `resolve_peers(kbroot) -> (resolved, gaps)` where `resolved` is a list of `{"alias","kb_dir","pin"}` and `gaps` is a list of human-readable strings.

- [ ] **Step 1: Write the failing test**

Append to `kb-forge/tests/test_peers.py`:

```python
def test_cache_dir_is_stable_and_url_keyed():
    a = peers.cache_dir("git@github.com:acme/api.git", "abc123")
    b = peers.cache_dir("git@github.com:acme/api.git", "abc123")
    c = peers.cache_dir("git@github.com:acme/other.git", "abc123")
    assert a == b
    assert a != c
    assert a.endswith(os.path.join("abc123"))


def test_resolve_path_peer_reads_working_tree():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, "product: acme\nalias: root\n")
        mod_kb = os.path.join(tmp, "services", "payments", ".speccraft", "kb")
        os.makedirs(mod_kb)
        peers.write_lock(kbroot, [{
            "alias": "payments", "kind": "path", "locator": "./services/payments",
            "kb_path": ".speccraft/kb", "pin": "LOCAL", "synced_at_commit": "x"}])
        resolved, gaps = peers.resolve_peers(kbroot)
        assert gaps == []
        assert len(resolved) == 1
        assert resolved[0]["alias"] == "payments"
        assert os.path.realpath(resolved[0]["kb_dir"]) == os.path.realpath(mod_kb)
        assert resolved[0]["pin"] == "LOCAL"


def test_resolve_path_peer_missing_dir_is_a_gap_not_an_error():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, "product: acme\nalias: root\n")
        peers.write_lock(kbroot, [{
            "alias": "ghost", "kind": "path", "locator": "./services/ghost",
            "kb_path": ".speccraft/kb", "pin": "LOCAL", "synced_at_commit": "x"}])
        resolved, gaps = peers.resolve_peers(kbroot)
        assert resolved == []
        assert len(gaps) == 1
        assert "ghost" in gaps[0]


def test_resolve_remote_peer_without_cache_is_a_gap(monkeypatch=None):
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["KBFORGE_HOME"] = os.path.join(tmp, "home")
        try:
            kbroot = _kbroot(tmp, "product: acme\nalias: web\n")
            peers.write_lock(kbroot, [{
                "alias": "api", "kind": "remote", "locator": "git@x:acme/api.git",
                "kb_path": ".speccraft/kb", "pin": "deadbeef",
                "synced_at_commit": "x"}])
            resolved, gaps = peers.resolve_peers(kbroot)
            assert resolved == []
            assert len(gaps) == 1
            assert "api" in gaps[0] and "deadbeef"[:7] in gaps[0]
        finally:
            del os.environ["KBFORGE_HOME"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd kb-forge && python3 -m pytest tests/test_peers.py -v`
Expected: FAIL with `AttributeError: module 'peers' has no attribute 'cache_dir'`

- [ ] **Step 3: Write minimal implementation**

Append to `kb-forge/speccraft/forge/peers.py`:

```python
import hashlib


def cache_root():
    home = os.environ.get("KBFORGE_HOME")
    if not home:
        home = os.path.join(os.path.expanduser("~"), ".kbforge")
    return os.path.join(home, "peers")


def cache_dir(locator, sha):
    """Content-addressed by (remote, commit). Immutable: a new pin is a new
    directory, so there is no invalidation logic to get wrong. Keyed by URL
    rather than alias so sibling repos share one entry."""
    key = hashlib.sha256(locator.encode("utf-8")).hexdigest()[:16]
    return os.path.join(cache_root(), key, sha)


def resolve_peers(kbroot):
    """Map lockfile entries to readable KB directories.

    Returns (resolved, gaps). Never raises, never denies: an unreadable peer
    is a coverage gap, matching deps0's rule that an absent scanner is
    recorded, never silently skipped.
    """
    repo_root = os.path.dirname(os.path.abspath(kbroot))
    resolved, gaps = [], []
    for e in load_lock(kbroot).get("peers", []):
        alias = e.get("alias") or "?"
        kb_path = e.get("kb_path") or DEFAULT_KB_PATH
        pin = e.get("pin") or LOCAL_PIN
        if e.get("kind") == "path":
            kb_dir = os.path.join(repo_root, e.get("locator", ""), kb_path)
        else:
            kb_dir = os.path.join(
                cache_dir(e.get("locator", ""), pin), kb_path)
        if os.path.isdir(kb_dir):
            resolved.append({"alias": alias, "kb_dir": kb_dir, "pin": pin})
        else:
            gaps.append(
                "peer %s unavailable at %s (pin %s) — facts not loaded"
                % (alias, kb_dir, pin[:7]))
    return resolved, gaps
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd kb-forge && python3 -m pytest tests/test_peers.py -v`
Expected: PASS (11 tests)

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/peers.py kb-forge/tests/test_peers.py
git commit -m "feat(speccraft): resolve peers to local KB dirs; absent peer is a coverage gap"
```

---

### Task 4: Move KB reading into peers.py

Pure refactor. `peers.py` needs `frontmatter` and `collect`; importing them back from `recall.py` would make the pure module depend on the CLI module.

**Files:**
- Modify: `kb-forge/speccraft/forge/peers.py`
- Modify: `kb-forge/speccraft/forge/recall.py:57-99`
- Modify: `kb-forge/tests/test_peers.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `peers.frontmatter(path) -> dict`, `peers.collect_kb(kbroot) -> [(relpath, meta, anchors)]`. `recall.frontmatter` and `recall.collect` remain importable names, re-exported.

- [ ] **Step 1: Write the failing test**

Append to `kb-forge/tests/test_peers.py`:

```python
def test_collect_kb_reads_facts_with_anchors():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, "product: acme\n")
        d = os.path.join(kbroot, "kb", "normative")
        os.makedirs(d)
        with open(os.path.join(d, "01-invariants.md"), "w", encoding="utf-8") as fh:
            fh.write("---\nstatus: ratified\nanchors: [src/pay/, topic:money]\n---\nbody\n")
        got = peers.collect_kb(kbroot)
        assert len(got) == 1
        relpath, meta, anchors = got[0]
        assert relpath.replace(os.sep, "/") == "kb/normative/01-invariants.md"
        assert meta["status"] == "ratified"
        assert anchors == ["src/pay/", "topic:money"]


def test_collect_kb_skips_derived_and_unanchored():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, "product: acme\n")
        os.makedirs(os.path.join(kbroot, "kb", "derived"))
        os.makedirs(os.path.join(kbroot, "kb", "inferred"))
        with open(os.path.join(kbroot, "kb", "derived", "inventory.md"),
                  "w", encoding="utf-8") as fh:
            fh.write("---\nanchors: [src/]\n---\n")
        with open(os.path.join(kbroot, "kb", "inferred", "no-anchor.md"),
                  "w", encoding="utf-8") as fh:
            fh.write("---\nstatus: observed\n---\n")
        assert peers.collect_kb(kbroot) == []


def test_recall_still_exposes_collect_and_frontmatter():
    import recall
    assert recall.collect is peers.collect_kb
    assert recall.frontmatter is peers.frontmatter
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd kb-forge && python3 -m pytest tests/test_peers.py -v`
Expected: FAIL with `AttributeError: module 'peers' has no attribute 'collect_kb'`

- [ ] **Step 3: Move the functions**

Append to `kb-forge/speccraft/forge/peers.py` — copy `frontmatter` verbatim from `recall.py:57-83`, then:

```python
def frontmatter(path):
    """Parse the leading YAML block just enough: scalars + one-level lists."""
    with open(path, encoding="utf-8") as fh:
        if fh.readline().strip() != "---":
            return {}
        body = []
        for line in fh:
            if line.strip() == "---":
                break
            body.append(line)
    return parse_block(body)


def collect_kb(kbroot):
    """Every anchored fact under a KB root, as (relpath, meta, anchors)."""
    facts = []
    for root, dirs, files in os.walk(kbroot):
        dirs[:] = [d for d in dirs if d not in {".git", "derived"}]
        for f in sorted(files):
            if not f.endswith(".md"):
                continue
            p = os.path.join(root, f)
            meta = frontmatter(p)
            anchors = meta.get("anchors") or []
            if isinstance(anchors, str):
                anchors = [anchors]
            if anchors:
                facts.append((os.path.relpath(p, kbroot), meta, anchors))
    return facts
```

In `kb-forge/speccraft/forge/recall.py`, delete the `frontmatter` (lines 57-83) and `collect` (lines 85-99) definitions and add after the existing imports on line 28:

```python
import peers
from peers import frontmatter, collect_kb as collect  # re-exported for callers
```

- [ ] **Step 4: Run the full suite to verify nothing regressed**

Run: `cd kb-forge && python3 -m pytest tests/ -v && speccraft/forge/session-kit/evals/self-test.sh`
Expected: PASS — pytest green, self-test reports 0 failures. This is the guard that the refactor changed no behavior.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/peers.py kb-forge/speccraft/forge/recall.py kb-forge/tests/test_peers.py
git commit -m "refactor(speccraft): move KB reading from recall.py into peers.py"
```

---

### Task 5: Qualified anchor grammar

**Files:**
- Modify: `kb-forge/speccraft/forge/peers.py`
- Modify: `kb-forge/tests/test_peers.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `qualify(anchor) -> (alias_or_None, bare_anchor)` and `local_anchors(anchors, me) -> list` — the anchors from a fact that apply to the repo whose alias is `me`.

- [ ] **Step 1: Write the failing test**

Append to `kb-forge/tests/test_peers.py`:

```python
def test_qualify_splits_alias_prefix():
    assert peers.qualify("api::src/pay/") == ("api", "src/pay/")
    assert peers.qualify("src/pay/") == (None, "src/pay/")
    assert peers.qualify("topic:money") == (None, "topic:money")


def test_qualify_ignores_single_colon_and_trailing_forms():
    assert peers.qualify("topic:a::b") == ("topic:a", "b")
    assert peers.qualify("::x") == (None, "::x")
    assert peers.qualify("api::") == (None, "api::")


def test_local_anchors_keeps_bare_and_self_qualified():
    anchors = ["src/a.py", "web::src/b.py", "api::src/c.py", "topic:money"]
    assert peers.local_anchors(anchors, "web") == [
        "src/a.py", "src/b.py", "topic:money"]


def test_local_anchors_without_self_alias_keeps_only_bare():
    anchors = ["src/a.py", "web::src/b.py"]
    assert peers.local_anchors(anchors, None) == ["src/a.py"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd kb-forge && python3 -m pytest tests/test_peers.py::test_qualify_splits_alias_prefix -v`
Expected: FAIL with `AttributeError: module 'peers' has no attribute 'qualify'`

- [ ] **Step 3: Write minimal implementation**

Append to `kb-forge/speccraft/forge/peers.py`:

```python
def qualify(anchor):
    """Split `alias::path` into (alias, path). Bare anchors yield (None, a).

    An empty alias or empty path is not a qualification — it is a literal
    anchor, returned unchanged so a typo degrades to 'never matches' rather
    than to 'matches everything'.
    """
    if "::" not in anchor:
        return None, anchor
    alias, rest = anchor.split("::", 1)
    if not alias or not rest:
        return None, anchor
    return alias, rest


def local_anchors(anchors, me):
    """The anchors of a fact that govern the repo whose alias is `me`.

    Bare anchors are always local (unchanged behavior, no migration).
    `me::path` contributes `path`. Anchors qualified to any other alias are
    ignored here — they govern that peer, not us.
    """
    out = []
    for a in anchors:
        alias, bare = qualify(a)
        if alias is None:
            out.append(bare)
        elif me and alias == me:
            out.append(bare)
    return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd kb-forge && python3 -m pytest tests/test_peers.py -v`
Expected: PASS (18 tests)

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/peers.py kb-forge/tests/test_peers.py
git commit -m "feat(speccraft): alias::path anchor grammar (additive; bare anchors unchanged)"
```

---

### Task 6: Federated collection

**Files:**
- Modify: `kb-forge/speccraft/forge/peers.py`
- Modify: `kb-forge/tests/test_peers.py`

**Interfaces:**
- Consumes: `resolve_peers`, `collect_kb`, `self_alias`, `local_anchors`.
- Produces: `collect_federated(kbroot) -> (facts, gaps)` where each fact is a 4-tuple `(display_path, meta, anchors, origin)` — `origin` is `None` for local facts and the peer alias otherwise, and `anchors` are already reduced to the anchors that govern *this* repo.

- [ ] **Step 1: Write the failing test**

Append to `kb-forge/tests/test_peers.py`:

```python
def _write_fact(kbdir, lane, name, text):
    d = os.path.join(kbdir, lane)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name), "w", encoding="utf-8") as fh:
        fh.write(text)


def test_collect_federated_merges_local_and_peer_facts():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, "product: acme\nalias: web\n")
        _write_fact(os.path.join(kbroot, "kb"), "inferred", "local.md",
                    "---\nstatus: observed\nanchors: [src/local.ts]\n---\n")
        peer_kb = os.path.join(tmp, "services", "api", ".speccraft", "kb")
        os.makedirs(peer_kb)
        _write_fact(peer_kb, "normative", "seam.md",
                    "---\nstatus: ratified\n"
                    "anchors: [api::src/pay/, web::src/api/pay.ts]\n---\n")
        peers.write_lock(kbroot, [{
            "alias": "api", "kind": "path", "locator": "./services/api",
            "kb_path": ".speccraft/kb", "pin": "LOCAL", "synced_at_commit": "x"}])

        facts, gaps = peers.collect_federated(kbroot)
        assert gaps == []
        by_origin = {f[3]: f for f in facts}
        assert set(by_origin) == {None, "api"}
        # local fact keeps its bare anchor
        assert by_origin[None][2] == ["src/local.ts"]
        # peer fact is reduced to the anchors that govern *this* repo
        assert by_origin["api"][2] == ["src/api/pay.ts"]
        assert by_origin["api"][0] == "api::kb/normative/seam.md"


def test_collect_federated_drops_peer_fact_that_does_not_govern_us():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, "product: acme\nalias: web\n")
        peer_kb = os.path.join(tmp, "services", "api", ".speccraft", "kb")
        os.makedirs(peer_kb)
        _write_fact(peer_kb, "normative", "internal.md",
                    "---\nstatus: ratified\nanchors: [api::src/internal/]\n---\n")
        peers.write_lock(kbroot, [{
            "alias": "api", "kind": "path", "locator": "./services/api",
            "kb_path": ".speccraft/kb", "pin": "LOCAL", "synced_at_commit": "x"}])
        facts, gaps = peers.collect_federated(kbroot)
        assert [f for f in facts if f[3] == "api"] == []


def test_collect_federated_returns_gaps_and_still_returns_local_facts():
    with tempfile.TemporaryDirectory() as tmp:
        kbroot = _kbroot(tmp, "product: acme\nalias: web\n")
        _write_fact(os.path.join(kbroot, "kb"), "inferred", "local.md",
                    "---\nstatus: observed\nanchors: [src/local.ts]\n---\n")
        peers.write_lock(kbroot, [{
            "alias": "ghost", "kind": "path", "locator": "./nope",
            "kb_path": ".speccraft/kb", "pin": "LOCAL", "synced_at_commit": "x"}])
        facts, gaps = peers.collect_federated(kbroot)
        assert len(facts) == 1 and facts[0][3] is None
        assert len(gaps) == 1 and "ghost" in gaps[0]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd kb-forge && python3 -m pytest tests/test_peers.py -k federated -v`
Expected: FAIL with `AttributeError: module 'peers' has no attribute 'collect_federated'`

- [ ] **Step 3: Write minimal implementation**

Append to `kb-forge/speccraft/forge/peers.py`:

```python
def collect_federated(kbroot):
    """Local facts plus peer facts that govern this repo.

    Each fact is (display_path, meta, anchors, origin). `anchors` are already
    reduced via local_anchors(), so callers match them exactly as before.
    Peer facts whose anchors govern only other repos are dropped here rather
    than filtered downstream.
    """
    me = self_alias(kbroot)
    facts = [(p, m, local_anchors(a, me), None) for p, m, a in collect_kb(kbroot)]
    facts = [f for f in facts if f[2]]

    resolved, gaps = resolve_peers(kbroot)
    for peer in resolved:
        for p, m, a in collect_kb(peer["kb_dir"]):
            mine = local_anchors(a, me)
            if not mine:
                continue
            display = "%s::%s" % (peer["alias"], p.replace(os.sep, "/"))
            m = dict(m)
            m["_pin"] = peer["pin"]
            facts.append((display, m, mine, peer["alias"]))
    return facts, gaps
```

Note: local facts with only foreign-qualified anchors are dropped by the
`if f[2]` filter, which is correct — a fact in this repo anchored solely to
`api::` governs the peer, not us.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd kb-forge && python3 -m pytest tests/test_peers.py -v`
Expected: PASS (21 tests)

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/peers.py kb-forge/tests/test_peers.py
git commit -m "feat(speccraft): collect_federated — local + peer facts, origin-tagged"
```

---

### Task 7: Wire federation into recall, with fail-open

The behavioral heart of Phase B. After this task, path peers work end to end with zero network.

**Files:**
- Modify: `kb-forge/speccraft/forge/recall.py:145,161-185`
- Create: `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`
- Modify: `kb-forge/speccraft/forge/session-kit/evals/self-test.sh`

**Interfaces:**
- Consumes: `peers.collect_federated(kbroot) -> (facts, gaps)`.
- Produces: recall output lines of the form `[status] api::kb/normative/seam.md   <- src/api/pay.ts   (api@a1b2c3d)`, and coverage-gap lines prefixed `coverage gap:`.

- [ ] **Step 1: Write the failing test**

Create `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`:

```bash
#!/bin/bash
# Federation eval suite — spec 2026-08-20-federated-kb-design.md.
# Asserts: qualified anchors match across a peer boundary, peer provenance is
# rendered, an absent peer is a loud coverage gap, and the gate FAILS OPEN.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FORGE="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
no(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert_contains(){ printf '%s' "$1" | grep -qE "$2" && ok || no "$3"; }
assert_not_contains(){ printf '%s' "$1" | grep -qE "$2" && no "$3" || ok; }

# A monorepo: root .speccraft (trust boundary) + one module KB (peer).
mk_monorepo(){
  local R; R=$(mktemp -d)
  mkdir -p "$R/.speccraft/kb/inferred" \
           "$R/services/api/.speccraft/kb/normative" \
           "$R/src/api"
  printf 'product: fixture\nalias: web\n' > "$R/.speccraft/kbforge.yaml"
  printf -- '---\nstatus: observed\nanchors: [src/local.ts]\n---\nlocal\n' \
    > "$R/.speccraft/kb/inferred/local.md"
  printf -- '---\nstatus: ratified\nanchors: [api::src/pay/, web::src/api/pay.ts]\n---\nseam\n' \
    > "$R/services/api/.speccraft/kb/normative/seam.md"
  cat > "$R/.speccraft/peers.lock" <<'LOCK'
{
  "version": 1,
  "peers": [
    {"alias": "api", "kind": "path", "locator": "./services/api",
     "kb_path": ".speccraft/kb", "pin": "LOCAL", "synced_at_commit": "x"}
  ]
}
LOCK
  echo "$R"
}

R=$(mk_monorepo)
CFG="$R/.speccraft/kbforge.yaml"

# --- a peer's seam fact matches on OUR path, via the web:: qualification
OUT=$(python3 "$FORGE/recall.py" --config "$CFG" --files src/api/pay.ts 2>&1)
assert_contains "$OUT" 'api::kb/normative/seam\.md' "federation: peer fact matched"
assert_contains "$OUT" 'ratified' "federation: peer lane rendered"
assert_contains "$OUT" '\(api@LOCAL\)' "federation: peer provenance rendered"

# --- local facts still match with bare anchors (no migration)
OUT=$(python3 "$FORGE/recall.py" --config "$CFG" --files src/local.ts 2>&1)
assert_contains "$OUT" 'kb/inferred/local\.md' "federation: local fact unchanged"
assert_not_contains "$OUT" 'api::' "federation: unrelated peer fact not pulled in"

# --- anchors qualified to a foreign alias never match here
OUT=$(python3 "$FORGE/recall.py" --config "$CFG" --files src/pay/x.ts 2>&1)
assert_contains "$OUT" 'NO KB COVERAGE' "federation: api:: anchor does not govern us"

# --- the peer's normative fact has teeth in the gate
python3 "$FORGE/recall.py" --config "$CFG" --files src/api/pay.ts --gate-check
[ $? -eq 3 ] && ok || no "federation: peer normative fact denies via gate"

# --- MISSING PEER FAILS OPEN (Confusion Protocol / kb-freeze precedent)
cat > "$R/.speccraft/peers.lock" <<'LOCK'
{
  "version": 1,
  "peers": [
    {"alias": "ghost", "kind": "path", "locator": "./services/ghost",
     "kb_path": ".speccraft/kb", "pin": "LOCAL", "synced_at_commit": "x"}
  ]
}
LOCK
OUT=$(python3 "$FORGE/recall.py" --config "$CFG" --files src/api/pay.ts 2>&1)
assert_contains "$OUT" 'coverage gap: .*ghost' "federation: absent peer is a loud gap"
python3 "$FORGE/recall.py" --config "$CFG" --files src/api/pay.ts --gate-check
[ $? -eq 0 ] && ok || no "federation: absent peer FAILS OPEN (must not deny)"

# --- a malformed lockfile also fails open
printf '{not json' > "$R/.speccraft/peers.lock"
python3 "$FORGE/recall.py" --config "$CFG" --files src/api/pay.ts --gate-check
[ $? -eq 0 ] && ok || no "federation: malformed lockfile fails open"

rm -rf "$R"
echo "federation: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

```bash
chmod +x kb-forge/speccraft/forge/session-kit/evals/test-federation.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`
Expected: FAIL — several assertions fail because `recall.py` still calls the local-only `collect()` and renders no provenance or gaps.

- [ ] **Step 3: Wire federation into recall.py**

In `kb-forge/speccraft/forge/recall.py`, replace line 145 (`facts = collect(kbroot)`) with:

```python
    facts_4, gaps = peers.collect_federated(kbroot)
    # internal query modes below want the historical 3-tuple shape
    facts = [(p, m, a) for p, m, a, _ in facts_4]
```

Replace the matched/unmatched loop (lines 161-170) with:

```python
    matched, unmatched = [], []
    for kbf, meta, anchors, origin in facts_4:
        lane_key = kbf.split("::", 1)[1] if origin else kbf
        if lanes and not any(lane_key.startswith(f"kb/{l}/") for l in lanes):
            continue
        hits = match(anchors, files, set(args.topic))
        status = (meta.get("status") or meta.get("ruling") or "?").split()[0]
        if hits:
            matched.append((RANK.get(status, 9), kbf, status, hits, meta, origin))
        else:
            unmatched.append((RANK.get(status, 9), kbf, status, hits))
```

Replace the render loop (lines 176-181) with:

```python
    for _, kbf, status, hits, meta, origin in matched:
        prov = "   (%s@%s)" % (origin, str(meta.get("_pin", "?"))[:7]) if origin else ""
        print(f"[{status:<20}] {kbf}   <- {', '.join(hits)}{prov}")
        if meta.get("seam"):
            print(f"        → USE: {meta['seam']}")
        if meta.get("avoid"):
            print(f"        → AVOID: {meta['avoid']}")
```

Add gap reporting immediately after that loop, before the `--all` block:

```python
    for g in gaps:
        print("coverage gap: %s" % g)
```

The `--gate-check` exit at line 192 needs no change: an unresolved peer contributes no facts, so `matched` simply lacks them and the gate exits 0. **That is the fail-open behavior** — it is a property of not adding facts, not a special case, which is why it cannot regress the way `kb-freeze` and the Confusion Protocol did.

- [ ] **Step 4: Run tests to verify they pass**

Run: `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`
Expected: `federation: 10 passed, 0 failed`

Run: `cd kb-forge && python3 -m pytest tests/ -v && speccraft/forge/session-kit/evals/self-test.sh`
Expected: both green — no existing behavior changed.

- [ ] **Step 5: Wire into the suite**

In `kb-forge/speccraft/forge/session-kit/evals/self-test.sh`, append before the final tally:

```bash
# ---------- section: federation ----------
if run_section federation; then
  OUT=$("$HERE/test-federation.sh" 2>&1)
  assert_contains "$OUT" '0 failed' "federation: suite green"
fi
```

- [ ] **Step 6: Commit**

```bash
git add kb-forge/speccraft/forge/recall.py \
        kb-forge/speccraft/forge/session-kit/evals/test-federation.sh \
        kb-forge/speccraft/forge/session-kit/evals/self-test.sh
git commit -m "feat(speccraft): federated recall — peer facts, provenance, fail-open gate"
```

---

### Task 8: Peer fetch and cache materialization

Phase C begins. All network lives here.

**Files:**
- Create: `kb-forge/speccraft/forge/peersync.py`
- Modify: `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`

**Interfaces:**
- Consumes: `peers.cache_dir`, `peers.declared_peers`, `peers.write_lock`, `peers.DEFAULT_KB_PATH`, `peers.LOCAL_PIN`.
- Produces:
  - `git(args, cwd=None, timeout=120) -> (rc, stdout, stderr)`
  - `peer_ratified_through(url) -> str or None` — step one of pin resolution.
  - `materialize(url, sha, kb_path) -> str or None` — populates the cache atomically, returns the cache dir.
  - `sync(kbroot) -> (entries, gaps)`

- [ ] **Step 1: Write the failing test**

Append to `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`, before the `rm -rf "$R"` line:

```bash
# ---------- remote peers: fetch, pin resolution, cache ----------
export KBFORGE_HOME=$(mktemp -d)

# Build a bare "remote" whose KB carries a ratified_through anchor.
UP=$(mktemp -d); BARE=$(mktemp -d)/api.git
git init --bare -q "$BARE"
git -C "$BARE" config uploadpack.allowFilter true
git -C "$BARE" config uploadpack.allowAnySHA1InWant true
(
  cd "$UP" && git init -q && git config user.email t@t && git config user.name t
  mkdir -p .speccraft/kb/normative
  printf 'product: api\nalias: api\n' > .speccraft/kbforge.yaml
  printf -- '---\nstatus: ratified\nanchors: [api::src/pay/, web::src/api/pay.ts]\n---\nseam\n' \
    > .speccraft/kb/normative/seam.md
  git add -A && git commit -qm one
  printf 'ratified_through: %s\n' "$(git rev-parse HEAD)" >> .speccraft/kbforge.yaml
  git add -A && git commit -qm pin
  git remote add origin "$BARE" && git push -q origin HEAD:refs/heads/main
) >/dev/null 2>&1

W=$(mktemp -d); mkdir -p "$W/.speccraft/kb/inferred" "$W/src/api"
printf 'product: fixture\nalias: web\npeers:\n  - api = %s\n' "$BARE" \
  > "$W/.speccraft/kbforge.yaml"

OUT=$(python3 "$FORGE/peersync.py" --config "$W/.speccraft/kbforge.yaml" 2>&1)
assert_contains "$OUT" 'api' "sync: peer reported"
grep -q '"alias": "api"' "$W/.speccraft/peers.lock" && ok || no "sync: lockfile written"
grep -q '"pin": "[0-9a-f]\{40\}"' "$W/.speccraft/peers.lock" && ok || no "sync: pin is a full sha"

# the pin is the peer's ratified_through, NOT its tip
PINNED=$(python3 -c "import json;print(json.load(open('$W/.speccraft/peers.lock'))['peers'][0]['pin'])")
RT=$(grep '^ratified_through:' "$UP/.speccraft/kbforge.yaml" | awk '{print $2}')
[ "$PINNED" = "$RT" ] && ok || no "sync: pinned at ratified_through, not tip"

# fetched KB is readable and recall now matches across the remote peer
OUT=$(python3 "$FORGE/recall.py" --config "$W/.speccraft/kbforge.yaml" --files src/api/pay.ts 2>&1)
assert_contains "$OUT" 'api::kb/normative/seam\.md' "sync: remote peer fact recalled"
assert_not_contains "$OUT" 'coverage gap' "sync: no gap after successful sync"

# only KB material was fetched — never source
CACHED=$(find "$KBFORGE_HOME/peers" -name seam.md | head -1)
[ -n "$CACHED" ] && ok || no "sync: KB materialized into cache"

# unreachable remote leaves the pin alone and reports a gap
printf 'product: fixture\nalias: web\npeers:\n  - api = /nonexistent/repo.git\n' \
  > "$W/.speccraft/kbforge.yaml"
OUT=$(python3 "$FORGE/peersync.py" --config "$W/.speccraft/kbforge.yaml" 2>&1)
assert_contains "$OUT" 'coverage gap' "sync: unreachable remote is a gap"
[ $? -ne 0 ] || ok   # sync exits 0 even on gaps

rm -rf "$UP" "$BARE" "$W" "$KBFORGE_HOME"
unset KBFORGE_HOME
```

- [ ] **Step 2: Run it to verify it fails**

Run: `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`
Expected: FAIL — `python3: can't open file '.../peersync.py'`

- [ ] **Step 3: Write minimal implementation**

Create `kb-forge/speccraft/forge/peersync.py`:

```python
#!/usr/bin/env python3
"""kb-forge federation (network half) — fetching peer KBs.

Everything that touches the network lives here. peers.py must never import
this module, and neither may recall.py or gate.py: a PreToolUse hook that
could reach the network would make gate decisions depend on connectivity,
and a gate that denies on one machine and passes on another is worse than
no gate.

Run at sync points only: speccraft init, the post-commit ship loop, and an
explicit `speccraft sync`.
"""
import argparse, os, shutil, subprocess, sys, tempfile

import peers

FETCH_TIMEOUT = 120


def git(args, cwd=None, timeout=FETCH_TIMEOUT):
    try:
        p = subprocess.run(["git"] + args, cwd=cwd, timeout=timeout,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return (p.returncode,
                p.stdout.decode("utf-8", "replace"),
                p.stderr.decode("utf-8", "replace"))
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, "", str(e)


def _sparse_fetch(url, ref, paths, dest):
    """Blobless partial fetch of `paths` at `ref` into `dest`. Kilobytes,
    regardless of repo size. Auth is inherited from the user's git
    credential helper — no new secret handling."""
    rc, _, err = git(["init", "-q", dest])
    if rc:
        return err
    for args in (["remote", "add", "origin", url],
                 ["config", "core.sparseCheckout", "true"],
                 ["sparse-checkout", "init"],
                 ["sparse-checkout", "set"] + list(paths)):
        rc, _, err = git(args, cwd=dest)
        if rc:
            return err
    rc, _, err = git(["fetch", "--filter=blob:none", "--depth", "1",
                      "origin", ref], cwd=dest)
    if rc:
        # Fallback: server refuses reachable-SHA fetch. Fetch the default
        # branch and resolve locally. NEVER fall forward to the tip — using a
        # commit newer than the pin would enforce unratified facts.
        rc2, _, err2 = git(["fetch", "--filter=blob:none", "origin"], cwd=dest)
        if rc2:
            return err or err2
        rc3, _, err3 = git(["checkout", "-q", ref], cwd=dest)
        return None if rc3 == 0 else (err3 or err)
    rc, _, err = git(["checkout", "-q", "FETCH_HEAD"], cwd=dest)
    return None if rc == 0 else err


def peer_ratified_through(url):
    """Step one of pin resolution: read the peer's trust boundary from its
    branch tip, cheaply, so step two can materialize that exact commit."""
    tmp = tempfile.mkdtemp(prefix="kbf-probe-")
    try:
        err = _sparse_fetch(url, "HEAD", [".speccraft"], tmp)
        if err:
            return None
        cfg = peers.load_kbforge(
            os.path.join(tmp, ".speccraft", "kbforge.yaml"))
        rt = cfg.get("ratified_through")
        return rt if isinstance(rt, str) and rt else None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def materialize(url, sha, kb_path):
    """Populate the content-addressed cache for (url, sha). Writes to a temp
    dir and atomically renames: parallel agent fan-out means concurrent
    readers, and a half-written peer KB would present as an intermittent."""
    dest = peers.cache_dir(url, sha)
    if os.path.isdir(os.path.join(dest, kb_path)):
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="kbf-mat-", dir=os.path.dirname(dest))
    try:
        err = _sparse_fetch(url, sha, [kb_path, ".speccraft/kbforge.yaml"], tmp)
        if err:
            return None
        try:
            os.replace(tmp, dest)
        except OSError:
            if not os.path.isdir(dest):
                raise
            shutil.rmtree(tmp, ignore_errors=True)
        return dest
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        return None


def sync(kbroot):
    """Resolve every declared peer to a pin and materialize it. Returns
    (entries, gaps). Never raises; an unreachable peer keeps its previous
    pin so a network blip cannot silently change what this repo enforces."""
    repo_root = os.path.dirname(os.path.abspath(kbroot))
    previous = {e.get("alias"): e for e in peers.load_lock(kbroot).get("peers", [])}
    rc, head, _ = git(["rev-parse", "--short", "HEAD"], cwd=repo_root)
    head = head.strip() if rc == 0 else "unknown"

    entries, gaps = [], []
    for p in peers.declared_peers(kbroot):
        if p["kind"] == "path":
            entries.append(dict(p, pin=peers.LOCAL_PIN, synced_at_commit=head))
            continue
        sha = peer_ratified_through(p["locator"])
        if not sha:
            gaps.append("peer %s unreachable or has no ratified_through — "
                        "keeping previous pin" % p["alias"])
            if p["alias"] in previous:
                entries.append(previous[p["alias"]])
            continue
        if materialize(p["locator"], sha, p["kb_path"]) is None:
            gaps.append("peer %s: could not materialize %s — keeping previous pin"
                        % (p["alias"], sha[:7]))
            if p["alias"] in previous:
                entries.append(previous[p["alias"]])
            continue
        entries.append(dict(p, pin=sha, synced_at_commit=head))
    peers.write_lock(kbroot, entries)
    return entries, gaps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    args = ap.parse_args()
    kbroot = os.path.dirname(os.path.abspath(args.config))
    entries, gaps = sync(kbroot)
    for e in entries:
        print("%-16s %s" % (e["alias"], str(e.get("pin", "?"))[:12]))
    for g in gaps:
        print("coverage gap: %s" % g)
    return 0   # sync never fails a caller


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`
Expected: `federation: 18 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/peersync.py \
        kb-forge/speccraft/forge/session-kit/evals/test-federation.sh
git commit -m "feat(speccraft): peersync.py — blobless peer fetch, two-step pin resolution"
```

---

### Task 9: Staleness detection and cache GC

**Files:**
- Modify: `kb-forge/speccraft/forge/peersync.py`
- Modify: `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`

**Interfaces:**
- Consumes: `peer_ratified_through`, `peers.load_lock`, `peers.cache_root`.
- Produces:
  - `staleness(kbroot) -> list` of `{"alias","pinned","current","stale"}`
  - `gc(kbroot_list, max_age_days=30) -> int` — count of pruned cache entries.

- [ ] **Step 1: Write the failing test**

Append to `test-federation.sh`, before the final `rm -rf`:

```bash
# ---------- staleness: warn, never block ----------
export KBFORGE_HOME=$(mktemp -d)
UP=$(mktemp -d); BARE=$(mktemp -d)/api.git
git init --bare -q "$BARE"
git -C "$BARE" config uploadpack.allowFilter true
git -C "$BARE" config uploadpack.allowAnySHA1InWant true
(
  cd "$UP" && git init -q && git config user.email t@t && git config user.name t
  mkdir -p .speccraft/kb/normative
  printf 'product: api\nalias: api\n' > .speccraft/kbforge.yaml
  printf -- '---\nstatus: ratified\nanchors: [web::src/api/pay.ts]\n---\nseam\n' \
    > .speccraft/kb/normative/seam.md
  git add -A && git commit -qm one
  printf 'ratified_through: %s\n' "$(git rev-parse HEAD)" >> .speccraft/kbforge.yaml
  git add -A && git commit -qm pin && git remote add origin "$BARE" \
    && git push -q origin HEAD:refs/heads/main
) >/dev/null 2>&1

W=$(mktemp -d); mkdir -p "$W/.speccraft" "$W/src/api"
printf 'product: fixture\nalias: web\npeers:\n  - api = %s\n' "$BARE" \
  > "$W/.speccraft/kbforge.yaml"
python3 "$FORGE/peersync.py" --config "$W/.speccraft/kbforge.yaml" >/dev/null 2>&1

OUT=$(python3 "$FORGE/peersync.py" --config "$W/.speccraft/kbforge.yaml" --check-stale 2>&1)
assert_not_contains "$OUT" 'STALE' "stale: fresh pin is not stale"

# peer ratifies further ahead
(
  cd "$UP" && printf -- '---\nstatus: ratified\nanchors: [web::src/api/new.ts]\n---\nnew\n' \
    > .speccraft/kb/normative/new.md
  git add -A && git commit -qm two
  sed -i.bak "s/^ratified_through: .*/ratified_through: $(git rev-parse HEAD)/" \
    .speccraft/kbforge.yaml && rm -f .speccraft/kbforge.yaml.bak
  git add -A && git commit -qm pin2 && git push -q origin HEAD:refs/heads/main
) >/dev/null 2>&1

OUT=$(python3 "$FORGE/peersync.py" --config "$W/.speccraft/kbforge.yaml" --check-stale 2>&1)
assert_contains "$OUT" 'STALE.*api' "stale: peer ahead is reported"

# staleness NEVER blocks: exit 0, and the gate still works off the old pin
python3 "$FORGE/peersync.py" --config "$W/.speccraft/kbforge.yaml" --check-stale >/dev/null 2>&1
[ $? -eq 0 ] && ok || no "stale: --check-stale exits 0 (warn, never block)"
python3 "$FORGE/recall.py" --config "$W/.speccraft/kbforge.yaml" \
  --files src/api/pay.ts --gate-check
[ $? -eq 3 ] && ok || no "stale: old pin still enforces its facts"
# the new fact is NOT enforced until the pin advances — consent is the pin
python3 "$FORGE/recall.py" --config "$W/.speccraft/kbforge.yaml" \
  --files src/api/new.ts --gate-check
[ $? -eq 0 ] && ok || no "stale: unpinned peer commit does not enforce here"

rm -rf "$UP" "$BARE" "$W" "$KBFORGE_HOME"
unset KBFORGE_HOME
```

- [ ] **Step 2: Run it to verify it fails**

Run: `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`
Expected: FAIL — `unrecognized arguments: --check-stale`

- [ ] **Step 3: Write minimal implementation**

Append to `kb-forge/speccraft/forge/peersync.py` before `main()`:

```python
def staleness(kbroot):
    """Compare each pinned peer against its current ratified_through.

    Runs only at sync time, when the network is already in hand. Reported
    through the stale-commit-guard's warning vocabulary rather than a second
    one, and never blocking.
    """
    out = []
    for e in peers.load_lock(kbroot).get("peers", []):
        if e.get("kind") != "remote":
            continue
        cur = peer_ratified_through(e.get("locator", ""))
        out.append({"alias": e.get("alias"), "pinned": e.get("pin"),
                    "current": cur, "stale": bool(cur and cur != e.get("pin"))})
    return out


def gc(kbroots, max_age_days=30):
    """Prune cache entries no lockfile references and older than max_age."""
    import time
    keep = set()
    for kbroot in kbroots:
        for e in peers.load_lock(kbroot).get("peers", []):
            if e.get("kind") == "remote":
                keep.add(peers.cache_dir(e.get("locator", ""), e.get("pin", "")))
    root = peers.cache_root()
    if not os.path.isdir(root):
        return 0
    cutoff = time.time() - max_age_days * 86400
    pruned = 0
    for key in os.listdir(root):
        kd = os.path.join(root, key)
        if not os.path.isdir(kd):
            continue
        for sha in os.listdir(kd):
            d = os.path.join(kd, sha)
            if d in keep or not os.path.isdir(d):
                continue
            try:
                if os.path.getmtime(d) < cutoff:
                    shutil.rmtree(d, ignore_errors=True)
                    pruned += 1
            except OSError:
                pass
    return pruned
```

Replace `main()` with:

```python
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--check-stale", action="store_true",
                    help="report peers whose ratified_through moved past our "
                         "pin; warns, never blocks")
    ap.add_argument("--gc", action="store_true",
                    help="prune unreferenced cache entries older than 30 days")
    args = ap.parse_args()
    kbroot = os.path.dirname(os.path.abspath(args.config))

    if args.check_stale:
        for s in staleness(kbroot):
            if s["stale"]:
                print("STALE  %-16s pinned %s, peer ratified %s"
                      % (s["alias"], str(s["pinned"])[:12], str(s["current"])[:12]))
            elif s["current"] is None:
                print("coverage gap: peer %s unreachable — staleness unknown"
                      % s["alias"])
        return 0

    if args.gc:
        print("pruned %d cache entries" % gc([kbroot]))
        return 0

    entries, gaps = sync(kbroot)
    for e in entries:
        print("%-16s %s" % (e["alias"], str(e.get("pin", "?"))[:12]))
    for g in gaps:
        print("coverage gap: %s" % g)
    return 0   # sync never fails a caller
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`
Expected: `federation: 23 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/peersync.py \
        kb-forge/speccraft/forge/session-kit/evals/test-federation.sh
git commit -m "feat(speccraft): peer staleness warning tier and cache GC"
```

---

### Task 10: `speccraft sync`, ship-loop wiring, briefing block

**Files:**
- Modify: `kb-forge/speccraft/cli.py:125-145`
- Modify: `kb-forge/speccraft/forge/session-kit/post-commit`
- Modify: `kb-forge/speccraft/forge/session-kit/hooks/kb-briefing.sh`
- Modify: `kb-forge/tests/test_cli.py`

**Interfaces:**
- Consumes: `peersync.py --config`, `peersync.py --check-stale`.
- Produces: `speccraft sync` CLI subcommand; a `Federation` block in the session briefing.

- [ ] **Step 1: Write the failing test**

Append to `kb-forge/tests/test_cli.py`:

```python
def test_sync_subcommand_is_registered():
    from speccraft import cli
    import io, contextlib, pytest
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        with pytest.raises(SystemExit):
            cli.main(["--help"])
    assert "sync" in buf.getvalue()
```

Append to `test-federation.sh` before the final `rm -rf`:

```bash
# ---------- briefing renders the federation block ----------
R2=$(mk_monorepo)
OUT=$(KB_ROOT="$R2/.speccraft" bash "$FORGE/session-kit/hooks/kb-briefing.sh" 2>&1)
assert_contains "$OUT" 'Federation' "briefing: federation block present"
assert_contains "$OUT" 'api' "briefing: peer listed"
rm -rf "$R2"
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd kb-forge && python3 -m pytest tests/test_cli.py -k sync -v`
Expected: FAIL — `assert "sync" in ...` fails; only `init` is registered.

- [ ] **Step 3: Implement**

In `kb-forge/speccraft/cli.py`, add beside `cmd_init`:

```python
def cmd_sync(args: argparse.Namespace) -> int:
    cfg = os.path.join(os.path.abspath(args.repo or "."), ".speccraft",
                       "kbforge.yaml")
    if not os.path.exists(cfg):
        print("no .speccraft/kbforge.yaml here — run `speccraft init` first")
        return 1
    return _run_forge_script("peersync.py", "--config", cfg)
```

Register it in `main()` alongside the existing `init` subparser:

```python
    p_sync = sub.add_parser("sync", help="fetch peer KBs and refresh peers.lock")
    p_sync.add_argument("repo", nargs="?", default=".")
    p_sync.set_defaults(func=cmd_sync)
```

In `kb-forge/speccraft/forge/session-kit/post-commit`, append after the existing ship-loop steps:

```bash
# Federation: refresh peer pins. Backgrounded and logged — never blocks a
# commit, never runs on the edit path. Mirrors how `repowise update` rides
# the ship loop.
if [ -f "$KB/peers.lock" ] || grep -q '^peers:' "$KB/kbforge.yaml" 2>/dev/null; then
  mkdir -p "$KB/evals"
  ( python3 "$FORGE/peersync.py" --config "$KB/kbforge.yaml" \
      >> "$KB/evals/peersync.log" 2>&1 ) &
fi
```

In `kb-forge/speccraft/forge/session-kit/hooks/kb-briefing.sh`, append after the existing two-anchor KB status block:

```bash
# Federation block — one session-start surface for the whole federation.
# Reads the lockfile and peer queues; never fetches (no network in hooks).
if [ -f "$KB/peers.lock" ]; then
  SELF=$(grep '^alias:' "$KB/kbforge.yaml" 2>/dev/null | awk '{print $2}')
  echo "Federation (self: ${SELF:-unset})"
  python3 - "$KB" <<'PY'
import json, os, sys
kb = sys.argv[1]
try:
    with open(os.path.join(kb, "peers.lock"), encoding="utf-8") as fh:
        entries = json.load(fh).get("peers", [])
except Exception:
    entries = []
sys.path.insert(0, os.environ.get("FORGE", ""))
for e in entries:
    alias = e.get("alias", "?")
    pin = str(e.get("pin", "?"))[:7]
    print("  %-14s %-8s" % (alias, pin))
PY
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd kb-forge && python3 -m pytest tests/ -v`
Expected: PASS

Run: `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh && kb-forge/speccraft/forge/session-kit/evals/self-test.sh`
Expected: both green

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/cli.py kb-forge/speccraft/forge/session-kit/post-commit \
        kb-forge/speccraft/forge/session-kit/hooks/kb-briefing.sh \
        kb-forge/tests/test_cli.py \
        kb-forge/speccraft/forge/session-kit/evals/test-federation.sh
git commit -m "feat(speccraft): speccraft sync, ship-loop peer refresh, briefing federation block"
```

---

### Task 11: Seam discovery via repowise (GATED on Task 1)

**Do not start this task until Task 1's audit says `SUFFICIENT` or `PARTIAL`.** If `PARTIAL`, implement only the surfaces its table marks as existing with valid JSON, and skip the rest. If `INSUFFICIENT`, skip this task entirely — Tasks 2–10 and 12 deliver working federation without it.

**Files:**
- Create: `kb-forge/speccraft/forge/seams.py`
- Modify: `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`

**Interfaces:**
- Consumes: `peers.declared_peers`, `peers.self_alias`, `REPOWISE_MIN_VERSION` from Task 1's audit.
- Produces: `propose_seams(kbroot) -> (facts_written, gaps)` writing to `kb/decisions/repowise-seams.md`.

- [ ] **Step 1: Write the failing test**

Append to `test-federation.sh` before the final `rm -rf`:

```bash
# ---------- seam discovery degrades loudly without the sidecar ----------
R3=$(mk_monorepo)
OUT=$(PATH=/usr/bin:/bin python3 "$FORGE/seams.py" \
        --config "$R3/.speccraft/kbforge.yaml" 2>&1)
assert_contains "$OUT" 'coverage gap: repowise' "seams: absent sidecar is a loud gap"
[ $? -eq 0 ] || ok
# and federation still works with no sidecar at all
OUT=$(PATH=/usr/bin:/bin python3 "$FORGE/recall.py" \
        --config "$R3/.speccraft/kbforge.yaml" --files src/api/pay.ts 2>&1)
assert_contains "$OUT" 'api::kb/normative/seam\.md' "seams: federation works sans repowise"
# mined seams NEVER land in normative
assert_not_contains "$(ls "$R3/.speccraft/kb/normative" 2>&1)" 'repowise-seams' \
  "seams: nothing written to normative"
rm -rf "$R3"
```

- [ ] **Step 2: Run to verify it fails**

Run: `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`
Expected: FAIL — `can't open file '.../seams.py'`

- [ ] **Step 3: Write minimal implementation**

Create `kb-forge/speccraft/forge/seams.py`:

```python
#!/usr/bin/env python3
"""Seam discovery — repowise workspace contracts as ratification candidates.

Mined seams are machine-extracted, so they enter the KB the way every other
observation does: graded, below normative, awaiting the founder. They land in
kb/decisions/ as pending-ratification and are promoted to normative exactly
one way — speccraft-ratify. Writing them straight to normative would be
self-ratification by sidecar, and the lane guard would block it anyway.

Absent, outdated, or offline sidecar: skip discovery, print a coverage gap,
exit 0. Federation itself never depends on this module.
"""
import argparse, json, os, subprocess, sys

import peers

REPOWISE_MIN_VERSION = ""   # set from docs/superpowers/reviews/2026-08-20-repowise-capability-audit.md
LANE = os.path.join("kb", "decisions")
OUT_NAME = "repowise-seams.md"


def _repowise(args, cwd, timeout=60):
    try:
        p = subprocess.run(["repowise"] + args, cwd=cwd, timeout=timeout,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if p.returncode != 0:
            return None
        return json.loads(p.stdout.decode("utf-8", "replace"))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def propose_seams(kbroot):
    repo = os.path.dirname(os.path.abspath(kbroot))
    me = peers.self_alias(kbroot) or "self"
    data = _repowise(["workspace", "diagnostics", "--json"], repo)
    if data is None:
        return 0, ["repowise unavailable or wrong version — seam discovery "
                   "skipped (federation unaffected)"]

    lines = ["# Repowise-mined seams",
             "",
             "Machine-extracted contract candidates. Promote with "
             "`speccraft-ratify`; never edit status by hand.",
             ""]
    n = 0
    for c in data.get("contracts", []):
        provider, consumer = c.get("provider", {}), c.get("consumer", {})
        pa, ca = provider.get("alias"), consumer.get("alias")
        if not pa or not ca or me not in (pa, ca):
            continue
        n += 1
        lines += [
            "## SEAM-%s" % c.get("id", n),
            "---",
            "status: pending-ratification",
            "source: repowise",
            "anchors: [%s::%s, %s::%s]" % (pa, provider.get("path", ""),
                                           ca, consumer.get("path", "")),
            "---",
            "%s (%s)" % (c.get("summary", "contract"), c.get("kind", "http")),
            "",
        ]
    if not n:
        return 0, []
    d = os.path.join(kbroot, LANE)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, OUT_NAME), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    return n, []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    args = ap.parse_args()
    kbroot = os.path.dirname(os.path.abspath(args.config))
    n, gaps = propose_seams(kbroot)
    if n:
        print("proposed %d seam candidates -> %s/%s" % (n, LANE, OUT_NAME))
    for g in gaps:
        print("coverage gap: %s" % g)
    return 0   # never fails a caller


if __name__ == "__main__":
    sys.exit(main())
```

Set `REPOWISE_MIN_VERSION` to the value from Task 1's audit document.

- [ ] **Step 4: Run tests to verify they pass**

Run: `kb-forge/speccraft/forge/session-kit/evals/test-federation.sh`
Expected: `federation: 28 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add kb-forge/speccraft/forge/seams.py \
        kb-forge/speccraft/forge/session-kit/evals/test-federation.sh
git commit -m "feat(speccraft): repowise seam discovery as pending-ratification candidates"
```

---

### Task 12: Packaging, docs, and spec reconciliation

**Files:**
- Modify: `kb-forge/pyproject.toml`
- Modify: `kb-forge/tests/test_packaging_completeness.py`
- Modify: `kb-forge/tests/test_forge_standalone_imports.py`
- Modify: `docs/superpowers/specs/2026-08-20-federated-kb-design.md`
- Modify: `kb-forge/README.md`

**Interfaces:**
- Consumes: every module from Tasks 2–11.
- Produces: shipped package including the new forge scripts.

- [ ] **Step 1: Write the failing test**

Append to `kb-forge/tests/test_packaging_completeness.py`:

```python
def test_new_forge_modules_are_packaged():
    import speccraft, pathlib
    forge = pathlib.Path(speccraft.__file__).parent / "forge"
    for name in ("peers.py", "peersync.py", "seams.py"):
        assert (forge / name).exists(), f"{name} missing from the installed forge"
```

Append to `kb-forge/tests/test_forge_standalone_imports.py`:

```python
def test_peers_has_no_network_imports():
    """recall.py runs in a PreToolUse hook. peers.py is what it imports, so
    peers.py must not be able to reach the network — commit 75244a3 shows
    sibling-import layout is load-bearing here."""
    import pathlib, speccraft
    src = (pathlib.Path(speccraft.__file__).parent / "forge" / "peers.py").read_text(
        encoding="utf-8")
    for bad in ("import subprocess", "import socket", "import urllib", "import peersync"):
        assert bad not in src, f"peers.py must not {bad}"


def test_recall_does_not_import_peersync():
    import pathlib, speccraft
    src = (pathlib.Path(speccraft.__file__).parent / "forge" / "recall.py").read_text(
        encoding="utf-8")
    assert "peersync" not in src, "recall.py must never reach the network"
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd kb-forge && python3 -m pytest tests/test_packaging_completeness.py tests/test_forge_standalone_imports.py -v`
Expected: FAIL if `pyproject.toml`'s explicit packaging list (added in `504ad32`) does not name the new files.

- [ ] **Step 3: Fix packaging and docs**

Add `peers.py`, `peersync.py`, and `seams.py` to the explicit forge packaging list in `kb-forge/pyproject.toml`, following the pattern `504ad32` established.

In `docs/superpowers/specs/2026-08-20-federated-kb-design.md`, update the two config examples to match what was built (JSON lockfile; `peers:` as `alias = locator` strings), and add a line under "Decisions taken" recording why. Add `speccraft sync` to `kb-forge/README.md`'s command list.

- [ ] **Step 4: Run the full suite**

Run: `cd kb-forge && python3 -m pytest tests/ -v && speccraft/forge/session-kit/evals/self-test.sh`
Expected: everything green.

- [ ] **Step 5: Commit**

```bash
git add kb-forge/pyproject.toml kb-forge/tests/ kb-forge/README.md \
        docs/superpowers/specs/2026-08-20-federated-kb-design.md
git commit -m "build: package federation modules; reconcile spec with built config format"
```

---

## Self-Review

**Spec coverage.** Peer model → Task 2. Fetch/cache → Tasks 3, 8. Two-step pin resolution and the never-fall-forward rule → Task 8. Anchor grammar → Task 5. Loading and rendering → Tasks 6, 7. Fail open → Task 7. Briefing → Task 10. Queue and seam ownership → no code: the spec's rule is that writes never cross a boundary, which this plan satisfies by never writing to a peer; the briefing's peer-queue *read* is deferred and noted below. Consent-is-the-pin → Task 9's assertion that an unpinned peer commit does not enforce. Decay across the seam → no code needed; peer facts are read-only by construction. Warm start → Task 8 (a synced peer's facts are in force immediately). Evals → Tasks 7–11. Phase-in → guarded by running the existing `self-test.sh` in Tasks 4, 7, 10, 12.

**Two gaps I am flagging rather than papering over:**

1. **Peer queue counts in the briefing are not implemented.** Task 10 renders alias and pin only. Reading peer `QUEUE.md` files requires the peer's repo root, which the cache does not currently hold (only `kb_path` is fetched). Closing it means fetching `.speccraft/QUEUE.md` alongside the KB — a one-line change to the sparse-checkout paths in `_sparse_fetch`, plus rendering. It is deliberately deferred so Phase C ships without widening the fetch contract; the "one briefing" claim is partially delivered until then.
2. **The queue append mechanism under parallel fan-out** is called out in the spec as an open detail and is not resolved here either, because no task in this plan writes to the queue. It becomes real when seam candidates start queueing digest items — a follow-on to Task 11.

**Placeholder scan.** `REPOWISE_MIN_VERSION = ""` in Task 11 is intentionally empty and Step 3 says to fill it from Task 1's audit; it is a value that cannot exist before Task 1 runs, not an unwritten decision.

**Type consistency.** `collect_kb` returns 3-tuples throughout; `collect_federated` returns 4-tuples and Task 7 adapts both call shapes explicitly. `cache_dir(locator, sha)` is called with the same argument order in `peers.resolve_peers`, `peersync.materialize`, and `peersync.gc`. Lockfile keys — `alias`, `kind`, `locator`, `kb_path`, `pin`, `synced_at_commit` — are identical in Tasks 2, 3, 7, 8, 9. `LOCAL_PIN` is `"LOCAL"` in the module and the fixtures.

---

## Plan complete

Saved to `docs/superpowers/plans/2026-08-20-federated-kb.md`.
