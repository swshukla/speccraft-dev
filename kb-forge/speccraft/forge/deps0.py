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

RISK = re.compile(r"razorpay|stripe|paypal|jwt|jose|passlib|bcrypt|oauth|"
                  r"crypto|telegram|boto3|sqlalchemy|alembic|celery|redis|"
                  r"httpx|requests|aiohttp|pydantic|fastapi|next|react", re.I)

def sh(cmd, cwd=None):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                              timeout=120).stdout
    except Exception:
        return ""

def load_config(path):
    cfg = {}
    for line in open(path):
        line = line.split("#")[0].rstrip()
        if ":" in line and not line.startswith(" "):
            k, v = line.split(":", 1)
            cfg[k.strip()] = v.strip().strip('"')
    return cfg

def pinned_sha(kbroot):
    for line in open(os.path.join(kbroot, "kb", "derived", "inventory.md")):
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
    for line in open(path, errors="replace"):
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
    for line in open(path, errors="replace"):
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
        data = json.load(open(path))
    except Exception:
        return [], []
    runtime = list(data.get("dependencies", {}).items())
    dev = list(data.get("devDependencies", {}).items())
    return runtime, dev

def parse_package_lock(path):
    pinned = {}
    try:
        data = json.load(open(path))
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

def audit(snap, cfg):
    findings = {"python": None, "js": None}
    if shutil.which("pip-audit") and find(snap, {"requirements.txt", "pyproject.toml"}):
        req = (find(snap, {"requirements.txt"}) or [None])[0]
        if req:
            out = sh(["pip-audit", "-r", req, "-f", "json", "--progress-spinner", "off"], snap)
            findings["python"] = out.strip() or "no output"
    if shutil.which("npm") and find(snap, {"package-lock.json"}):
        lock_dir = os.path.dirname(find(snap, {"package-lock.json"})[0])
        out = sh(["npm", "audit", "--json"], lock_dir)
        findings["js"] = out.strip() or "no output"
    return findings

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    args = ap.parse_args()
    cfg = load_config(args.config)
    repo = os.path.expanduser(cfg["repo"])
    kbroot = os.path.dirname(os.path.abspath(args.config))
    pin = pinned_sha(kbroot)

    with tempfile.TemporaryDirectory(
            dir=os.environ.get("CLAUDE_SCRATCHPAD") or None) as tmp:
        snapshot(repo, pin, tmp)
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
        advisories = audit(tmp, cfg)

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
    with open(out, "w") as fh:
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
        fh.write("\n## Security advisories (deterministic)\n\n")
        for eco, data in advisories.items():
            if data is None:
                fh.write(f"- {eco}: scanner not available — COVERAGE GAP "
                         f"(install pip-audit / run npm audit to close)\n")
            else:
                fh.write(f"- {eco}: scanner ran; see raw output "
                         f"(kb/derived/advisories-{eco}.json)\n")
                open(os.path.join(kbroot, "kb", "derived",
                                  f"advisories-{eco}.json"), "w").write(data)
    print(json.dumps({"py": len(py), "js": len(js), "js_dev": len(jsd),
                      "py_audit": advisories["python"] is not None,
                      "js_audit": advisories["js"] is not None,
                      "pin": pin, "out": os.path.relpath(out, kbroot)}))

if __name__ == "__main__":
    main()
