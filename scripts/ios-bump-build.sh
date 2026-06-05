#!/bin/bash
# Bump CURRENT_PROJECT_VERSION in project.yml, then re-run xcodegen.
#
# Why: App Store Connect rejects duplicate build numbers per marketing
# version. Every TestFlight or App Store upload needs a unique
# CURRENT_PROJECT_VERSION. Doing this by hand is error-prone — this
# script does the increment in one place.
#
# Usage:
#   scripts/ios-bump-build.sh           # bumps by 1
#   scripts/ios-bump-build.sh 5         # sets to exactly 5
#
# Run from anywhere in the repo. Idempotent on dirty trees — only
# touches project.yml + the regenerated .xcodeproj.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_YML="$REPO_ROOT/ios/IronBoi/project.yml"

if [ ! -f "$PROJECT_YML" ]; then
  echo "error: $PROJECT_YML not found"
  exit 1
fi

CURRENT=$(grep -E "^[[:space:]]*CURRENT_PROJECT_VERSION:" "$PROJECT_YML" | head -1 | awk '{print $2}')
if [ -z "$CURRENT" ]; then
  echo "error: couldn't find CURRENT_PROJECT_VERSION in $PROJECT_YML"
  exit 1
fi

if [ "${1:-}" != "" ]; then
  NEXT="$1"
else
  NEXT=$((CURRENT + 1))
fi

if [ "$NEXT" = "$CURRENT" ]; then
  echo "CURRENT_PROJECT_VERSION already $CURRENT — nothing to do."
  exit 0
fi

# In-place replace, BSD-sed compatible (macOS default).
# `\s` is not portable to BSD sed — use [[:space:]] for the indent.
sed -i "" "s/^\([[:space:]]*CURRENT_PROJECT_VERSION:\) $CURRENT$/\1 $NEXT/" "$PROJECT_YML"

echo "Bumped CURRENT_PROJECT_VERSION: $CURRENT → $NEXT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "warning: xcodegen not in PATH — skipping project regeneration. Install with: brew install xcodegen"
  exit 0
fi

cd "$REPO_ROOT/ios/IronBoi"
xcodegen >/dev/null
echo "Regenerated IronBoi.xcodeproj"
