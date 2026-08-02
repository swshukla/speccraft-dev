#!/usr/bin/env python3
"""One-time: keep only the human lane (## Open + ## Ruled) in an installed
QUEUE.md, dropping every mechanical section. Run drift.py --queue afterwards to
regenerate SIGNALS.md from the current pin."""
import sys

DROP_PREFIXES = ("## Staleness", "## Dependency drift")


def split(text):
    """Keep every line except those inside a mechanical section (one whose
    heading starts with a DROP prefix). A section runs from its `## ` heading
    until the next `## ` heading."""
    out, keep = [], True
    for line in text.splitlines():
        if line.startswith("## "):
            keep = not line.startswith(DROP_PREFIXES)
        if keep:
            out.append(line)
    while out and out[-1].strip() == "":
        out.pop()
    return "\n".join(out) + "\n"


def main():
    path = sys.argv[1]
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(split(text))
    print(f"migrated {path}: kept human lane, dropped mechanical sections")


if __name__ == "__main__":
    main()
