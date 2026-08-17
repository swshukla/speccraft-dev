"""Regression guard for the installed-layout import class of bug.

In the dev monorepo the forge scripts live at ``kb-forge/speccraft/forge/*.py``,
so ``dirname(dirname(dirname(__file__)))`` happens to be ``kb-forge/`` — a
directory that contains the ``speccraft`` package. Installed, they are reached
through ``~/.speccraft/kb-forge`` (a symlink/junction pointing at
``<site-packages>/speccraft/forge``), and ``os.path.abspath`` does NOT resolve
that link: the same expression yields ``$HOME``, so ``from speccraft.forge
import signals`` raises ModuleNotFoundError. The pre-commit hook runs these
scripts with a bare ``python3`` (which is generally not the pipx venv that has
speccraft installed), so nothing else puts the package on sys.path either.

Every forge script must therefore be importable standing alone — with only its
own directory on sys.path and no ``speccraft`` package anywhere. This test
copies the forge directory flat into a tmpdir (exactly the installed shape),
strips PYTHONPATH, and executes each module's top level in a subprocess.
"""
import os
import pathlib
import shutil
import subprocess
import sys

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
FORGE_DIR = REPO_ROOT / "speccraft" / "forge"

RUNNER = (
    "import importlib.util, sys\n"
    "spec = importlib.util.spec_from_file_location('forge_mod_under_test', sys.argv[1])\n"
    "mod = importlib.util.module_from_spec(spec)\n"
    "spec.loader.exec_module(mod)\n"
)


def _forge_scripts():
    return sorted(p.name for p in FORGE_DIR.glob("*.py"))


@pytest.fixture(scope="module")
def flat_forge(tmp_path_factory):
    """The forge dir copied somewhere with no ``speccraft`` package above it."""
    dest = tmp_path_factory.mktemp("installed") / "kb-forge"
    shutil.copytree(FORGE_DIR, dest,
                    ignore=shutil.ignore_patterns("__pycache__"))
    return dest


@pytest.mark.parametrize("script", _forge_scripts())
def test_forge_script_imports_standalone(flat_forge, script, tmp_path):
    env = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    proc = subprocess.run(
        [sys.executable, "-c", RUNNER, str(flat_forge / script)],
        cwd=str(tmp_path), env=env, capture_output=True, text=True,
    )
    assert proc.returncode == 0, (
        f"{script} fails to import in the installed layout (forge dir reached "
        f"through ~/.speccraft/kb-forge, no speccraft package on sys.path):\n"
        f"{proc.stderr}"
    )
