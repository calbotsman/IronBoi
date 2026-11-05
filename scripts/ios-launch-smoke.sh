#!/usr/bin/env bash
# Launch smoke test: install a simulator build of MYO, launch it, and fail if
# it is dead (or left a crash report) after a few seconds.
#
# Both launch crashes of 2026-11-05 died in App.init and passed a build-only
# CI: F40 (GoogleService-Info.plist not bundled, Firebase abort) and F42 (an
# HKHealthStore getter that doesn't exist at runtime, unrecognized selector).
#
# Usage: scripts/ios-launch-smoke.sh path/to/IronBoi.app [runtime-id]
#   runtime-id: e.g. com.apple.CoreSimulator.SimRuntime.iOS-26-0, or "oldest".
#   Defaults to the newest available iOS runtime of the selected Xcode
#   (DEVELOPER_DIR picks the Xcode).
# Env: SMOKE_SECONDS (default 10).
#
# The app runs with MYO_NO_MIC=1 (never opens the mic) and MYO_PREVIEW=1
# (DEBUG: skips sign-in into the no-backend preview session, so the launch
# path goes past the first screen without touching the backend).
set -euo pipefail

APP="${1:?usage: $0 path/to/IronBoi.app [runtime-id]}"
RUNTIME="${2:-}"
WAIT="${SMOKE_SECONDS:-10}"

[ -d "$APP" ] || { echo "::error::$APP not found"; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
EXE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")

# Newest available iOS runtime, and an iPhone it supports.
read -r RUNTIME DEVTYPE RUNTIME_NAME < <(xcrun simctl list runtimes available -j | python3 -c '
import json, sys
want = sys.argv[1]
rts = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
if want not in ("", "oldest"):
    rts = [r for r in rts if r["identifier"] == want]
if not rts:
    sys.exit("no matching iOS simulator runtime")
pick = min if want == "oldest" else max
rt = pick(rts, key=lambda r: tuple(int(x) for x in r["version"].split(".")))
phones = [d["identifier"] for d in rt["supportedDeviceTypes"] if d.get("productFamily") == "iPhone"]
print(rt["identifier"], phones[-1], rt["name"].replace(" ", "_"))
' "$RUNTIME")
[ -n "${DEVTYPE:-}" ] || { echo "::error::no usable iOS simulator runtime${RUNTIME:+ ($RUNTIME)}"; exit 1; }
echo "Runtime: $RUNTIME_NAME ($RUNTIME), device: $DEVTYPE"

UDID=$(xcrun simctl create "MYO smoke" "$DEVTYPE" "$RUNTIME")
LOG=$(mktemp -t myo-smoke-log)
STREAM_PID=""
cleanup() {
  [ -n "$STREAM_PID" ] && kill "$STREAM_PID" 2>/dev/null || true
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null

# Crash reports for simulator apps land on the host.
REPORTS="$HOME/Library/Logs/DiagnosticReports"
mkdir -p "$REPORTS"
MARK=$(mktemp -t myo-smoke-mark)

xcrun simctl install "$UDID" "$APP"
xcrun simctl spawn "$UDID" log stream --style compact --level debug \
  --predicate "process == \"$EXE\"" >"$LOG" 2>&1 &
STREAM_PID=$!
sleep 1

OUT=$(SIMCTL_CHILD_MYO_NO_MIC=1 SIMCTL_CHILD_MYO_PREVIEW=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID")
PID="${OUT##*: }"
echo "Launched $BUNDLE_ID (pid $PID); waiting ${WAIT}s"
sleep "$WAIT"

fail=0
if ! kill -0 "$PID" 2>/dev/null; then
  echo "::error::$EXE (pid $PID) died within ${WAIT}s of launch on $RUNTIME_NAME"
  fail=1
fi
NEW=$(find "$REPORTS" -newer "$MARK" -name "$EXE*" 2>/dev/null || true)
if [ -n "$NEW" ]; then
  echo "::error::$EXE left a crash report on $RUNTIME_NAME"
  fail=1
fi

if [ "$fail" = 1 ]; then
  for f in $NEW; do
    echo "----- $f"
    head -c 6000 "$f"
    echo
  done
  echo "----- last log lines"
  grep -E "Terminating|unrecognized selector|exception|FIRApp|fatal|error" "$LOG" | tail -40 || true
  tail -60 "$LOG"
  exit 1
fi
echo "OK: $EXE still running after ${WAIT}s on $RUNTIME_NAME, no crash report"
