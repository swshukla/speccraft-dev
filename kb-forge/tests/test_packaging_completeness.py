"""Regression guard: the built wheel must contain the entire forge tree.

speccraft/forge/ is deliberately NOT an importable package — it has no
__init__.py, its scripts are executed by path and import each other as
siblings. That means nothing about normal package discovery guarantees the
files reach the wheel: they ship purely because of

    [tool.setuptools.package-data]
    speccraft = ["forge/**/*"]

Historically this was doubly covered (PEP 420 namespace discovery also picked
forge/ up as a package), which made the packaging config's real dependency
invisible — a change to either mechanism could silently drop files from the
wheel and only surface as a broken install on a user's machine.

Worse, glob behaviour is not stable across build environments: setuptools 83
excludes dot-directories from package-data globs while 84 includes them, so
the eval fixtures under fixtures/*/.speccraft/ shipped only because CI happened
to resolve a new enough setuptools. The globs are now explicit, and this test
is what keeps them honest.

It builds an actual wheel and asserts every git-tracked file under
speccraft/forge/ is present — including the non-.py assets (kbforge-init.sh,
session-kit/, SPEC.md) that no import-level test would notice were missing.

Note: the wheel is built in-process via setuptools.build_meta using the
ambient setuptools, not in an isolated PEP 517 env like CI. That is deliberate
— it is the stricter of the two paths (the ambient version here is the one
that drops dot-dirs), so a config that passes locally also ships correctly
from CI. It also keeps the test dependency-free and fast.
"""
import io
import os
import pathlib
import shutil
import subprocess
import zipfile

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
FORGE_DIR = REPO_ROOT / "speccraft" / "forge"

IGNORE = shutil.ignore_patterns(
    "__pycache__", "*.pyc", ".git", "dist", "build", "*.egg-info", ".pytest_cache",
)


def _expected_forge_files():
    """Every git-tracked file under speccraft/forge/, as wheel-relative paths.

    Tracked files, not a working-tree walk: an untracked .DS_Store or a local
    scratch file is not part of the package and must not make this test fail.
    """
    out = subprocess.run(
        ["git", "ls-files", "-z", "--", "speccraft/forge"],
        cwd=str(REPO_ROOT), capture_output=True, text=True, check=True,
    ).stdout
    return {p for p in out.split("\0") if p}


@pytest.fixture(scope="module")
def built_wheel(tmp_path_factory):
    """Build a wheel from a pristine copy of the working tree."""
    build_meta = pytest.importorskip(
        "setuptools.build_meta",
        reason="setuptools is required to build the wheel under test",
    )
    src = tmp_path_factory.mktemp("src") / "pkg"
    shutil.copytree(REPO_ROOT, src, ignore=IGNORE)
    outdir = tmp_path_factory.mktemp("wheel")

    cwd = os.getcwd()
    os.chdir(src)
    try:
        name = build_meta.build_wheel(str(outdir))
    finally:
        os.chdir(cwd)
    return zipfile.ZipFile(outdir / name)


def test_wheel_contains_entire_forge_tree(built_wheel):
    shipped = set(built_wheel.namelist())
    expected = _expected_forge_files()
    assert expected, "no forge files found in the source tree — test is misconfigured"

    missing = sorted(expected - shipped)
    assert not missing, (
        f"{len(missing)} file(s) under speccraft/forge/ are missing from the built "
        f"wheel — an installed user would get a broken forge even though every "
        f"import test passes locally:\n  " + "\n  ".join(missing)
    )


def test_wheel_ships_forge_entrypoint_scripts(built_wheel):
    """The scripts the git hooks invoke by path must be in the wheel."""
    shipped = set(built_wheel.namelist())
    for script in ("gate.py", "drift.py", "deps0.py", "dep-diff.py",
                   "recall.py", "signals.py", "kbforge-init.sh"):
        target = f"speccraft/forge/{script}"
        assert target in shipped, f"{target} missing from the wheel"


def test_forge_is_not_shipped_as_an_importable_package(built_wheel):
    """forge/ must stay a script tree, not become a package.

    If someone adds an __init__.py, package-qualified imports start working in
    the dev monorepo while still failing for installed users (the layout that
    broke gate.py in 0.7.2). Fail loudly at packaging time instead.
    """
    assert not (FORGE_DIR / "__init__.py").exists(), (
        "speccraft/forge/__init__.py exists. forge is a tree of standalone "
        "scripts run by path under an arbitrary interpreter; making it a package "
        "invites `from speccraft.forge import ...` imports that work in the dev "
        "tree and raise ModuleNotFoundError once installed."
    )
    assert "speccraft/forge/__init__.py" not in set(built_wheel.namelist())


def test_no_package_qualified_forge_imports():
    """No forge script may import itself through the speccraft package."""
    offenders = []
    for path in sorted(FORGE_DIR.rglob("*.py")):
        if "__pycache__" in path.parts:
            continue
        text = io.open(path, encoding="utf-8").read()
        for lineno, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith(("from speccraft", "import speccraft")):
                offenders.append(f"{path.relative_to(REPO_ROOT)}:{lineno}: {stripped}")
    assert not offenders, (
        "forge scripts must import siblings directly (`import signals`), not "
        "through the speccraft package — the package is not importable when the "
        "scripts run from ~/.speccraft/kb-forge under a bare python3:\n  "
        + "\n  ".join(offenders)
    )
