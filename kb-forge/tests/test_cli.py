"""Tests for the speccraft CLI's shell-out layer.

The interesting behaviour here is all about *how* the bash scripts under
forge/ get launched — Windows has no shebang handling, so cmd_init must
resolve an interpreter itself and hand it POSIX-shaped paths.
"""
import os
import sys
import types

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from speccraft import cli  # noqa: E402


@pytest.fixture
def calls(monkeypatch):
    """Capture subprocess.call args instead of running the installer."""
    recorded = {}

    def fake_call(argv, **kwargs):
        recorded["argv"] = argv
        recorded["kwargs"] = kwargs
        return 0

    monkeypatch.setattr(cli.subprocess, "call", fake_call)
    monkeypatch.setattr(cli, "_ensure_kbforge_home_link", lambda forge_dir: None)
    return recorded


def _init(repo):
    return cli.cmd_init(types.SimpleNamespace(repo=str(repo)))


def test_init_launches_script_through_bash(calls, tmp_path):
    assert _init(tmp_path) == 0
    argv = calls["argv"]
    assert os.path.basename(argv[0]).lower().startswith("bash")
    assert argv[1].endswith("/kbforge-init.sh")


def test_init_passes_posix_style_paths(calls, tmp_path):
    """Git Bash does not treat \\ as a separator; dirname would return '.'."""
    _init(tmp_path)
    for arg in calls["argv"][1:]:
        assert "\\" not in arg


def test_init_pins_the_interpreter_for_the_script(calls, tmp_path):
    """forge scripts call python3, which often does not exist on Windows."""
    _init(tmp_path)
    env = calls["kwargs"]["env"]
    assert env["SPECCRAFT_PYTHON"] == sys.executable.replace("\\", "/")


def test_init_pins_utf8_stdio_for_the_forge_scripts(calls, tmp_path):
    """The harvesters print unicode (arrows, checkmarks, box-drawing) to
    stdout. On Windows, a cp1252 console raises UnicodeEncodeError at
    print() time unless PYTHONIOENCODING forces UTF-8. This env var is
    inherited by every child python.exe the bash script spawns."""
    _init(tmp_path)
    env = calls["kwargs"]["env"]
    assert env["PYTHONIOENCODING"] == "utf-8"


def test_init_honours_an_explicit_bash(calls, tmp_path, monkeypatch):
    monkeypatch.setenv("SPECCRAFT_BASH", "/opt/custom/bash")
    _init(tmp_path)
    assert calls["argv"][0] == "/opt/custom/bash"


def test_missing_bash_reports_actionably(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli, "_ensure_kbforge_home_link", lambda forge_dir: None)
    monkeypatch.setattr(cli.shutil, "which", lambda name: None)
    monkeypatch.setattr(cli.os.path, "exists", lambda p: False)
    monkeypatch.delenv("SPECCRAFT_BASH", raising=False)

    assert _init(tmp_path) == 1
    err = capsys.readouterr().err
    assert "bash" in err.lower()
    assert "git for windows" in err.lower() or "install" in err.lower()
