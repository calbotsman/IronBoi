#!/usr/bin/env bash
# Static checks that run before the (slow) iOS build in CI.
#
# GoogleService-Info.plist is gitignored and written by a pre-build phase, so
# it only gets bundled if the project lists it explicitly. When the listing
# went missing, Firebase aborted in `FIRApp configure` at launch and CI stayed
# green (F40, fixed by #54). This fails fast if either the XcodeGen spec or
# the committed project loses it again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$ROOT/ios/IronBoi/project.yml"
PBX="$ROOT/ios/IronBoi/IronBoi.xcodeproj/project.pbxproj"
fail=0

# project.yml: the IronBoi target must list the plist as its own source,
# in the resources phase.
if ! python3 - "$SPEC" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
# The entry: "- path: IronBoi/GoogleService-Info.plist" followed by its
# indented keys; buildPhase must be resources.
m = re.search(r"^(\s*)- path: IronBoi/GoogleService-Info\.plist\s*\n((?:\1  .*\n)*)", text, re.M)
sys.exit(0 if m and re.search(r"buildPhase:\s*resources", m.group(2)) else 1)
PY
then
  echo "::error file=ios/IronBoi/project.yml::project.yml no longer lists IronBoi/GoogleService-Info.plist with buildPhase: resources. Without it the app crashes at launch in FIRApp configure (F40, see #54)."
  fail=1
fi

# The committed project (CI builds it as-is, no xcodegen step) must copy it.
if ! grep -q '/\* GoogleService-Info.plist in Resources \*/' "$PBX"; then
  echo "::error file=ios/IronBoi/IronBoi.xcodeproj/project.pbxproj::project.pbxproj does not copy GoogleService-Info.plist in Resources. Regenerate with \`xcodegen generate\` in ios/IronBoi (F40, see #54)."
  fail=1
fi

# The pre-build phase copies the Debug plist from here; it must be committed.
if [ ! -f "$ROOT/ios/IronBoi/IronBoi/Firebase/GoogleService-Info-Staging.plist" ]; then
  echo "::error::ios/IronBoi/IronBoi/Firebase/GoogleService-Info-Staging.plist is missing; Debug builds have no Firebase config."
  fail=1
fi

[ "$fail" = 0 ] && echo "preflight: GoogleService-Info.plist is listed in project.yml and project.pbxproj"
exit "$fail"
