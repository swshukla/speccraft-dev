#!/usr/bin/env python3
"""kb-forge decay — archive hygiene by age (trust-decay spec, Mechanism B).

Under the projection model, drift / dep-diff regions self-clean: a fixed
finding just vanishes on the next projection run, so QUEUE.md never
accumulates stale mechanical sections and decay.py no longer touches it.

decay.py's only remaining job is trimming QUEUE-ARCHIVE.md: resolved-item
lines (`- resolved YYYY-MM-DD: ...`) older than `queue_archive_days`
(kbforge.yaml, default 30) are dropped; everything else (including
non-dated lines) is kept, in order.

ADJUDICATION items (session divergences in QUEUE.md) are never touched
here: they are the human questions the queue exists for, and age visibly
instead (briefing trust line).

Usage: python3 decay.py --config /path/to/.speccraft/kbforge.yaml
"""
import argparse, os, re, sys
from datetime import date, datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from recall import log_telemetry
from drift import load_config

_DATED = re.compile(r"^- resolved (\d{4}-\d{2}-\d{2}):")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    args = ap.parse_args()
    cfg = load_config(args.config)
    kbroot = os.path.dirname(os.path.abspath(args.config))
    days = int(cfg.get("queue_archive_days", "30") or "30")
    apath = os.path.join(kbroot, "QUEUE-ARCHIVE.md")
    if not os.path.exists(apath):
        return

    today = datetime.now(timezone.utc).date()
    cutoff = today - timedelta(days=days)
    lines = open(apath, encoding="utf-8").read().splitlines()

    kept, dropped = [], 0
    for ln in lines:
        m = _DATED.match(ln)
        if m:
            try:
                d = date.fromisoformat(m.group(1))
            except ValueError:
                kept.append(ln)
                continue
            if d < cutoff:
                dropped += 1
                continue
        kept.append(ln)

    if not dropped:
        return
    open(apath, "w", encoding="utf-8").write("\n".join(kept) + "\n")
    log_telemetry(kbroot, "queue_archive_trim", str(dropped), "ship-loop")
    print(f"decay: trimmed {dropped} resolved archive entr"
          f"{'y' if dropped == 1 else 'ies'} older than {days}d "
          f"from QUEUE-ARCHIVE.md")

if __name__ == "__main__":
    main()
