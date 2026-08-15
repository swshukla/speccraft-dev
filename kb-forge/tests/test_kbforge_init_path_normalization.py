"""Tests for the Windows path-normalization block in kbforge-init.sh.

kbforge-init.sh resolves $REPO via `cd "$REPO" && pwd`, then (since the
Windows patch) optionally rewrites it through `cygpath -m` / `pwd -W` so the
value later written into kbforge.yaml's `repo:` field is resolvable by a
*native* Windows Python interpreter — plain Git-Bash `pwd` emits MSYS-style
paths (/c/Users/x/...) that Python on Windows cannot resolve when read back
as plain text from a file (see kbforge-init.sh's comment on the block).

These tests exercise the actual block (extracted verbatim from the script,
not reimplemented) under three conditions:
  1. No cygpath, no `pwd -W` — the real state of this dev machine (macOS) —
     must be a no-op.
  2. A stub `cygpath` on PATH — must be invoked as `cygpath -m "$REPO"` and
     its output must become the new $REPO.
  3. No cygpath, but `pwd -W` available (shadowed via a shell function) —
     must resolve against $REPO's own directory, not the caller's cwd. This
     is a regression test for the bug in the user's original patch, whose
     `elif pwd -W` branch read the CALLER's cwd rather than $REPO.
"""
import os
import stat
import subprocess
import sys

FORGE_SH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "speccraft", "forge", "kbforge-init.sh",
)


def _extract_normalization_block() -> str:
    """Pull the `if command -v cygpath ... fi` block out of kbforge-init.sh
    verbatim, so the test runs the real shipped code, not a re-typed copy."""
    with open(FORGE_SH, encoding="utf-8") as fh:
        lines = fh.readlines()
    start = next(i for i, l in enumerate(lines) if l.startswith("if command -v cygpath"))
    end = next(i for i in range(start, len(lines)) if lines[i].rstrip("\n") == "fi")
    return "".join(lines[start:end + 1])


NORMALIZATION_BLOCK = _extract_normalization_block()


def _run_block(repo_dir: str, extra_prefix: str = "", extra_path: str = "") -> str:
    env = dict(os.environ)
    if extra_path:
        env["PATH"] = extra_path + os.pathsep + env.get("PATH", "")
    script = f'REPO={repo_dir!r}\n{extra_prefix}\n{NORMALIZATION_BLOCK}\nprintf "%s" "$REPO"\n'
    result = subprocess.run(
        ["bash", "-c", script], capture_output=True, text=True, env=env, check=True,
    )
    return result.stdout


def test_noop_when_no_cygpath_and_no_pwd_dash_w(tmp_path):
    """Real-world macOS/Linux case: neither cygpath nor `pwd -W` exist, so
    the block must leave $REPO exactly as `cd && pwd` resolved it."""
    repo = tmp_path / "proj"
    repo.mkdir()
    resolved = subprocess.run(
        ["bash", "-c", f'cd {str(repo)!r} && pwd'],
        capture_output=True, text=True, check=True,
    ).stdout.strip()

    out = _run_block(str(repo))
    assert out == resolved, "normalization block must be a no-op without cygpath/pwd -W"


def test_uses_cygpath_dash_m_when_available(tmp_path):
    """When `cygpath` is on PATH, the block must call it as `cygpath -m
    "$REPO"` (mixed form, forward slashes) and adopt its output — not
    `cygpath -w` (which would emit backslashes)."""
    repo = tmp_path / "proj"
    repo.mkdir()
    bindir = tmp_path / "fakebin"
    bindir.mkdir()
    stub = bindir / "cygpath"
    stub.write_text(
        "#!/bin/bash\n"
        'if [ "$1" = "-m" ]; then echo "MIXED:$2"; else echo "WRONG_FLAG:$*"; exit 1; fi\n'
    )
    stub.chmod(stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    out = _run_block(str(repo), extra_path=str(bindir))
    assert out.startswith("MIXED:"), f"expected cygpath -m to be used, got: {out!r}"
    assert out == f"MIXED:{repo}"


def test_pwd_dash_w_fallback_resolves_against_repo_not_caller_cwd(tmp_path):
    """Regression test for the bug in the reviewed patch: its `elif pwd -W`
    branch called bare `pwd -W`, which reports the CALLER's cwd — silently
    resolving to the wrong directory whenever `speccraft init /other/repo`
    is run from a different cwd. The shipped fix `cd`s into $REPO first.

    No real Windows box is available, so `pwd -W` is simulated via a shell
    function (bash functions shadow builtins) that behaves like Git Bash's
    `pwd -W`: it reports the CURRENT directory, formatted. This is enough to
    prove the shipped code resolves against $REPO's own directory rather
    than whatever directory happened to be current when the script started.
    """
    repo = tmp_path / "target_repo"
    repo.mkdir()
    caller_cwd = tmp_path / "unrelated_caller_cwd"
    caller_cwd.mkdir()

    # Shadow `pwd` with a function that supports -W (Git-Bash-style) by
    # tagging whatever `command pwd` reports for the current directory.
    fake_pwd_fn = (
        "pwd() { if [ \"$1\" = \"-W\" ]; then echo \"W:$(command pwd)\"; "
        "else command pwd; fi; }\n"
    )
    # `command -v cygpath` must fail (no cygpath stub on PATH) so we fall
    # into the elif branch under test.
    script = (
        f"cd {str(caller_cwd)!r}\n"
        f"{fake_pwd_fn}"
        f"REPO={str(repo)!r}\n"
        f"{NORMALIZATION_BLOCK}\n"
        'printf "%s" "$REPO"\n'
    )
    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
    out = result.stdout

    assert out == f"W:{repo}", (
        f"pwd -W fallback must resolve against $REPO ({repo}), not the "
        f"caller's cwd ({caller_cwd}); got {out!r}"
    )
