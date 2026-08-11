#!/usr/bin/env bash
# check-for: INV-1
# strict: true
#
# EXAMPLE fixture for speccraft-check documentation (Source B — a custom
# check script) — NOT wired into any product's kb/normative/checks/. Real
# and runnable: point it at any repo (via SPECCRAFT_REPO or cwd) and it
# will actually scan it.
#
# What it checks: every SQLAlchemy model class declared in the repo
# (`class Foo(Base):` / `class Foo(db.Model):`) should be reachable from
# wherever Alembic's `target_metadata` is assembled (typically
# `alembic/env.py`) — otherwise `alembic revision --autogenerate` silently
# ignores it and the table never gets a migration.
#
# check.py contract: run with cwd=<repo>, SPECCRAFT_REPO=<repo>, 120s
# timeout. Exit 0 = pass. Exit nonzero = violation; this script's stdout
# is what check.py surfaces in its report.
set -euo pipefail

REPO="${SPECCRAFT_REPO:-$(pwd)}"
cd "$REPO"

EXCLUDES=(--exclude-dir=.git --exclude-dir=.venv --exclude-dir=venv
          --exclude-dir=node_modules --exclude-dir=__pycache__)

# Files that assemble Alembic's target_metadata (usually alembic/env.py).
METADATA_FILES=$(grep -rlE 'target_metadata' --include='*.py' \
  "${EXCLUDES[@]}" . 2>/dev/null || true)

if [ -z "$METADATA_FILES" ]; then
  # No Alembic wiring in this repo at all — nothing for this check to do.
  exit 0
fi

# Model class declarations: `class Foo(Base):` / `class Foo(db.Model):`.
MODELS=$(grep -rhoE 'class +[A-Za-z_][A-Za-z0-9_]* *\((Base|db\.Model)\)' \
  --include='*.py' "${EXCLUDES[@]}" . 2>/dev/null \
  | sed -E 's/class +([A-Za-z_][A-Za-z0-9_]*).*/\1/' | sort -u || true)

MISSING=""
for model in $MODELS; do
  if ! grep -qE "\\b${model}\\b" $METADATA_FILES 2>/dev/null; then
    MISSING="${MISSING}${model}\n"
  fi
done

if [ -n "$MISSING" ]; then
  echo "SQLAlchemy models declared but absent from target_metadata (Alembic autogenerate will not see them):"
  printf '%b' "$MISSING" | sed 's/^/  - /'
  exit 1
fi

exit 0
