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

ANCHOR SCOPE — new files added under a fact's directory anchors since the pin
  (spec 2026-07-25-anchor-scope-drift.md rev 2). The fact governs those files
  implicitly; the founder verifies the fact still holds or narrows the anchor.
  Harness-independent backstop: catches files created via Bash, by humans, or
  in hookless harnesses. Normative-anchored findings queue (--queue) and feed
  the T2 judge (--judge-targets); inferred/decisions stay report-only.

Usage: python3 drift.py --config /path/to/<product>-kb/kbforge.yaml [--queue]
  --queue          append findings (all directions) to QUEUE.md
  --judge-targets  print machine-readable normative anchor-scope findings
                   (kb_file<TAB>anchor<TAB>added_file) and exit — consumed by
                   kb-audit.sh to seed the capped LLM-judge sample
"""
import argparse, os, re, subprocess, sys
from collections import defaultdict
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from recall import frontmatter, log_telemetry  # shared parser + telemetry
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))  # kb-forge/ root, for the speccraft package
from speccraft.forge import signals

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
    """The KB lives IN the repo (.speccraft/); its ship-loop commits move HEAD
    without changing product code. The pin target is therefore the last commit
    that touched anything OUTSIDE .speccraft/."""
    return sh(["git", "log", "-1", "--format=%h", "--", ".",
               ":(exclude).speccraft"], repo).strip()

def parse_diff(repo, pin, head):
    """Returns (old_ranges: path -> [(start,end)] changed on the pinned side,
                added: path -> [(new_lineno, text)] lines added on the HEAD side)."""
    out = sh(["git", "diff", "--unified=0", f"{pin}..{head}", "--", ".",
              ":(exclude).speccraft"], repo)
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

def demote(kbroot, findings, pin, head):
    """Trust decay Mechanism A (spec 2026-07-25-trust-decay.md): execute the
    demotion policy this file has always DECLARED (docstring line 11) but
    only printed. Trust rises only through the founder; it falls
    mechanically, on evidence, with a ledger entry. Policy by lane:
      inferred/decisions: cited-file-DELETED or cited-lines-changed → challenged
      normative:          cited-file-DELETED only → challenged (a ratified
                          fact citing a nonexistent file is the KB lying);
                          lines-changed stays founder-adjudicated (queue)
      derived:            never touched here (regenerated mechanically)
    Content is never modified — one status flip + a status_note, reversible
    by exactly one human action (speccraft-ratify)."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    demoted = []
    for kbf, path, rng, sev in findings:
        if sev == "file-changed-elsewhere":
            continue
        parts = kbf.split(os.sep)
        lane = parts[1] if len(parts) > 2 and parts[0] == "kb" else ""
        if lane in ("", "derived"):
            continue
        if lane == "normative" and sev != "cited-file-DELETED":
            continue
        p = os.path.join(kbroot, kbf)
        try:
            src = open(p, encoding="utf-8").read()
        except OSError:
            continue
        fm_end = src.find("\n---", 4)
        if fm_end < 0:
            continue
        m = re.search(r"^status:[ \t]*(\S+)", src[:fm_end], re.M)
        if not m or m.group(1) == "challenged":
            continue
        note = (f"status_note: auto-demoted {now} — cites {path}:{rng} "
                f"[{sev}] in {pin}..{head}")
        src = src[:m.start()] + f"status: challenged\n{note}" + src[m.end():]
        open(p, "w", encoding="utf-8").write(src)
        demoted.append((kbf, m.group(1), path, rng, sev))
        log_telemetry(kbroot, "auto_demote", f"{kbf} {m.group(1)}->challenged",
                      "ship-loop")
    if demoted:
        led = os.path.join(kbroot, "ledger")
        os.makedirs(led, exist_ok=True)
        with open(os.path.join(led, "trust-decay.md"), "a", encoding="utf-8") as fh:
            for kbf, old, path, rng, sev in demoted:
                fh.write(f"{now}  AUTO-DEMOTE  {kbf}  {old} → challenged\n"
                         f"  evidence: cites {path}:{rng} [{sev}] in {pin}..{head}\n"
                         f"  reverse-by: speccraft-ratify (founder)\n")
        print(f"\nAUTO-DEMOTED {len(demoted)} fact(s) to challenged "
              f"(ledger/trust-decay.md; reverse via speccraft-ratify):")
        for kbf, old, path, rng, sev in demoted:
            print(f"  ~ {kbf}  {old} → challenged  [{sev} {path}:{rng}]")
    return demoted

def anchor_scope_drift(kbroot, repo, pin, head):
    """Third drift direction: files ADDED since pin that fall under existing
    facts' directory anchors. --no-renames is load-bearing: a file moved into
    an anchored scope shows as R with rename detection and would be missed;
    decomposed, its add side lands here (the delete side is subtractive's).
    Returns {kb_file: (lane, [(anchor, [added_file, ...]), ...])}."""
    added = [f for f in sh(["git", "diff", "--name-only", "--no-renames",
                            "--diff-filter=A", f"{pin}..{head}", "--", ".",
                            ":(exclude).speccraft"], repo).splitlines() if f]
    finds = {}
    if not added:
        return finds
    for root, dirs, files in os.walk(kbroot):
        dirs[:] = [d for d in dirs if d not in {".git", "derived"}]
        for f in files:
            if not f.endswith(".md"):
                continue
            if f in {"QUEUE.md", "SIGNALS.md", "QUEUE-ARCHIVE.md"}:
                continue          # never re-ingest our own queue output
            p = os.path.join(root, f)
            kbf = os.path.relpath(p, kbroot)
            anchors = frontmatter(p).get("anchors") or []
            if isinstance(anchors, str):
                anchors = [anchors]
            rows = []
            for a in anchors:
                if a.startswith("topic:"):
                    continue
                pref = a.rstrip("/") + "/"   # directory-scope match only:
                hits = sorted(x for x in added if x.startswith(pref))
                if hits:
                    rows.append((a, hits))
            if rows:
                # deepest anchor first — pointed findings lead, broad trail
                rows.sort(key=lambda r: -r[0].rstrip("/").count("/"))
                parts = kbf.split(os.sep)
                lane = parts[1] if len(parts) > 2 and parts[0] == "kb" else "other"
                finds[kbf] = (lane, rows)
    return finds

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

def _anchor_scope_line(kbf, a, hits):
    """Verbatim rendering lifted from the old QUEUE.md writer (anchor-scope
    finding text) so the projected line is byte-for-byte identical."""
    shown = ", ".join(f"`{x}`" for x in hits[:ADD_CAP])   # not context
    over = f" (+{len(hits) - ADD_CAP} more)" if len(hits) > ADD_CAP else ""
    return (f"- [ ] anchor scope drift: `{kbf}` — new file(s) in "
            f"scope of `{a}`: {shown}{over}. Verify the fact applies "
            f"to these files or narrow its anchor.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--queue", action="store_true")
    ap.add_argument("--judge-targets", action="store_true")
    ap.add_argument("--demote", action="store_true",
                    help="execute the demotion policy on hard subtractive "
                         "findings (trust-decay spec); ship-loop only")
    args = ap.parse_args()
    cfg = load_config(args.config)
    repo = os.path.expanduser(cfg["repo"])
    kbroot = os.path.dirname(os.path.abspath(args.config))
    pin = pinned_sha(kbroot)
    head = last_code_commit(repo)

    if head == pin and not args.queue:
        if not args.judge_targets:
            print(f"KB pin {pin} == last code commit — nothing stale.")
        return

    scope = anchor_scope_drift(kbroot, repo, pin, head)
    if args.judge_targets:
        # machine-readable: normative-anchored scope findings only
        for kbf, (lane, rows) in sorted(scope.items()):
            if lane != "normative":
                continue
            for a, hits in rows:
                for x in hits:
                    print(f"{kbf}\t{a}\t{x}")
        return

    n_commits = sh(["git", "rev-list", "--count", f"{pin}..{head}", "--", ".",
                    ":(exclude).speccraft"], repo).strip()
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
            if f in {"QUEUE.md", "SIGNALS.md", "QUEUE-ARCHIVE.md"}:
                continue          # never re-ingest our own queue output
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

    if scope:
        print("\nANCHOR SCOPE drift — new files added under anchored paths since pin:")
        for kbf in sorted(scope, key=lambda k: (scope[k][0] != "normative", k)):
            lane, rows = scope[kbf]
            for a, hits in rows:
                over = f" (+{len(hits) - ADD_CAP} more)" if len(hits) > ADD_CAP else ""
                print(f"  {kbf}  (anchor: {a}) [{lane}]{over}")
                for x in hits[:ADD_CAP]:
                    print(f"    + {x}")

    scope_q = [(kbf, a, hits) for kbf, (lane, rows) in sorted(scope.items())
               if lane == "normative" for a, hits in rows]

    # dep_changed no longer queues here — dep-diff.py owns dependency queue
    # items (it has the precise story: package, old→new, affected cards).
    if args.queue:
        now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        lines = []
        for kbf, p, r, sev in sorted(hard):
            lines.append(f"- [ ] re-verify `{kbf}` — cites `{p}:{r}` [{sev}]")
        for kbf, p, r, sev in sorted(soft):
            lines.append(f"- [ ] spot-check `{kbf}` — cites `{p}:{r}` [file changed elsewhere]")
        for aspect in sorted(adds):
            lines.append(f"- [ ] additive drift [{aspect}]: {len(adds[aspect])} "
                         f"new site(s) — {ASPECT_TARGET[aspect]}")
        for kbf, a, hits in sorted(scope_q, key=lambda t: (t[0], t[1])):
            lines.append(_anchor_scope_line(kbf, a, hits))   # not context
        body = f"## drift (pin {pin} → head {head}, {now})\n" + "\n".join(lines)
        prev = set(signals.read_lines(kbroot, "drift"))
        resolved = [f"- resolved {now}: {ln[6:]}" for ln in sorted(prev - set(lines))]
        signals.archive_resolved(kbroot, resolved)
        signals.write_region(kbroot, "drift", body)

    if args.demote and findings:
        demote(kbroot, findings, pin, head)

if __name__ == "__main__":
    main()
