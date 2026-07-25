"""speccraft — CLI wrapper around the kb-forge tooling.

Every subcommand shells out to the existing scripts under forge/ rather
than reimplementing their logic; this file only resolves paths and wires
argv through.
"""
import argparse
import importlib.resources
import os
import subprocess
import sys


def _forge_dir() -> str:
    return str(importlib.resources.files("speccraft") / "forge")


def _ensure_kbforge_home_link(forge_dir: str) -> None:
    """Point ~/.speccraft/kb-forge at the installed forge dir.

    This is what lets the hooks' KBFORGE_HOME default
    (${KBFORGE_HOME:-$HOME/.speccraft/kb-forge}) keep working without the
    user ever setting an env var.
    """
    home_link = os.path.join(os.path.expanduser("~"), ".speccraft", "kb-forge")
    os.makedirs(os.path.dirname(home_link), exist_ok=True)

    if os.path.islink(home_link):
        if os.readlink(home_link) == forge_dir:
            return
        os.remove(home_link)
    elif os.path.exists(home_link):
        # real directory already there (e.g. pre-existing manual clone) — leave it alone
        return

    os.symlink(forge_dir, home_link)


def cmd_init(args: argparse.Namespace) -> int:
    forge_dir = _forge_dir()
    _ensure_kbforge_home_link(forge_dir)
    script = os.path.join(forge_dir, "kbforge-init.sh")
    return subprocess.call([script, args.repo])


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="speccraft")
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init", help="scaffold a .speccraft/ KB in a repo")
    p_init.add_argument("repo", help="path to the target git repo")
    p_init.set_defaults(func=cmd_init)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
