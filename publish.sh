#!/usr/bin/env bash
#
# publish.sh — release the speccraft package to PyPI from this dev monorepo.
#
# The dev repo (origin → swshukla/speccraft-dev) and the package repo
# (speccraft → swshukla/speccraft) share NO git history, so you can never
# `git push` / `git subtree push` between them. This script instead SNAPSHOTS
# the current `kb-forge/` tree onto the package repo's tip as one release
# commit, then pushes a vX.Y.Z tag to trigger the PyPI publish workflow.
#
# kb-forge/ is a complete mirror of the package repo root (pyproject.toml,
# README, LICENSE, .github/workflows/publish.yml, speccraft/), so the snapshot
# is faithful and the publish workflow is carried along automatically.
#
# Usage:
#   ./publish.sh <version> [--dry-run] [--yes]
#     <version>   semver, e.g. 0.2.1  (no leading 'v')
#     --dry-run   do everything locally but push/tag NOTHING; then clean up
#     --yes       skip the final confirmation prompt
#
set -euo pipefail

DEV_REMOTE=origin          # swshukla/speccraft-dev  (dev workspace)
PKG_REMOTE=speccraft       # swshukla/speccraft      (PyPI publish target)
SUBDIR=kb-forge            # package source inside the dev repo
PYPROJECT="$SUBDIR/pyproject.toml"

die() { printf 'publish: %s\n' "$*" >&2; exit 1; }

# ---- args ----------------------------------------------------------------
VER=""; DRYRUN=0; ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRYRUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -*)        die "unknown flag: $a" ;;
    *)         [ -z "$VER" ] || die "version given twice"; VER="$a" ;;
  esac
done
[ -n "$VER" ] || die "usage: ./publish.sh <version> [--dry-run] [--yes]"
printf '%s' "$VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "version must be semver like 0.2.1 (got '$VER')"
TAG="v$VER"

# ---- must run from the dev repo root, tree must be clean -----------------
cd "$(git rev-parse --show-toplevel)" || die "not in a git repo"
git remote get-url "$DEV_REMOTE"  >/dev/null 2>&1 || die "no '$DEV_REMOTE' remote (expected speccraft-dev)"
git remote get-url "$PKG_REMOTE"  >/dev/null 2>&1 || die "no '$PKG_REMOTE' remote (expected speccraft package repo)"
[ -f "$PYPROJECT" ] || die "$PYPROJECT not found — run from the dev repo root"
git diff --quiet && git diff --cached --quiet \
  || die "working tree is dirty — commit your feature work first, then publish"

# ---- refuse to republish an existing version ----------------------------
git fetch -q "$PKG_REMOTE" || die "could not fetch $PKG_REMOTE"
if git ls-remote --tags "$PKG_REMOTE" "refs/tags/$TAG" | grep -q "$TAG"; then
  die "$TAG already exists on $PKG_REMOTE — PyPI versions are permanent; bump the number"
fi

CUR=$(sed -nE 's/^version = "([^"]*)".*/\1/p' "$PYPROJECT" | head -1)
echo "publish: $CUR -> $VER   (dev=$DEV_REMOTE  pkg=$PKG_REMOTE  dry-run=$DRYRUN)"

# ---- 1. bump version in the dev repo (skip if already set) ---------------
BUMPED=0
if [ "$CUR" != "$VER" ]; then
  tmp=$(mktemp)
  sed -E 's/^version = "[^"]*"/version = "'"$VER"'"/' "$PYPROJECT" > "$tmp" && mv "$tmp" "$PYPROJECT"
  grep -q "version = \"$VER\"" "$PYPROJECT" || die "version bump failed"
  git add "$PYPROJECT"
  git commit -qm "chore(release): speccraft-cli $VER"
  BUMPED=1
  echo "publish: bumped + committed $VER in dev repo"
else
  echo "publish: $PYPROJECT already at $VER — no bump commit"
fi

# ---- 2. build the release snapshot on the package repo tip ---------------
WT=$(mktemp -d)
cleanup() { git worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"; }
trap cleanup EXIT
git worktree add -q --detach "$WT" "$PKG_REMOTE/main"

# replace the package tree entirely with the current kb-forge/ tree
( cd "$WT" && git rm -rqf . >/dev/null 2>&1 || true )
git archive HEAD:"$SUBDIR" | tar -x -C "$WT"
( cd "$WT" && git add -A )

if git -C "$WT" diff --cached --quiet; then
  die "no differences to publish — package repo already matches kb-forge/ at $VER"
fi

echo "publish: snapshot staged; changed files:"
git -C "$WT" diff --cached --name-status | sed 's/^/  /' | head -40

# ---- 3. confirm (this next step publishes to PyPI, irreversibly) ---------
if [ "$DRYRUN" -eq 1 ]; then
  echo "publish: --dry-run OK — pushed and tagged NOTHING."
  [ "$BUMPED" -eq 1 ] && echo "publish: note: a local dev bump commit for $VER was made (not pushed). Undo with: git reset --hard HEAD~1"
  exit 0
fi
if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'publish: push snapshot to %s/main and tag %s (triggers PyPI publish)? [y/N] ' "$PKG_REMOTE" "$TAG"
  read -r ans </dev/tty
  case "$ans" in y|Y|yes|YES) ;; *) die "aborted by user (dev repo bump is committed locally; not pushed)";; esac
fi

# ---- 4. commit + push package repo, then tag ----------------------------
git -C "$WT" commit -qm "release speccraft-cli $VER"
git -C "$WT" push "$PKG_REMOTE" HEAD:main
git -C "$WT" tag -a "$TAG" -m "speccraft-cli $VER"
git -C "$WT" push "$PKG_REMOTE" "$TAG"
echo "publish: pushed release + $TAG to $PKG_REMOTE (PyPI publish workflow triggered)"

# ---- 5. push the dev repo bump so it's backed up ------------------------
git push -q "$DEV_REMOTE" HEAD:main && echo "publish: dev repo pushed to $DEV_REMOTE"

echo "publish: done. Verify: https://github.com/swshukla/speccraft/actions  and  https://pypi.org/project/speccraft-cli/$VER/"
