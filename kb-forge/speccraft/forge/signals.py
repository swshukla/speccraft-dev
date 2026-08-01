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


def _region_bounds(text, region):
    """Return (start, end) char offsets of the whole fenced block for `region`,
    or None if absent. Parses regions in order to ensure correct matching even
    if a region's body contains another region's fence-marker text."""
    bounds = {}
    pos = 0
    for r in REGIONS:
        o_r, c_r = _fence(r)
        i = text.find(o_r, pos)
        if i == -1:
            bounds[r] = None
            continue
        j = text.find(c_r, i + len(o_r))
        if j == -1:
            bounds[r] = None
            continue
        bounds[r] = (i, j + len(c_r))
        pos = j + len(c_r)  # Continue searching after this region
    return bounds.get(region)


def read_region(kbroot, region):
    path = _path(kbroot)
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    b = _region_bounds(text, region)
    if not b:
        return ""
    o, c = _fence(region)
    return text[b[0] + len(o):b[1] - len(c)].strip("\n")


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
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    else:
        text = _skeleton()
    o, c = _fence(region)
    b = _region_bounds(text, region)
    replacement = f"{o}\n{body}\n{c}" if body else f"{o}\n{c}"
    if b:
        text = text[:b[0]] + replacement + text[b[1]:]
    else:
        text = text.rstrip("\n") + f"\n\n{replacement}\n"
    text = _refresh_header(text)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def archive_resolved(kbroot, resolved_lines):
    if not resolved_lines:
        return
    with open(os.path.join(kbroot, ARCHIVE), "a", encoding="utf-8") as fh:
        for line in resolved_lines:
            fh.write(line + "\n")
