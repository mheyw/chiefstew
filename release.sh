#!/usr/bin/env bash
# Publish a release to the team:  ./release.sh 0.3.0
#
# Runs the tests, sets VERSION, commits, tags v0.3.0 (its message lists the changes since the
# last release, which teammates see after updating) and pushes main and the tag. Teammates'
# copies on the Releases channel install it automatically within a few hours.

set -euo pipefail
cd "$(dirname "$0")"
die() { echo "✗ $*" >&2; exit 1; }

V="${1:-}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: ./release.sh <version>, e.g. ./release.sh 0.3.0"
[ "$(git branch --show-current)" = main ] || die "release from main (you're on $(git branch --show-current))"
[ -z "$(git status --porcelain)" ] || die "commit or stash your changes first"
git fetch --quiet --tags origin
git rev-parse --verify --quiet "refs/tags/v$V" >/dev/null && die "v$V already exists"
[ "$(git rev-list --count HEAD..origin/main)" = 0 ] || die "main is behind origin/main: pull first"

echo "  running the tests…"
swift test >/dev/null 2>&1 || die "tests failed: run 'swift test' to see why"

PREV="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
NOTES="$(git log --no-merges --format='- %s' ${PREV:+$PREV..}HEAD | grep -v '^- Release v' || true)"
echo "$V" > VERSION
git diff --quiet VERSION || git commit -q -m "Release v$V" VERSION
git tag -a "v$V" -m "Chief Stew v$V" -m "${NOTES:-- Maintenance}"
git push -q origin main "v$V"
echo "✓ released v$V${PREV:+ (since $PREV)}"
echo "$NOTES"
