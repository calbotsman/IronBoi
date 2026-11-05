#!/bin/bash
# Compile and run ios/IronBoi/HostTests on the Mac: plain-Swift checks for
# code with no UI or device dependency (Watch messages, heart-rate zones,
# Bluetooth heart-rate parsing). No simulator needed; runs in CI's ios job.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/ios/IronBoi"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# Sources under test: the shared Watch/phone code, plus any phone file
# listed in HostTests/sources.txt (paths relative to ios/IronBoi).
EXTRA=()
if [ -f "$IOS/HostTests/sources.txt" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && EXTRA+=("$IOS/$line")
  done < "$IOS/HostTests/sources.txt"
fi
xcrun swiftc -O -o "$OUT/host-tests" "$IOS"/MYOShared/*.swift ${EXTRA[@]+"${EXTRA[@]}"} "$IOS"/HostTests/*.swift
"$OUT/host-tests"
