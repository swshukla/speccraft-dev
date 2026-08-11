#!/usr/bin/env python3
"""speccraft-check — deterministic product checks. Lenient by default (report,
exit 0); strict (exit nonzero) via --strict, check_mode: strict, or per-check strict."""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drift import load_config
from recall import frontmatter

SKIP_DIRS = {".git", ".speccraft", "node_modules", "__pycache__", ".venv", "venv"}
SRC_EXT = (".py", ".ts", ".tsx", ".js", ".jsx", ".sql", ".yaml", ".yml",
           ".toml", ".sh", ".go", ".rb", ".java")


def _raw_field(path, field):
    """Read a frontmatter scalar RAW (regex-safe: no #-split, no []-coercion)."""
    with open(path, encoding="utf-8") as fh:
        if fh.readline().strip() != "---":
            return None
        for line in fh:
            if line.strip() == "---":
                break
            if line.startswith(field + ":"):
                return line.split(":", 1)[1].strip().strip('"').strip("'")
    return None


def grep_bans(kbroot):
    cdir = os.path.join(kbroot, "kb", "normative", "conventions")
    out = []
    if not os.path.isdir(cdir):
        return out
    for fn in sorted(os.listdir(cdir)):
        if not fn.endswith(".md"):
            continue
        path = os.path.join(cdir, fn)
        pat = _raw_field(path, "avoid_pattern")
        if not pat:
            continue
        meta = frontmatter(path)
        out.append({
            "id": fn[:-3],
            "pattern": pat,
            "anchors": [a for a in meta.get("anchors", []) if not a.startswith("topic:")],
            "seam": meta.get("seam", ""),
            "strict": str(meta.get("strict", "")).lower() == "true",
        })
    return out


def _scan_file(fp, rx, repo, ban, out):
    try:
        with open(fp, encoding="utf-8", errors="ignore") as fh:
            for i, line in enumerate(fh, 1):
                if rx.search(line):
                    out.append({"check": ban["id"], "file": os.path.relpath(fp, repo),
                                "line": i, "text": line.strip()[:120],
                                "seam": ban["seam"], "strict": ban["strict"]})
    except OSError:
        pass


def run_grep_bans(repo, bans):
    out = []
    compiled = []
    for b in bans:
        try:
            rx = re.compile(b["pattern"])
        except re.error as e:
            out.append({"check": b["id"], "file": "(pattern)", "line": 0,
                        "text": f"invalid avoid_pattern: {e}", "seam": b["seam"],
                        "strict": b["strict"]})
            continue
        compiled.append((b, rx))
    if not compiled:
        return out
    # Anchors are PATH PREFIXES (spec §4.2 / recall.py's `match`), not exact
    # file/dir names — walk the repo once and match each source file to a
    # ban by rel-path prefix, consistent with recall.
    for root, dirs, files in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if not f.endswith(SRC_EXT):
                continue
            fp = os.path.join(root, f)
            rel = os.path.relpath(fp, repo)
            for b, rx in compiled:
                anchors = b["anchors"] or [""]
                if any(rel.startswith(a.rstrip("/")) for a in anchors):
                    _scan_file(fp, rx, repo, b, out)
    return out


def _script_header(path):
    hdr = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if s.startswith("#!"):
                continue
            if s.startswith("#"):
                body = s[1:].strip()
                if ":" in body:
                    k, val = body.split(":", 1)
                    if k.strip() in ("check-for", "strict"):
                        hdr[k.strip()] = val.strip()
                continue
            if s == "":
                continue
            break   # first non-comment, non-blank line ends the header
    return hdr


def run_check_scripts(repo, kbroot):
    import subprocess
    cdir = os.path.join(kbroot, "kb", "normative", "checks")
    out = []
    if not os.path.isdir(cdir):
        return out
    for fn in sorted(os.listdir(cdir)):
        path = os.path.join(cdir, fn)
        if not (os.path.isfile(path) and os.access(path, os.X_OK)):
            continue
        hdr = _script_header(path)
        strict = hdr.get("strict", "").lower() == "true"
        try:
            r = subprocess.run([path], cwd=repo, capture_output=True, text=True,
                               env={**os.environ, "SPECCRAFT_REPO": repo}, timeout=120)
        except Exception as e:
            out.append({"check": fn, "file": "(script)", "line": 0,
                        "text": f"check failed to run: {e}", "strict": strict})
            continue
        if r.returncode != 0:
            msg = (r.stdout.strip() or r.stderr.strip() or f"exit {r.returncode}")[:500]
            out.append({"check": fn, "file": "(script)", "line": 0, "text": msg,
                        "seam": hdr.get("check-for", ""), "strict": strict})
    return out


def report(violations, global_strict):
    for v in violations:
        v["strict_eff"] = global_strict or v.get("strict", False)
    if not violations:
        print("speccraft-check: 0 violations")
        return 0
    groups = {}
    for v in violations:
        groups.setdefault(v["check"], []).append(v)
    for cid in sorted(groups):
        xs = groups[cid]
        print(f"\n## {cid} ({len(xs)} violation(s))")
        for v in xs:
            tag = "[strict]" if v["strict_eff"] else "[lenient]"
            loc = f"{v['file']}:{v['line']}" if v.get("line") else v["file"]
            print(f"  {tag} {loc}: {v['text']}")
            if v.get("seam"):
                print(f"         → USE: {v['seam']}")
    n_strict = sum(1 for v in violations if v["strict_eff"])
    print(f"\nspeccraft-check: {len(violations)} violation(s), {n_strict} strict.")
    return 1 if n_strict else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()
    cfg = load_config(args.config)
    kbroot = os.path.dirname(os.path.abspath(args.config))
    repo = os.path.expanduser(cfg.get("repo", "."))
    global_strict = args.strict or cfg.get("check_mode", "lenient").lower() == "strict"

    violations = run_grep_bans(repo, grep_bans(kbroot)) + run_check_scripts(repo, kbroot)
    return report(violations, global_strict)


if __name__ == "__main__":
    sys.exit(main())
