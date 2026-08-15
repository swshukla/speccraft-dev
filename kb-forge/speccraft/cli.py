"""speccraft — CLI wrapper around the kb-forge tooling.

Every subcommand shells out to the existing scripts under forge/ rather
than reimplementing their logic; this file only resolves paths and wires
argv through.
"""
import argparse
import importlib.resources
import os
import shutil
import subprocess
import sys


def _forge_dir() -> str:
    return str(importlib.resources.files("speccraft") / "forge")


def _posix(path: str) -> str:
    """Git Bash does not treat \\ as a path separator.

    Handing it C:\\Users\\x\\forge\\kbforge-init.sh makes dirname return '.',
    so $FORGE resolves to the caller's cwd. C:/Users/x/... it handles fine.
    """
    return path.replace("\\", "/")


def _find_bash() -> str:
    """Locate a bash able to run the forge scripts.

    Windows has no shebang handling, so the scripts cannot be exec'd
    directly — we must name the interpreter. On Windows we prefer Git for
    Windows over whatever `bash` is on PATH, because System32\\bash.exe is
    the WSL launcher: it runs in a different filesystem namespace where the
    C:/... paths we pass do not exist (they live under /mnt/c).
    """
    explicit = os.environ.get("SPECCRAFT_BASH")
    if explicit:
        return explicit

    if os.name == "nt":
        candidates = [
            os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"),
                         "Git", "bin", "bash.exe"),
            os.path.join(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
                         "Git", "bin", "bash.exe"),
            os.path.join(os.environ.get("LOCALAPPDATA", ""),
                         "Programs", "Git", "bin", "bash.exe"),
        ]
        for candidate in candidates:
            if os.path.exists(candidate):
                return candidate
        found = shutil.which("bash")
        # skip the WSL shim; it cannot see the Windows paths we hand it
        if found and "system32" not in found.lower():
            return found
        return ""

    found = shutil.which("bash")
    if found:
        return found
    return "/bin/bash" if os.path.exists("/bin/bash") else ""


def _run_forge_script(script: str, *script_args: str) -> int:
    bash = _find_bash()
    if not bash:
        print(
            "ERROR: speccraft needs bash to run its forge scripts, and none was found.\n"
            "  Windows: install Git for Windows (https://git-scm.com/download/win),\n"
            "           which provides bash.exe, then re-run this command.\n"
            "  Or point speccraft at one explicitly: set SPECCRAFT_BASH=<path to bash>",
            file=sys.stderr,
        )
        return 1

    env = dict(os.environ)
    # forge scripts call python3; on Windows that is typically missing (or is
    # the Store alias stub) even where python exists. Pin the interpreter that
    # is already running speccraft — it is known-good by construction.
    env.setdefault("SPECCRAFT_PYTHON", _posix(sys.executable))
    # The harvesters print unicode (arrows, checkmarks, box-drawing) to stdout.
    # A Windows console's default codepage (e.g. cp1252) raises
    # UnicodeEncodeError on those characters at print() time. This env var is
    # inherited by every child process the bash script spawns (each harvester
    # is a fresh `python.exe`, so per-process sys.stdout.reconfigure() calls
    # would each need doing separately — setting it once here covers all of
    # them). No-op on macOS/Linux, where stdout is already UTF-8.
    env.setdefault("PYTHONIOENCODING", "utf-8")

    argv = [bash, _posix(script)] + [_posix(a) for a in script_args]
    return subprocess.call(argv, env=env)


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
        # real directory already there (e.g. pre-existing manual clone, or a
        # Windows junction — which islink() does not report) — leave it alone
        return

    try:
        os.symlink(forge_dir, home_link)
    except OSError:
        if os.name != "nt":
            raise
        # Windows symlinks need Developer Mode or admin; a directory junction
        # needs neither and reads identically to the hooks' $HOME lookup.
        subprocess.call(["cmd", "/c", "mklink", "/J", home_link, forge_dir],
                        stdout=subprocess.DEVNULL)


def cmd_init(args: argparse.Namespace) -> int:
    forge_dir = _forge_dir()
    _ensure_kbforge_home_link(forge_dir)
    script = os.path.join(forge_dir, "kbforge-init.sh")
    return _run_forge_script(script, os.path.abspath(args.repo))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="speccraft")
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init", help="scaffold a .speccraft/ KB in a repo")
    p_init.add_argument("repo", nargs="?", default=".",
                        help="path to the target git repo (default: current directory)")
    p_init.set_defaults(func=cmd_init)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
