#!/bin/bash
# Pre-submission check for a PUBLIC App Store release.
#
# Why this exists as a separate script rather than a build phase: an Xcode
# build cannot tell a TestFlight archive from an App Store archive. Both use
# the Release configuration and produce the identical binary — the
# destination is chosen afterwards, in Organizer. So the only honest place
# for an App-Store-specific gate is a step you run on purpose.
#
# The build-phase check in ios/IronBoi/project.yml is the backstop (it hard-
# fails a 1.x build carrying a placeholder prod plist). This is the real
# check: it verifies the prod project exists AND has the backend deployed,
# which no build phase can know.
#
# Usage:
#   scripts/preflight-appstore.sh                 # checks ironboi-prod
#   scripts/preflight-appstore.sh my-project-id   # checks another project
#
# Exit 0 = safe to submit. Exit 1 = do not submit; read the output.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_YML="$REPO_ROOT/ios/IronBoi/project.yml"
PROD_PLIST="$REPO_ROOT/ios/IronBoi/IronBoi/Firebase/GoogleService-Info-Prod.plist"
PROD_PROJECT="${1:-ironboi-prod}"

FAILURES=0
WARNINGS=0

pass() { printf "  \033[32mok\033[0m    %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAILURES=$((FAILURES + 1)); }
warn() { printf "  \033[33mwarn\033[0m  %s\n" "$1"; WARNINGS=$((WARNINGS + 1)); }

echo "Preflight for public App Store submission (project: $PROD_PROJECT)"
echo

# --- 1. The prod Firebase config must be real -------------------------------
echo "Firebase config"
if [ ! -f "$PROD_PLIST" ]; then
  fail "GoogleService-Info-Prod.plist is missing"
elif grep -q "REPLACE_WITH_PROD" "$PROD_PLIST"; then
  fail "GoogleService-Info-Prod.plist still has REPLACE_WITH_PROD_* placeholders — the build would silently ship STAGING credentials to real users"
else
  pass "GoogleService-Info-Prod.plist has no placeholders"

  PLIST_PROJECT="$(/usr/libexec/PlistBuddy -c "Print :PROJECT_ID" "$PROD_PLIST" 2>/dev/null || echo "")"
  if [ "$PLIST_PROJECT" = "$PROD_PROJECT" ]; then
    pass "plist PROJECT_ID is $PLIST_PROJECT"
  else
    fail "plist PROJECT_ID is '${PLIST_PROJECT:-unreadable}', expected '$PROD_PROJECT'"
  fi
fi

# --- 2. Version sanity ------------------------------------------------------
echo
echo "Version"
MARKETING_VERSION="$(grep -E "^\s*MARKETING_VERSION:" "$PROJECT_YML" | head -1 | sed 's/.*: *//' | tr -d '"' | tr -d "'")"
case "${MARKETING_VERSION:-0}" in
  0|0.*)
    warn "MARKETING_VERSION is $MARKETING_VERSION — a 0.x version on the public App Store is unusual; bump to 1.0.0 if this is a real launch"
    ;;
  *)
    pass "MARKETING_VERSION is $MARKETING_VERSION"
    ;;
esac

# --- 3. The prod project must exist and have the backend ---------------------
# A perfect plist pointing at an empty project is the same outage as no plist.
echo
echo "Backend on $PROD_PROJECT"
if ! command -v npx >/dev/null 2>&1; then
  warn "npx unavailable — skipping backend checks; verify manually"
else
  PROJECTS="$(npx --yes firebase-tools projects:list 2>/dev/null)"
  if [ -z "$PROJECTS" ]; then
    warn "could not list Firebase projects (not logged in?) — run 'npx firebase-tools login' and re-run"
  elif ! echo "$PROJECTS" | grep -q "$PROD_PROJECT"; then
    fail "Firebase project '$PROD_PROJECT' does not exist — create it before submitting"
  else
    pass "Firebase project '$PROD_PROJECT' exists"

    FUNCS="$(npx --yes firebase-tools functions:list --project "$PROD_PROJECT" 2>/dev/null)"
    if [ -z "$FUNCS" ]; then
      fail "no Cloud Functions found on '$PROD_PROJECT' — deploy the backend before submitting"
    else
      MISSING=""
      # Spot-check the endpoints the app cannot function without, rather than
      # every name — a partial deploy is the realistic failure, not an empty one.
      for fn in sendCoachMessage startWorkoutSessionCallable finishWorkoutSessionCallable \
                getExerciseSwapOptionsCallable swapExerciseCallable applyExerciseBaselinesCallable; do
        echo "$FUNCS" | grep -q "$fn" || MISSING="$MISSING $fn"
      done
      if [ -n "$MISSING" ]; then
        fail "functions missing on '$PROD_PROJECT':$MISSING"
      else
        pass "core callables are deployed"
      fi
    fi
  fi
fi

# --- 4. Firestore rules must not be the default open/closed stub -------------
echo
echo "Firestore rules"
RULES="$REPO_ROOT/firestore.rules"
if [ ! -f "$RULES" ]; then
  fail "firestore.rules is missing"
else
  if grep -qE "allow read, write: if true" "$RULES"; then
    fail "firestore.rules contains an 'if true' allow — this would expose every user's data"
  else
    pass "no blanket-allow rule in firestore.rules"
  fi
  warn "rules are NOT auto-verified against $PROD_PROJECT here — deploy them with: npx firebase-tools deploy --only firestore:rules --project $PROD_PROJECT"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  printf "\033[31m%s check(s) failed\033[0m — do NOT submit to the App Store.\n" "$FAILURES"
  exit 1
fi
if [ "$WARNINGS" -gt 0 ]; then
  printf "\033[33mPassed with %s warning(s)\033[0m — read them before submitting.\n" "$WARNINGS"
  exit 0
fi
printf "\033[32mAll checks passed.\033[0m Safe to submit.\n"
