#!/usr/bin/env python3
"""kb-forge drift — two-directional drift checker (doc 03's Drift Reconciler,
laptop scale).

Compares the product repo's current HEAD against the sha the KB was built from
(the pin) and reports BOTH directions of drift:

SUBTRACTIVE — code the KB cites has changed or vanished (citation staleness).
  Refresh policy by provenance (doc 04):
    derived   -> regenerate mechanically: re-run seed0 + assume0 (no judgment)
    inferred  -> stale citation demotes the claim to `challenged`; re-verify it
    elicited  -> intent is not invalidated by code changes; flagged only so the
                 confrontation pass can check whether a new divergence appeared

ADDITIVE — new decision/integration surface entered the code that no KB fact
  covers yet (coverage drift). Scans the ADDED lines of the pin..HEAD diff for:
    integration surface: new external URLs, HTTP/SDK client imports, celery
      beat entries          -> refresh kb/inferred/05-data-sources.md and
                               kb/inferred/06-integrations.md
    assumption surface: new UPPER_CASE numeric constants, timing/retry values,
      swallowed exceptions  -> re-run assume0.py; extend
                               kb/inferred/07-assumptions.md (new residues are
                               new hypotheses for the confrontation batch)

Usage: python3 drift.py --config /path/to/<product>-kb/kbforge.yaml [--queue]
  --queue  append findings (both directions) to QUEUE.md
"""
import argparse, os, re, subprocess, sys
from collections import defaultdict
from datetime import datetime, timezone

CITE = re.compile(r"([\w@./-]+/[\w.-]+\.(?:py|tsx|ts|jsx|js|md|yaml|yml|toml|sql)):(\d+)(?:-(\d+))?")
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
CODE_EXT = (".py", ".ts", ".tsx", ".js", ".jsx")

ADDITIVE = [
    ("integration", re.compile(r"https?://[\w.-]+")),
    ("integration", re.compile(r"^\s*(?:import|from)\s+(?:httpx|requests|aiohttp"
                               r"|feedparser|razorpay|telegram|websockets|boto3"
                               r"|stripe|openai|anthropic|google)\b")),
    ("integration", re.compile(r"beat_schedule|add_periodic_task|_api_key\b|_API_KEY\b")),
    ("assumption", re.compile(r"^\s*[A-Z][A-Z0-9_]{2,}\s*(?::[\w\[\], .]+)?=\s*-?\d")),
    ("assumption", re.compile(r"\b(?:sleep|timeout|retries|max_retries|ttl"
                              r"|interval|countdown|expires)\s*[=(]\s*\d", re.I)),
    ("assumption", re.compile(r"^\s*except(?:\s+Exception)?(?:\s+as\s+\w+)?\s*:\s*$")),
]
ASPECT_TARGET = {
    "integration": "refresh kb/inferred/05-data-sources.md + 06-integrations.md",
    "assumption": "re-run assume0.py; extend kb/inferred/07-assumptions.md",
}
ADD_CAP = 40  # max additive findings shown per aspect

def sh(cmd, cwd):
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
    inv = os.path.join(kbroot, "kb", "derived", "inventory.md")
    for line in open(inv):
        if line.startswith("source_commit:"):
            return line.split(":", 1)[1].strip()
    sys.exit("no source_commit pin found in kb/derived/inventory.md")

def last_code_commit(repo):
    """The KB lives IN the repo (superdev/); its ship-loop commits move HEAD
    without changing product code. The pin target is therefore the last commit
    that touched anything OUTSIDE superdev/."""
    return sh(["git", "log", "-1", "--format=%h", "--", ".",
               ":(exclude)superdev"], repo).strip()

def parse_diff(repo, pin, head):
    """Returns (old_ranges: path -> [(start,end)] changed on the pinned side,
                added: path -> [(new_lineno, text)] lines added on the HEAD side)."""
    out = sh(["git", "diff", "--unified=0", f"{pin}..{head}", "--", ".",
              ":(exclude)superdev"], repo)
    old_ranges, added = defaultdict(list), defaultdict(list)
    old_path = new_path = None
    new_ln = 0
    for ln in out.splitlines():
        if ln.startswith("--- a/"):
            old_path = ln[6:]
        elif ln.startswith("--- /dev/null"):
            old_path = None
        elif ln.startswith("+++ b/"):
            new_path = ln[6:]
        elif ln.startswith("+++ /dev/null"):
            new_path = None
        m = HUNK.match(ln)
        if m:
            if old_path:
                start = int(m.group(1)); n = int(m.group(2) or "1")
                old_ranges[old_path].append((start, max(start, start + n - 1)))
            new_ln = int(m.group(3))
            continue
        if ln.startswith("+") and not ln.startswith("+++") and new_path:
            added[new_path].append((new_ln, ln[1:]))
            new_ln += 1
    return old_ranges, added

def additive_findings(added):
    finds = defaultdict(list)   # aspect -> [(path, lineno, snippet)]
    for path, lines in added.items():
        if not path.endswith(CODE_EXT) or "test" in path.lower():
            continue
        for lineno, text in lines:
            for aspect, pat in ADDITIVE:
                if pat.search(text):
                    finds[aspect].append((path, lineno, text.strip()[:90]))
                    break
    return finds

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--queue", action="store_true")
    args = ap.parse_args()
    cfg = load_config(args.config)
    repo = os.path.expanduser(cfg["repo"])
    kbroot = os.path.dirname(os.path.abspath(args.config))
    pin = pinned_sha(kbroot)
    head = last_code_commit(repo)

    if head == pin:
        print(f"KB pin {pin} == last code commit — nothing stale.")
        return

    n_commits = sh(["git", "rev-list", "--count", f"{pin}..{head}", "--", ".",
                    ":(exclude)superdev"], repo).strip()
    ranges, added = parse_diff(repo, pin, head)
    changed_files = set(ranges.keys())
    deleted = {f for f in changed_files
               if not os.path.exists(os.path.join(repo, f))}

    findings = []   # (kb_file, cited_path, cited_range, severity)
    for root, dirs, files in os.walk(kbroot):
        dirs[:] = [d for d in dirs if d not in {".git", "derived"}]
        for f in files:
            if not f.endswith(".md"):
                continue
            kbf = os.path.relpath(os.path.join(root, f), kbroot)
            src = open(os.path.join(root, f), encoding="utf-8").read()
            for m in CITE.finditer(src):
                path, a, b = m.group(1), int(m.group(2)), int(m.group(3) or m.group(2))
                if path in deleted:
                    findings.append((kbf, path, f"{a}-{b}", "cited-file-DELETED"))
                elif path in changed_files:
                    hit = any(not (b < s or a > e) for s, e in ranges[path])
                    findings.append((kbf, path, f"{a}-{b}",
                                     "cited-lines-changed" if hit else "file-changed-elsewhere"))

    adds = additive_findings(added)

    # dependency drift: manifest/lockfile changed → versions moved → the
    # version-pinned gotcha cards (09-dependency-practices) may no longer apply.
    MANIFESTS = ("requirements.txt", "pyproject.toml", "poetry.lock",
                 "package.json", "package-lock.json", "pnpm-lock.yaml")
    dep_changed = sorted({f for f in changed_files
                          if os.path.basename(f) in MANIFESTS})

    print(f"KB pin {pin} → last code commit {head} ({n_commits} code commits behind)")
    print(f"changed files since pin: {len(changed_files)}\n")
    print("DERIVED layer: stale by definition — re-run seed0.py + assume0.py to re-pin.\n")

    hard = [x for x in findings if x[3] != "file-changed-elsewhere"]
    soft = [x for x in findings if x[3] == "file-changed-elsewhere"]
    if hard:
        print("SUBTRACTIVE — stale citations (cited lines changed or file deleted); demote to challenged:")
        for kbf, p, r, sev in hard:
            print(f"  - {kbf}  cites  {p}:{r}  [{sev}]")
    if soft:
        print("\nSUBTRACTIVE (weak) — cited file changed, cited lines untouched; spot-check:")
        for kbf, p, r, sev in soft:
            print(f"  - {kbf}  cites  {p}:{r}")
    if not findings:
        print("SUBTRACTIVE: no KB citations touch the changed files.")

    if adds:
        print("\nADDITIVE — new surface since pin, not yet covered by the KB:")
        for aspect in sorted(adds):
            items = adds[aspect]
            print(f"  [{aspect}] {len(items)} new"
                  f"{', showing ' + str(ADD_CAP) if len(items) > ADD_CAP else ''}"
                  f"  ->  {ASPECT_TARGET[aspect]}")
            for path, lineno, snip in items[:ADD_CAP]:
                print(f"    + {path}:{lineno}  {snip}")
    else:
        print("\nADDITIVE: no new integration/assumption surface detected in the diff.")

    if dep_changed:
        print("\nDEPENDENCY drift — manifests/lockfiles changed; versions may "
              "have moved. Re-run deps0.py and re-verify version-pinned cards "
              "in kb/inferred/09-dependency-practices.md for changed deps:")
        for f in dep_changed:
            print(f"  ~ {f}")

    if args.queue and (findings or adds or dep_changed):
        now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        with open(os.path.join(kbroot, "QUEUE.md"), "a") as fh:
            fh.write(f"\n## Staleness — drift run {now} ({pin}→{head})\n\n")
            for kbf, p, r, sev in hard:
                fh.write(f"- [ ] re-verify `{kbf}` — cites `{p}:{r}` [{sev}]\n")
            for kbf, p, r, sev in soft:
                fh.write(f"- [ ] spot-check `{kbf}` — cites `{p}:{r}` [file changed elsewhere]\n")
            for aspect in sorted(adds):
                fh.write(f"- [ ] additive drift [{aspect}]: {len(adds[aspect])} "
                         f"new site(s) — {ASPECT_TARGET[aspect]}\n")
            for f in dep_changed:
                fh.write(f"- [ ] dependency drift: `{f}` changed — re-run deps0, "
                         f"re-verify 09-dependency-practices cards for moved versions\n")
        print("\nAppended drift items to QUEUE.md")

if __name__ == "__main__":
    main()
