#!/usr/bin/env python3
"""kb-forge decay — queue hygiene by age (trust-decay spec, Mechanism B).

Archives MECHANICAL QUEUE.md sections (drift / dep-diff runs) older than
`queue_archive_days` (kbforge.yaml, default 30) into QUEUE-ARCHIVE.md,
leaving a one-line digest in place. Safe because, with drift.py --demote in
the ship loop, the durable state of a stale fact lives in its `status:`
field — these queue items are notifications, and the next drift run
re-detects anything still live.

ADJUDICATION items (session divergences, anything outside the mechanical
section headers) are NEVER archived: they are the human questions the queue
exists for. They age visibly instead (briefing trust line). This split is
what keeps archiving from becoming neglect-laundering.

Usage: python3 decay.py --config /path/to/.speccraft/kbforge.yaml
"""
import argparse, os, re, sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from recall import log_telemetry
from drift import load_config

MECH_HEADER = re.compile(
    r"^## (?:Staleness — drift run|Dependency drift — dep-diff run) "
    r"(\d{4}-\d{2}-\d{2})")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    args = ap.parse_args()
    cfg = load_config(args.config)
    kbroot = os.path.dirname(os.path.abspath(args.config))
    days = int(cfg.get("queue_archive_days", "30") or "30")
    qpath = os.path.join(kbroot, "QUEUE.md")
    if not os.path.exists(qpath):
        return

    now = datetime.now(timezone.utc)
    today = now.strftime("%Y-%m-%d")
    lines = open(qpath, encoding="utf-8").read().splitlines(keepends=True)

    keep, archived, arch_lines = [], 0, []
    i = 0
    while i < len(lines):
        m = MECH_HEADER.match(lines[i])
        if m:
            # bound the section: up to the next "## " header or EOF
            j = i + 1
            while j < len(lines) and not lines[j].startswith("## "):
                j += 1
            try:
                sec_date = datetime.strptime(m.group(1), "%Y-%m-%d")
                age = (now.replace(tzinfo=None) - sec_date).days
            except ValueError:
                age = 0
            items = sum(1 for l in lines[i:j] if l.startswith("- [ ]"))
            if age > days and items > 0:
                arch_lines += lines[i:j]
                keep.append(f"> archived {today}: {items} mechanical item(s) "
                            f"from \"{lines[i].strip('# \n')}\" "
                            f"→ QUEUE-ARCHIVE.md\n")
                archived += items
                i = j
                continue
        keep.append(lines[i])
        i += 1

    if not archived:
        return
    with open(os.path.join(kbroot, "QUEUE-ARCHIVE.md"), "a",
              encoding="utf-8") as fh:
        fh.write(f"\n<!-- archived {today} by decay.py -->\n")
        fh.writelines(arch_lines)
    open(qpath, "w", encoding="utf-8").write("".join(keep))
    log_telemetry(kbroot, "queue_archive", str(archived), "ship-loop")
    print(f"decay: archived {archived} mechanical queue item(s) older than "
          f"{days}d → QUEUE-ARCHIVE.md (adjudication items never archive)")

if __name__ == "__main__":
    main()
