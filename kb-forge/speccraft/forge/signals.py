#!/usr/bin/env python3
"""SIGNALS.md — mechanical drift projection with fenced, region-scoped writes.

Regions (drift, deps, advisories) are each owned by one writer and replaced
whole on every run, so SIGNALS.md is a projection of current state: dedup and
decay require no bookkeeping. The top header is a live open-signal count.
"""
import os
import re

SIGNALS = "SIGNALS.md"
ARCHIVE = "QUEUE-ARCHIVE.md"
REGIONS = ("drift", "deps", "advisories")


def _fence(region):
    return f"<!-- signals:{region} -->", f"<!-- /signals:{region} -->"


def _skeleton():
    parts = ["# SIGNALS — 0 open mechanical signals\n\n"]
    for r in REGIONS:
        o, c = _fence(r)
        parts.append(f"{o}\n{c}\n\n")
    return "".join(parts)


def _path(kbroot):
    return os.path.join(kbroot, SIGNALS)


def read_region(kbroot, region):
    path = _path(kbroot)
    if not os.path.exists(path):
        return ""
    text = open(path, encoding="utf-8").read()
    o, c = _fence(region)
    m = re.search(re.escape(o) + r"\n?(.*?)\n?" + re.escape(c), text, re.S)
    return m.group(1) if m else ""


def read_lines(kbroot, region):
    return [ln for ln in read_region(kbroot, region).splitlines()
            if ln.startswith("- [ ]")]


def _refresh_header(text):
    n = len(re.findall(r"(?m)^- \[ \]", text))
    plural = "signal" if n == 1 else "signals"
    header = f"# SIGNALS — {n} open mechanical {plural}"
    lines = text.splitlines()
    if lines and lines[0].startswith("# SIGNALS —"):
        lines[0] = header
        return "\n".join(lines) + ("\n" if text.endswith("\n") else "")
    return header + "\n\n" + text


def write_region(kbroot, region, body):
    path = _path(kbroot)
    text = open(path, encoding="utf-8").read() if os.path.exists(path) else _skeleton()
    o, c = _fence(region)
    if o not in text:
        text = text.rstrip("\n") + f"\n\n{o}\n{c}\n"
    replacement = f"{o}\n{body}\n{c}" if body else f"{o}\n{c}"
    pat = re.compile(re.escape(o) + r"\n.*?\n?" + re.escape(c), re.S)
    text = pat.sub(lambda _m: replacement, text)
    text = _refresh_header(text)
    open(path, "w", encoding="utf-8").write(text)


def archive_resolved(kbroot, resolved_lines):
    if not resolved_lines:
        return
    with open(os.path.join(kbroot, ARCHIVE), "a", encoding="utf-8") as fh:
        for line in resolved_lines:
            fh.write(line + "\n")
