#!/usr/bin/env python3
"""kb-forge deps0 — deterministic dependency inventory (tech-stack seeding).

Harvests the exact third-party dependencies and PINNED VERSIONS the system
uses, from manifests + lockfiles read at the KB pin. Versions are load-bearing:
best-practice/gotcha knowledge (pass 2, kb/inferred/09-dependency-practices.md)
is version-specific, so a gotcha card is only meaningful against the version
recorded here.

Also runs security advisory scanners when available (pip-audit / npm audit) —
CVEs are known mistakes with known fixes, and unlike LLM "gotchas" they are
authoritative, not hallucinated. When a scanner is absent it is recorded as a
coverage gap, never silently skipped.

Output: kb/derived/dependencies.md (provenance: derived).

Usage: python3 deps0.py --config /path/to/<product>-kb/kbforge.yaml
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import signals                          # sibling module in this dir

RISK = re.compile(r"razorpay|stripe|paypal|jwt|jose|passlib|bcrypt|oauth|"
                  r"crypto|telegram|boto3|sqlalchemy|alembic|celery|redis|"
                  r"httpx|requests|aiohttp|pydantic|fastapi|next|react", re.I)

# Advisory refresh cadence. Scanners are networked + slow, so they are OFF the
# per-commit inventory path: the ship loop only re-scans when the last scan is
# older than this many days (or when --advisories-only forces it). deps0 tracks
# the last scan and the set of known advisory IDs in advisories-meta.json, and
# queues only advisories that are NEW since that baseline — a CVE landing on an
# UNCHANGED pinned version is founder WORK, not noise.
DEFAULT_ADVISORY_AGE_DAYS = 7
ADV_META = "advisories-meta.json"   # under kb/derived/

def sh(cmd, cwd=None):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=120).stdout
    except Exception:
        return ""

def load_config(path):
    cfg = {}
    for line in open(path, encoding="utf-8"):
        line = line.split("#")[0].rstrip()
        if ":" in line and not line.startswith(" "):
            k, v = line.split(":", 1)
            cfg[k.strip()] = v.strip().strip('"')
    return cfg

def pinned_sha(kbroot):
    for line in open(os.path.join(kbroot, "kb", "derived", "inventory.md"), encoding="utf-8"):
        if line.startswith("source_commit:"):
            return line.split(":", 1)[1].strip()
    sys.exit("no source_commit pin in kb/derived/inventory.md")

def snapshot(repo, sha, dest):
    tar = os.path.join(dest, "snap.tar")
    with open(tar, "wb") as fh:
        subprocess.run(["git", "archive", sha], cwd=repo, stdout=fh, check=True)
    subprocess.run(["tar", "-xf", tar, "-C", dest], check=True)
    os.unlink(tar)

# ---- python ---------------------------------------------------------------
def parse_pyproject(path):
    try:
        import tomllib
        with open(path, "rb") as fh:
            data = tomllib.load(fh)
    except Exception:
        return []
    deps = []
    proj = data.get("project", {})
    for d in proj.get("dependencies", []):
        deps.append(_split_req(d))
    poetry = data.get("tool", {}).get("poetry", {}).get("dependencies", {})
    for name, spec in poetry.items():
        if name.lower() == "python":
            continue
        v = spec if isinstance(spec, str) else (spec.get("version", "") if isinstance(spec, dict) else "")
        deps.append((name, v.lstrip("^~>=< ")))
    return deps

def _split_req(line):
    m = re.match(r"\s*([A-Za-z0-9_.\-]+)\s*(.*)", line)
    if not m:
        return (line.strip(), "")
    return (m.group(1), m.group(2).strip())

def parse_requirements(path):
    deps = []
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.split("#")[0].strip()
        if not line or line.startswith("-"):
            continue
        m = re.match(r"([A-Za-z0-9_.\-]+)\s*([=<>!~].*)?", line)
        if m:
            deps.append((m.group(1), (m.group(2) or "").strip()))
    return deps

def parse_poetry_lock(path):
    """Lockfile = exact resolved versions (strongest signal)."""
    pinned = {}
    name = ver = None
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if line == "[[package]]":
            name = ver = None
        elif line.startswith("name = "):
            name = line.split("=", 1)[1].strip().strip('"')
        elif line.startswith("version = "):
            ver = line.split("=", 1)[1].strip().strip('"')
            if name:
                pinned[name] = ver
    return pinned

# ---- javascript -----------------------------------------------------------
def parse_package_json(path):
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception:
        return [], []
    runtime = list(data.get("dependencies", {}).items())
    dev = list(data.get("devDependencies", {}).items())
    return runtime, dev

def parse_package_lock(path):
    pinned = {}
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception:
        return pinned
    for key, meta in (data.get("packages") or {}).items():
        if not key.startswith("node_modules/"):
            continue
        nm = key.split("node_modules/")[-1]
        if isinstance(meta, dict) and meta.get("version"):
            pinned[nm] = meta["version"]
    for nm, meta in (data.get("dependencies") or {}).items():
        if isinstance(meta, dict) and meta.get("version") and nm not in pinned:
            pinned[nm] = meta["version"]
    return pinned

def find(snap, names):
    hits = []
    for root, dirs, files in os.walk(snap):
        dirs[:] = [d for d in dirs if d not in
                   {".git", "node_modules", ".next", "venv", ".venv", "__pycache__"}]
        for f in files:
            if f in names:
                hits.append(os.path.join(root, f))
    return hits

def run_scanners(snap, inputs):
    """Raw scanner output per ecosystem: {'python': str|None, 'js': str|None}.

    None == scanner absent (a COVERAGE GAP, never a silent skip). `inputs` maps
    an ecosystem to a file of pre-computed scanner JSON, bypassing the network
    scanner — used by CI (feed a scan artifact) and by the self-test (determinism
    without a live scanner)."""
    findings = {"python": None, "js": None}
    if "python" in inputs:
        findings["python"] = open(inputs["python"], encoding="utf-8", errors="replace").read()
    elif shutil.which("pip-audit") and find(snap, {"requirements.txt", "pyproject.toml"}):
        req = (find(snap, {"requirements.txt"}) or [None])[0]
        if req:
            out = sh(["pip-audit", "-r", req, "-f", "json", "--progress-spinner", "off"], snap)
            findings["python"] = out.strip() or "no output"
    if "js" in inputs:
        findings["js"] = open(inputs["js"], encoding="utf-8", errors="replace").read()
    elif shutil.which("npm") and find(snap, {"package-lock.json"}):
        lock_dir = os.path.dirname(find(snap, {"package-lock.json"})[0])
        out = sh(["npm", "audit", "--json"], lock_dir)
        findings["js"] = out.strip() or "no output"
    return findings

def _py_advisory_ids(raw):
    """{'py:pkg:VULNID': label} from pip-audit -f json (dict or bare-list shape)."""
    out = {}
    try:
        data = json.loads(raw)
    except Exception:
        return out
    deps = data.get("dependencies", []) if isinstance(data, dict) else data
    for dep in deps or []:
        if not isinstance(dep, dict):
            continue
        name, ver = dep.get("name", "?"), dep.get("version", "?")
        for v in dep.get("vulns", []) or []:
            vid = v.get("id", "?")
            fixes = ", ".join(v.get("fix_versions", []) or []) or "no fix listed"
            out[f"py:{name}:{vid}"] = f"`{name}` @ {ver} — {vid} (fix: {fixes})"
    return out

def _js_advisory_ids(raw):
    """{'js:pkg:source': label} from npm audit --json (v7+ vulnerabilities map)."""
    out = {}
    try:
        data = json.loads(raw)
    except Exception:
        return out
    for pkg, meta in (data.get("vulnerabilities") or {}).items():
        if not isinstance(meta, dict):
            continue
        sev = meta.get("severity", "?")
        for via in meta.get("via", []) or []:
            if isinstance(via, dict):
                src = via.get("source") or via.get("url") or via.get("title") or "?"
                out[f"js:{pkg}:{src}"] = (f"`{pkg}` — {sev}: {via.get('title', '')} "
                                          f"{via.get('url', '')}".strip())
            else:
                out[f"js:{pkg}:{via}"] = f"`{pkg}` — {sev}: via vulnerable `{via}`"
    return out

_EXTRACT = {"python": _py_advisory_ids, "js": _js_advisory_ids}

def _meta_path(kbroot):
    return os.path.join(kbroot, "kb", "derived", ADV_META)

def load_meta(kbroot):
    try:
        return json.load(open(_meta_path(kbroot), encoding="utf-8"))
    except Exception:
        return {}

def advisories_stale(meta, max_age_days):
    """True when no scan is recorded or the last scan is >= max_age_days old."""
    last = meta.get("last_scan")
    if not last:
        return True
    try:
        return (date.today() - date.fromisoformat(last)).days >= max_age_days
    except Exception:
        return True

def refresh_advisories(kbroot, snap, inputs, queue):
    """Scan → diff against the saved advisory baseline → queue NEW advisories →
    persist raw output + baseline. Returns (meta, new_items).

    Only advisories absent from the prior baseline are queued, so re-scanning an
    unchanged tree is silent. When a scanner is absent its prior IDs are kept
    (baseline preserved, no false 'resolved'), and last_scan is NOT advanced —
    the gate keeps cheaply probing until the scanner appears."""
    derived = os.path.join(kbroot, "kb", "derived")
    os.makedirs(derived, exist_ok=True)
    prev = load_meta(kbroot)
    prev_ids = prev.get("ids", {})
    findings = run_scanners(snap, inputs)

    new_ids, counts, new_items = {}, {}, []
    for eco, raw in findings.items():
        if raw is None:                       # scanner absent — coverage gap
            counts[eco] = None
            new_ids[eco] = prev_ids.get(eco, {})
            continue
        open(os.path.join(derived, f"advisories-{eco}.json"), "w", encoding="utf-8").write(raw)
        ids = _EXTRACT[eco](raw)
        new_ids[eco] = ids
        counts[eco] = len(ids)
        base = prev_ids.get(eco, {})
        for k, label in ids.items():
            if k not in base:
                new_items.append(f"- [ ] deps0-advisory: new {eco} advisory — {label} "
                                 f"(see kb/derived/advisories-{eco}.json)")

    scanned = any(findings[e] is not None for e in findings)
    meta = {"last_scan": date.today().isoformat() if scanned else prev.get("last_scan"),
            "counts": counts, "ids": new_ids}
    json.dump(meta, open(_meta_path(kbroot), "w", encoding="utf-8"), indent=2)

    if queue and new_items:
        existing = signals.read_lines(kbroot, "advisories")
        body = "## advisories\n" + "\n".join(existing + new_items)
        signals.write_region(kbroot, "advisories", body)
    return meta, new_items

def advisories_section(kbroot):
    """The dependencies.md advisory block, rendered from the cached baseline
    (NOT a live scan) so the per-commit inventory path stays network-free."""
    meta = load_meta(kbroot)
    last = meta.get("last_scan")
    if not last:
        return ("\n## Security advisories (deterministic)\n\n"
                "- not yet scanned — run `deps0.py --advisories-only --queue` to "
                "establish the advisory baseline\n")
    out = ["\n## Security advisories (deterministic)\n\n",
           f"Refreshed on a {DEFAULT_ADVISORY_AGE_DAYS}-day cadence via the ship "
           f"loop (last scan: {last}). Force now: `deps0.py --advisories-only "
           f"--queue`.\n\n"]
    for eco, c in (meta.get("counts") or {}).items():
        if c is None:
            out.append(f"- {eco}: scanner not available — COVERAGE GAP "
                       f"(install pip-audit / run npm audit to close)\n")
        else:
            out.append(f"- {eco}: {c} advisory record(s) as of last scan; "
                       f"see advisories-{eco}.json\n")
    return "".join(out)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--queue", action="store_true",
                    help="append NEW advisories to the SIGNALS.md advisories region")
    ap.add_argument("--advisories-only", action="store_true",
                    help="skip the inventory rewrite; force an advisory "
                         "scan+diff+queue regardless of cadence (CI / manual)")
    ap.add_argument("--advisory-max-age-days", type=int,
                    default=DEFAULT_ADVISORY_AGE_DAYS,
                    help="per-commit path re-scans only when the last scan is "
                         "at least this old (default %(default)s)")
    ap.add_argument("--advisory-input", action="append", default=[],
                    metavar="ECO=PATH",
                    help="inject scanner JSON for ECO (python|js) instead of "
                         "running the network scanner; repeatable")
    args = ap.parse_args()
    cfg = load_config(args.config)
    repo = os.path.expanduser(cfg["repo"])
    kbroot = os.path.dirname(os.path.abspath(args.config))
    pin = pinned_sha(kbroot)
    inputs = dict(kv.split("=", 1) for kv in args.advisory_input if "=" in kv)

    with tempfile.TemporaryDirectory(
            dir=os.environ.get("CLAUDE_SCRATCHPAD") or None) as tmp:
        snapshot(repo, pin, tmp)

        # ---- advisory-only: scheduled/CI refresh, no inventory rewrite ----
        if args.advisories_only:
            meta, new_items = refresh_advisories(kbroot, tmp, inputs, args.queue)
            print(json.dumps({"mode": "advisories-only", "pin": pin,
                              "new_advisories": len(new_items),
                              "counts": meta["counts"], "last_scan": meta["last_scan"]}))
            return

        # ---- inventory (per-commit, network-free) ----
        py_direct, js_runtime, js_dev = [], [], []
        py_lock, js_lock = {}, {}
        for p in find(tmp, {"pyproject.toml"}):
            py_direct += parse_pyproject(p)
        for p in find(tmp, {"requirements.txt"}):
            py_direct += parse_requirements(p)
        for p in find(tmp, {"poetry.lock"}):
            py_lock.update(parse_poetry_lock(p))
        for p in find(tmp, {"package.json"}):
            r, d = parse_package_json(p)
            js_runtime += r; js_dev += d
        for p in find(tmp, {"package-lock.json"}):
            js_lock.update(parse_package_lock(p))

        # ---- advisory gate: scan only when stale (or scanner injected) ----
        new_items = []
        if inputs or advisories_stale(load_meta(kbroot), args.advisory_max_age_days):
            _, new_items = refresh_advisories(kbroot, tmp, inputs, args.queue)

    def resolve(name, spec, lock):
        return lock.get(name) or (spec.lstrip("^~>=<! ") if spec else "?")

    py = {}
    for name, spec in py_direct:
        py[name] = resolve(name, spec, py_lock)
    js = {}
    for name, spec in js_runtime:
        js[name] = resolve(name, spec, js_lock)
    jsd = {name: resolve(name, spec, js_lock) for name, spec in js_dev}

    out = os.path.join(kbroot, "kb", "derived", "dependencies.md")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("---\nname: dependencies\nprovenance: derived\n"
                 f"source_commit: {pin}\nconfidence: certain\nanchors:\n"
                 "  - topic:dependencies\n---\n\n"
                 "# Tech dependency inventory (mechanical)\n\n"
                 "Direct runtime dependencies with resolved versions @ pin. "
                 "Best-practice/gotcha knowledge is version-specific and lives "
                 "in kb/inferred/09-dependency-practices.md — cards there are "
                 "valid only against the versions below.\n")
        for title, table in (("Python (runtime)", py),
                             ("JavaScript / Node (runtime)", js),
                             ("JavaScript / Node (dev)", jsd)):
            fh.write(f"\n## {title} ({len(table)})\n\n")
            for name in sorted(table):
                risk = " ⚠risk" if RISK.search(name) else ""
                fh.write(f"- `{name}` @ **{table[name]}**{risk}\n")
        fh.write(advisories_section(kbroot))
    meta = load_meta(kbroot)
    print(json.dumps({"py": len(py), "js": len(js), "js_dev": len(jsd),
                      "advisory_new": len(new_items),
                      "advisory_last_scan": meta.get("last_scan"),
                      "pin": pin, "out": os.path.relpath(out, kbroot)}))

if __name__ == "__main__":
    main()
