"""Regression guard for the Windows encoding class of bug.

Python's `open()` defaults to `locale.getpreferredencoding(False)` when no
`encoding=` is given. On Windows that is typically cp1252, not UTF-8. speccraft
writes/reads UTF-8 text everywhere (KB markdown carries unicode arrows,
checkmarks, box-drawing characters), so any text-mode `open()` call missing
an explicit `encoding=` argument will raise UnicodeEncodeError/
UnicodeDecodeError on Windows even though it works fine on macOS/Linux (whose
locale encoding is usually already UTF-8) — which is exactly why this class
of bug shipped unnoticed.

This test walks the AST of every .py file under speccraft/ and fails if any
text-mode open() call (i.e. no binary "b" in its mode) lacks `encoding=`.
It pins the whole class of bug, not just the one call site (deps0.py:370)
a Windows user happened to hit and patch locally.
"""
import ast
import pathlib

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGE_ROOT = REPO_ROOT / "speccraft"


def _iter_py_files():
    return sorted(PACKAGE_ROOT.rglob("*.py"))


def _mode_of(call: ast.Call):
    """Best-effort extraction of the `mode` argument (positional or kw)."""
    if len(call.args) >= 2 and isinstance(call.args[1], ast.Constant):
        return call.args[1].value
    for kw in call.keywords:
        if kw.arg == "mode" and isinstance(kw.value, ast.Constant):
            return kw.value.value
    return None


def _find_unencoded_text_opens(path: pathlib.Path):
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    offenders = []
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                and node.func.id == "open"):
            continue
        has_encoding = any(kw.arg == "encoding" for kw in node.keywords)
        # a bare **kwargs forward (e.g. open(path, **kwargs)) could smuggle
        # an encoding= in dynamically; don't flag those as false positives.
        has_star_kwargs = any(kw.arg is None for kw in node.keywords)
        mode = _mode_of(node)
        is_binary = isinstance(mode, str) and "b" in mode
        if not has_encoding and not has_star_kwargs and not is_binary:
            offenders.append(node.lineno)
    return offenders


@pytest.mark.parametrize("path", _iter_py_files(), ids=lambda p: str(p.relative_to(REPO_ROOT)))
def test_no_unencoded_text_mode_open(path):
    offenders = _find_unencoded_text_opens(path)
    assert not offenders, (
        f"{path.relative_to(REPO_ROOT)}: text-mode open() missing encoding= "
        f"at line(s) {offenders} — this reads/writes with the platform locale "
        f"encoding, which is cp1252 (not UTF-8) on Windows and will raise "
        f"UnicodeDecodeError/UnicodeEncodeError there even though it works "
        f"on macOS/Linux."
    )
