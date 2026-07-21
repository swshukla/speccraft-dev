#!/usr/bin/env python3
"""kb-forge assume0 — mechanical harvest of decision residue (assumption
excavation, pass 1 of 3).

Decisions leave scars in predictable places; this collects the scars without
interpreting them (no LLM, cannot hallucinate). Classes harvested:

  todo        TODO/FIXME/HACK/XXX/WORKAROUND comments — self-admitted debt
  swallow     bare/broad `except` that passes or continues — "failure here is
              tolerable" assumptions
  const       module-level UPPER_CASE numeric/bool constants — frozen tradeoffs
  timing      sleep/timeout/retry/interval/ttl numeric args — reliability and
              cost assumptions about external systems
  threshold   numeric comparison operands in services/worker code — tuned
              decision boundaries whose rationale lives nowhere
  deadcode    runs of commented-out code — rejected alternatives left in place
  deleted     files deleted in git history — abandoned features
  revert      commits whose message says revert — reversed decisions

Reads the product repo ONLY at the KB's pinned commit (git archive to a temp
snapshot); the working tree is never read. Output: kb/derived/assumption-residue.md
(provenance: derived). Pass 2 (agent) turns residues into hypothesis cards;
pass 3 (founder confrontation) ratifies or kills them.

Usage: python3 assume0.py --config /path/to/<product>-kb/kbforge.yaml
"""
import argparse, json, os, re, subprocess, sys, tempfile

SKIP_DIRS = {".git", "node_modules", ".next", "__pycache__", "venv", ".venv",
             "dist", "build", ".pytest_cache", "superdev"}
PY, JS = {".py"}, {".ts", ".tsx", ".js", ".jsx"}
CAPS = {"todo": 999, "swallow": 999, "const": 80, "timing": 60,
        "threshold": 60, "deadcode": 30, "deleted": 40, "revert": 40}

TODO = re.compile(r"(?:#|//)\s*(TODO|FIXME|HACK|XXX|WORKAROUND|TEMP)\b[:\s]*(.*)", re.I)
EXC = re.compile(r"^\s*except(?:\s+Exception)?(?:\s+as\s+\w+)?\s*:\s*$")
CONST = re.compile(r"^([A-Z][A-Z0-9_]{2,})(?:\s*:[\w\[\], .\"']+)?\s*=\s*"
                   r"(-?\d[\d_]*\.?\d*|True|False)\s*(?:#.*)?$")
TIMING = re.compile(r"\b(sleep|timeout|retries|max_retries|retry_backoff|"
                    r"countdown|expires|ttl|interval|max_age|cache_ttl)\s*[=(]\s*"
                    r"(-?\d[\d_]*\.?\d*)", re.I)
THRESH = re.compile(r"(?:if|elif|while|and|or|return)\b[^#]*?(<=|>=|<|>)\s*"
                    r"(\d[\d_]*\.?\d*)\b")
DEAD_PY = re.compile(r"^\s*#\s*(?:if |for |while |return |await |def |class |"
                     r"self\.|\w+\s*=\s*\S|\w+\().*")
DEAD_JS = re.compile(r"^\s*//\s*(?:if\s*\(|const |let |return |await |function\b).*")

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

def harvest_files(snap):
    found = {k: [] for k in ("todo", "swallow", "const", "timing",
                             "threshold", "deadcode")}
    for root, dirs, files in os.walk(snap):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in sorted(files):
            ext = os.path.splitext(f)[1]
            if ext not in PY | JS:
                continue
            rel = os.path.relpath(os.path.join(root, f), snap)
            in_worker_or_service = ("services" in rel or "worker" in rel
                                    or "bot" in rel)
            try:
                lines = open(os.path.join(root, f), encoding="utf-8",
                             errors="replace").read().splitlines()
            except OSError:
                continue
            dead_run, dead_start = 0, 0
            for i, ln in enumerate(lines, 1):
                m = TODO.search(ln)
                if m:
                    found["todo"].append((rel, i, f"{m.group(1).upper()}: "
                                          f"{m.group(2).strip()[:90]}"))
                if ext in PY and EXC.match(ln):
                    nxt = "".join(lines[i:i + 2])
                    if re.search(r"\b(pass|continue)\b", nxt) and \
                       "raise" not in nxt:
                        found["swallow"].append((rel, i, ln.strip()[:60]))
                m = CONST.match(ln)
                if m and "test" not in rel:
                    found["const"].append((rel, i,
                                           f"{m.group(1)} = {m.group(2)}"))
                m = TIMING.search(ln)
                if m and "test" not in rel:
                    found["timing"].append((rel, i,
                                            f"{m.group(1)}={m.group(2)}"))
                if in_worker_or_service and "test" not in rel:
                    m = THRESH.search(ln)
                    if m and m.group(2) not in ("0", "1", "2"):
                        found["threshold"].append((rel, i, ln.strip()[:90]))
                dead = (DEAD_PY if ext in PY else DEAD_JS).match(ln)
                if dead:
                    if dead_run == 0:
                        dead_start = i
                    dead_run += 1
                else:
                    if dead_run >= 2:
                        found["deadcode"].append((rel, dead_start,
                                                  f"{dead_run} commented-out "
                                                  f"code lines"))
                    dead_run = 0
    return found

def harvest_git(repo, pin):
    deleted = []
    out = sh(["git", "log", "--diff-filter=D", "--name-only",
              "--format=%h %s", pin], repo)
    commit = ""
    for ln in out.splitlines():
        if re.match(r"^[0-9a-f]{7,} ", ln):
            commit = ln[:60]
        elif ln.strip() and not ln.startswith(" "):
            deleted.append((ln.strip(), 0, f"deleted in {commit}"))
    reverts = [(m[:80], 0, "revert-ish commit message") for m in
               sh(["git", "log", "-i", "--grep", "revert", "--oneline", pin],
                  repo).splitlines()]
    return deleted, reverts

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
        found = harvest_files(tmp)
    found["deleted"], found["revert"] = harvest_git(repo, pin)

    titles = {
        "todo": "Self-admitted debt (TODO/FIXME/HACK)",
        "swallow": "Swallowed exceptions — 'failure here is tolerable'",
        "const": "Frozen constants — tradeoffs without recorded rationale",
        "timing": "Timing/retry values — reliability & cost assumptions",
        "threshold": "Decision thresholds in services/worker",
        "deadcode": "Commented-out code — rejected alternatives in place",
        "deleted": "Deleted files — abandoned features (see git for diffs)",
        "revert": "Reverted decisions",
    }
    out = os.path.join(kbroot, "kb", "derived", "assumption-residue.md")
    with open(out, "w") as fh:
        fh.write("---\nname: assumption-residue\nprovenance: derived\n"
                 f"source_commit: {pin}\nconfidence: certain\n"
                 "note: machine-harvested decision residue; interpretation "
                 "lives in kb/inferred/07-assumptions.md\n---\n\n"
                 "# Decision residue (mechanical harvest)\n\n"
                 "Each line is a scar a decision left; the rationale is NOT "
                 "here — that is pass 2/3's job.\n")
        for k, title in titles.items():
            items = found[k]
            fh.write(f"\n## {title} ({len(items)}"
                     f"{', showing ' + str(CAPS[k]) if len(items) > CAPS[k] else ''})\n\n")
            for rel, line, txt in items[:CAPS[k]]:
                loc = f"{rel}:{line}" if line else rel
                fh.write(f"- `{loc}` {txt}\n")
    print(json.dumps({k: len(v) for k, v in found.items()} | {"pin": pin,
          "out": os.path.relpath(out, kbroot)}))

if __name__ == "__main__":
    main()
