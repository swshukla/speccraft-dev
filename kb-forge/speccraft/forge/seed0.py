#!/usr/bin/env python3
"""kb-forge seed0 — deterministic KB ingest (doc 04, Seed-Phase 0).

Walks a product repo and harvests what code makes certain — routes, data
models, tests, churn, module map — into <kb-repo>/kb/derived/. No LLM runs
here; every fact carries a path:line citation pinned to the last CODE commit
(HEAD moves with KB ship-loop commits under .speccraft/ — those don't count).
Harvest reads a `git archive` snapshot at that pin, never the working tree.

Usage: python3 seed0.py --config /path/to/<product>-kb/kbforge.yaml
"""
import argparse, json, os, re, subprocess, sys, tempfile
from datetime import datetime, timezone
from collections import defaultdict

SKIP_DIRS = {"node_modules", ".git", ".next", "__pycache__", ".pytest_cache",
             "dist", "build", ".venv", "venv", ".turbo", "coverage", ".DS_Store",
             ".speccraft"}   # .speccraft/ = the KB itself, tracked inside the repo
CODE_EXT = {".py", ".ts", ".tsx", ".js", ".jsx", ".sql", ".yaml", ".yml", ".json", ".md", ".css", ".sh", ".toml"}
RISK_PAT = re.compile(r"auth|login|session|token|payment|billing|subscri|trade|order|broker|wallet|portfolio|alert", re.I)

def sh(cmd, cwd):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=120).stdout
    except Exception:
        return ""

def last_code_sha(repo):
    """Last commit touching product code (KB commits under .speccraft/ excluded)."""
    return sh(["git", "log", "-1", "--format=%h", "--", ".", ":(exclude).speccraft"],
              repo).strip() or "no-git"

def snapshot(repo, sha, dest):
    tar = os.path.join(dest, "snap.tar")
    with open(tar, "wb") as fh:
        subprocess.run(["git", "archive", sha], cwd=repo, stdout=fh, check=True)
    subprocess.run(["tar", "-xf", tar, "-C", dest], check=True)
    os.unlink(tar)

def load_config(path):
    cfg = {}
    for line in open(path):
        line = line.split("#")[0].rstrip()
        if ":" in line and not line.startswith(" "):
            k, v = line.split(":", 1)
            cfg[k.strip()] = v.strip().strip('"')
    return cfg

def walk(repo):
    for root, dirs, files in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for f in files:
            if os.path.splitext(f)[1] in CODE_EXT:
                yield os.path.relpath(os.path.join(root, f), repo)

def header(kind, repo, sha):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return ("---\n"
            f"provenance: derived\ntool: kb-forge seed0 v0.1\nkind: {kind}\n"
            f"source_repo: {repo}\nsource_commit: {sha}\ngenerated: {now}\n"
            "confidence: certain   # deterministic harvest — no inference\n"
            "---\n\n")

RX_FASTAPI = re.compile(r"@(\w+)\.(get|post|put|delete|patch|websocket)\(\s*['\"]([^'\"]+)")
RX_INCLUDE = re.compile(r"include_router\(\s*([\w.]+)(?:[^)]*prefix\s*=\s*['\"]([^'\"]+))?")
RX_MODEL   = re.compile(r"^class\s+(\w+)\([^)]*Base[^)]*\):", re.M)
RX_TABLE   = re.compile(r"__tablename__\s*=\s*['\"](\w+)['\"]")
RX_COL     = re.compile(r"^\s{4}(\w+)\s*(?::\s*Mapped\[([^\]]+)\])?\s*=\s*(?:mapped_)?[Cc]olumn", re.M)
RX_PYTEST  = re.compile(r"^(?:async\s+)?def\s+(test_\w+)", re.M)
RX_JSTEST  = re.compile(r"(?:^|\s)(?:it|test)\(\s*['\"`]([^'\"`]+)")
RX_PYDANTIC= re.compile(r"^class\s+(\w+)\((?:[\w.]*BaseModel|[\w.]*Schema)[^)]*\):", re.M)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    args = ap.parse_args()
    cfg = load_config(args.config)
    repo = os.path.expanduser(cfg["repo"])
    kbdir = os.path.join(os.path.dirname(os.path.abspath(args.config)), "kb", "derived")
    os.makedirs(kbdir, exist_ok=True)
    sha = last_code_sha(repo)

    with tempfile.TemporaryDirectory(
            dir=os.environ.get("CLAUDE_SCRATCHPAD") or None) as tmp:
        if sha != "no-git":
            snapshot(repo, sha, tmp)   # harvest the pinned tree, not the (dirty) working tree
            snap = tmp
        else:
            snap = repo
        files = list(walk(snap))
        by_ext, by_top = defaultdict(int), defaultdict(int)
        for f in files:
            by_ext[os.path.splitext(f)[1]] += 1
            by_top[f.split(os.sep)[0]] += 1

        # ---- routes: FastAPI ----
        api_routes, includes = [], []
        # ---- routes: Next.js app router ----
        web_routes = []
        # ---- data model ----
        models, pydantic = [], []
        # ---- tests ----
        tests = []

        for f in files:
            p = os.path.join(snap, f)
            try:
                src = open(p, encoding="utf-8", errors="ignore").read()
            except Exception:
                continue
            if f.endswith(".py"):
                for m in RX_FASTAPI.finditer(src):
                    line = src[:m.start()].count("\n") + 1
                    api_routes.append((m.group(2).upper(), m.group(3), f, line, m.group(1)))
                for m in RX_INCLUDE.finditer(src):
                    includes.append((m.group(1), m.group(2) or "", f))
                for m in RX_MODEL.finditer(src):
                    line = src[:m.start()].count("\n") + 1
                    tail = src[m.start():m.start() + 4000]
                    tbl = RX_TABLE.search(tail)
                    cols = [c.group(1) for c in RX_COL.finditer(tail)][:30]
                    models.append((m.group(1), tbl.group(1) if tbl else "?", cols, f, line))
                for m in RX_PYDANTIC.finditer(src):
                    pydantic.append((m.group(1), f, src[:m.start()].count("\n") + 1))
                if "test" in f.lower():
                    for m in RX_PYTEST.finditer(src):
                        tests.append((m.group(1), f, src[:m.start()].count("\n") + 1))
            elif f.endswith((".ts", ".tsx", ".js", ".jsx")):
                base = os.path.basename(f)
                if base in ("page.tsx", "page.jsx", "route.ts", "route.js", "layout.tsx"):
                    parts = [s for s in os.path.dirname(f).split(os.sep) if not s.startswith("(")]
                    try:
                        url = "/" + "/".join(parts[parts.index("app") + 1:])
                    except ValueError:
                        url = "/" + os.path.dirname(f)
                    web_routes.append((url or "/", "API" if base.startswith("route") else "PAGE", f))
                if re.search(r"\.(test|spec)\.", base):
                    for m in RX_JSTEST.finditer(src):
                        tests.append((m.group(1), f, src[:m.start()].count("\n") + 1))

    # ---- churn (real repo dir, pinned to the same sha, KB excluded) ----
    churn = defaultdict(lambda: [0, 0])   # path -> [commits, lines]
    log = sh(["git", "log", sha, "--numstat", "--format=%h",
              "--", ".", ":(exclude).speccraft"], repo) if sha != "no-git" else ""
    for ln in log.splitlines():
        m = re.match(r"^(\d+)\t(\d+)\t(.+)$", ln)
        if m and not any(s in m.group(3) for s in SKIP_DIRS):
            churn[m.group(3)][0] += 1
            churn[m.group(3)][1] += int(m.group(1)) + int(m.group(2))
    top_churn = sorted(churn.items(), key=lambda kv: -kv[1][1])[:40]

    # ---- module map (top-2-level clustering) ----
    mods = defaultdict(lambda: {"files": 0, "tests": 0, "churn": 0, "risk": []})
    for f in files:
        parts = f.split(os.sep)
        key = "/".join(parts[:2]) if len(parts) > 1 else parts[0]
        mods[key]["files"] += 1
        if "test" in f.lower():
            mods[key]["tests"] += 1
        rm = RISK_PAT.search(f)
        if rm and rm.group(0).lower() not in mods[key]["risk"]:
            mods[key]["risk"].append(rm.group(0).lower())
    for path, (c, lines) in churn.items():
        parts = path.split("/")
        key = "/".join(parts[:2]) if len(parts) > 1 else parts[0]
        if key in mods:
            mods[key]["churn"] += lines

    def w(name, kind, body):
        with open(os.path.join(kbdir, name), "w") as fh:
            fh.write(header(kind, repo, sha) + body)

    w("inventory.md", "inventory",
      f"# Repo inventory\n\n**Files (code/config):** {len(files)}\n\n## By top-level dir\n"
      + "".join(f"- `{k}/` — {v} files\n" for k, v in sorted(by_top.items(), key=lambda x: -x[1]))
      + "\n## By extension\n"
      + "".join(f"- `{k}` — {v}\n" for k, v in sorted(by_ext.items(), key=lambda x: -x[1])))

    w("routes-api.md", "api-surface",
      f"# API surface (FastAPI) — {len(api_routes)} routes\n\n"
      + "".join(f"- **{m} `{path}`** — `{f}:{ln}` (router `{r}`)\n" for m, path, f, ln, r in sorted(api_routes, key=lambda x: x[1]))
      + ("\n## Router mounts\n" + "".join(f"- `{r}` prefix `{p or '—'}` — `{f}`\n" for r, p, f in includes) if includes else ""))

    w("routes-web.md", "web-surface",
      f"# Web surface (Next.js app router) — {len(web_routes)} routes\n\n"
      + "".join(f"- **`{u}`** ({t}) — `{f}`\n" for u, t, f in sorted(set(web_routes))))

    w("data-model.md", "data-model",
      f"# Data model (SQLAlchemy) — {len(models)} models\n\n"
      + "".join(f"## {n} (table `{t}`) — `{f}:{ln}`\ncolumns: {', '.join(cols) or '?'}\n\n" for n, t, cols, f, ln in models)
      + f"\n# API schemas (Pydantic) — {len(pydantic)}\n"
      + "".join(f"- `{n}` — `{f}:{ln}`\n" for n, f, ln in pydantic))

    w("tests.md", "test-inventory",
      f"# Test inventory — {len(tests)} tests\n\nEach test is an executable assertion about intended behavior — the strongest derived facts we have.\n\n"
      + "".join(f"- `{n}` — `{f}:{ln}`\n" for n, f, ln in tests))

    w("churn.md", "churn",
      "# Git churn (all history) — top 40 files by lines changed\n\n| file | commits | lines± |\n|---|---|---|\n"
      + "".join(f"| `{p}` | {c} | {l} |\n" for p, (c, l) in top_churn))

    w("modules.md", "module-map",
      "# Module map (Seed-1 input) — top-2-level clusters\n\n"
      "Risk tags are path-pattern hits (auth/trade/alert/…): candidates for the high-risk class that never earns auto-accept (`04`).\n\n"
      "| module | files | tests | churn (lines±) | risk tags |\n|---|---|---|---|---|\n"
      + "".join(f"| `{k}` | {v['files']} | {v['tests']} | {v['churn']} | {', '.join(v['risk']) or '—'} |\n"
               for k, v in sorted(mods.items(), key=lambda x: -x[1]["churn"]) if v["files"] > 2))

    print(json.dumps({"sha": sha, "files": len(files), "api_routes": len(api_routes),
                      "web_routes": len(web_routes), "models": len(models),
                      "pydantic": len(pydantic), "tests": len(tests),
                      "modules": len([m for m in mods.values() if m['files'] > 2])}))

if __name__ == "__main__":
    main()
