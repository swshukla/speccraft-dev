#!/usr/bin/env python3
"""kb-forge dup0 — mechanical harvest of duplicate & contradiction CANDIDATES
(consistency excavation, pass 1).

Detects shapes, not verdicts — whether a duplicate is debt or deliberate, and
whether a divergence is a contradiction or an intentional distinction, is
pass 2/3's judgment. Classes harvested:

  samename   function/method name defined in 2+ modules (Python via ast,
             TS/JS via regex) — candidate duplicated capability
  clone      structurally identical Python function bodies across files
             (normalized ast hash) — copy-paste duplication
  divconst   same UPPER_CASE constant name bound to DIFFERENT values in
             different modules — candidate contradiction
  sharedurl  same external host hardcoded in 2+ files — candidate duplicated
             integration path

Reads the product repo ONLY at the KB pin (git archive snapshot).
Output: kb/derived/dup-residue.md (provenance: derived).

Usage: python3 dup0.py --config /path/to/<product>-kb/kbforge.yaml
"""
import argparse, ast, hashlib, json, os, re, subprocess, sys, tempfile
from collections import defaultdict

SKIP_DIRS = {".git", "node_modules", ".next", "__pycache__", "venv", ".venv",
             "dist", "build", ".pytest_cache", "superdev"}
JS_EXT = {".ts", ".tsx", ".js", ".jsx"}
BORING = {"main", "run", "setup", "get", "post", "put", "delete", "handler",
          "handle", "init", "cli", "cleanup", "close", "start", "stop",
          "render", "page", "layout", "default", "index"}
URL = re.compile(r"https?://([\w.-]+)")
JS_FN = re.compile(r"(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*\(")
CAPS = {"samename": 60, "clone": 40, "divconst": 40, "sharedurl": 30}

def sh(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True).stdout

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

def snapshot(repo, pin, dest):
    tar = os.path.join(dest, "snap.tar")
    with open(tar, "wb") as fh:
        subprocess.run(["git", "archive", pin], cwd=repo, stdout=fh, check=True)
    subprocess.run(["tar", "-xf", tar, "-C", dest], check=True)
    os.unlink(tar)

def body_hash(node):
    body = node.body
    if body and isinstance(body[0], ast.Expr) and \
       isinstance(getattr(body[0], "value", None), ast.Constant) and \
       isinstance(body[0].value.value, str):
        body = body[1:]                       # drop docstring
    mod = ast.Module(body=body, type_ignores=[])
    return (hashlib.sha1(ast.dump(mod, annotate_fields=False)
                         .encode()).hexdigest()[:12], len(body))

def harvest(snap):
    fn_sites = defaultdict(list)     # name -> [(file, line)]
    clones = defaultdict(list)       # hash -> [(file, line, name, nstmt)]
    consts = defaultdict(dict)       # NAME -> {value_repr: [(file, line)]}
    urls = defaultdict(set)          # host -> {file}
    for root, dirs, files in os.walk(snap):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in sorted(files):
            ext = os.path.splitext(f)[1]
            full = os.path.join(root, f)
            rel = os.path.relpath(full, snap)
            if "test" in rel.lower():
                continue
            try:
                src = open(full, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            if ext == ".py":
                try:
                    tree = ast.parse(src)
                except SyntaxError:
                    continue
                for node in ast.walk(tree):
                    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        if node.name.startswith("__") or node.name in BORING:
                            continue
                        fn_sites[node.name].append((rel, node.lineno))
                        h, n = body_hash(node)
                        if n >= 4:
                            clones[h].append((rel, node.lineno, node.name, n))
                    elif isinstance(node, ast.Assign) and len(node.targets) == 1:
                        t = node.targets[0]
                        if isinstance(t, ast.Name) and t.id.isupper() and \
                           len(t.id) > 2:
                            try:
                                v = ast.unparse(node.value)[:60]
                            except Exception:
                                continue
                            consts[t.id].setdefault(v, []).append(
                                (rel, node.lineno))
            elif ext in JS_EXT:
                for m in JS_FN.finditer(src):
                    name = m.group(1)
                    if name in BORING or name[0].isupper():   # skip components
                        continue
                    line = src.count("\n", 0, m.start()) + 1
                    fn_sites[name].append((rel, line))
            if ext == ".py" or ext in JS_EXT:
                for m in URL.finditer(src):
                    host = m.group(1)
                    if host not in ("localhost", "127.0.0.1", "example.com",
                                    "www.w3.org", "schemas.openxmlformats.org"):
                        urls[host].add(rel)

    def modules_of(sites):
        return {s[0] for s in sites}

    samename = sorted(
        [(n, sorted(set(s))) for n, s in fn_sites.items()
         if len(modules_of(s)) >= 2],
        key=lambda x: -len(x[1]))
    clone_groups = sorted(
        [v for v in clones.values() if len({c[0] for c in v}) >= 2],
        key=lambda g: -g[0][3])
    divconst = sorted(
        [(n, vals) for n, vals in consts.items()
         if len(vals) >= 2 and len({loc for v in vals.values()
                                    for loc in v}) >= 2],
        key=lambda x: -len(x[1]))
    sharedurl = sorted([(h, sorted(fs)) for h, fs in urls.items()
                        if len(fs) >= 2], key=lambda x: -len(x[1]))
    return samename, clone_groups, divconst, sharedurl

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
        samename, clone_groups, divconst, sharedurl = harvest(tmp)

    out = os.path.join(kbroot, "kb", "derived", "dup-residue.md")
    with open(out, "w") as fh:
        fh.write("---\nname: dup-residue\nprovenance: derived\n"
                 f"source_commit: {pin}\nconfidence: certain\n"
                 "note: duplicate/contradiction CANDIDATES; classification "
                 "lives in kb/inferred/08-consistency.md\n---\n\n"
                 "# Duplicate & contradiction candidates (mechanical)\n")
        fh.write(f"\n## Same-name functions in 2+ modules ({len(samename)})\n\n")
        for name, sites in samename[:CAPS["samename"]]:
            locs = ", ".join(f"`{p}:{l}`" for p, l in sites[:8])
            more = f" +{len(sites)-8} more" if len(sites) > 8 else ""
            fh.write(f"- **{name}** ×{len(sites)}: {locs}{more}\n")
        fh.write(f"\n## Identical-body clones across files ({len(clone_groups)})\n\n")
        for g in clone_groups[:CAPS["clone"]]:
            locs = ", ".join(f"`{p}:{l}` ({n})" for p, l, n, _ in g[:6])
            fh.write(f"- {g[0][3]} stmts: {locs}\n")
        fh.write(f"\n## Same constant, different values ({len(divconst)})\n\n")
        for name, vals in divconst[:CAPS["divconst"]]:
            fh.write(f"- **{name}**:\n")
            for v, locs in vals.items():
                ll = ", ".join(f"`{p}:{l}`" for p, l in locs[:4])
                fh.write(f"    - `{v}` @ {ll}\n")
        fh.write(f"\n## External host hardcoded in 2+ files ({len(sharedurl)})\n\n")
        for host, files in sharedurl[:CAPS["sharedurl"]]:
            fh.write(f"- **{host}** ×{len(files)}: "
                     + ", ".join(f"`{f}`" for f in files[:8])
                     + (f" +{len(files)-8} more" if len(files) > 8 else "")
                     + "\n")
    print(json.dumps({"samename": len(samename), "clone": len(clone_groups),
                      "divconst": len(divconst), "sharedurl": len(sharedurl),
                      "pin": pin, "out": os.path.relpath(out, kbroot)}))

if __name__ == "__main__":
    main()
