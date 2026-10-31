#!/bin/bash
# Builds Docket in Release and installs it as /Applications/Docket.app, replacing any running copy.
# Usage: tools/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild -project Docket.xcodeproj -scheme Docket -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .build/Release build | grep -E '(error|warning):|BUILD' | grep -v -i appintents || true

built=".build/Release/Build/Products/Release/Docket.app"
[ -d "$built" ] || { echo "Build failed: $built not found" >&2; exit 1; }
codesign --verify --strict "$built"

# Quit any running copy (development or installed), then replace the installed one.
pkill -x Docket 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x Docket >/dev/null || break; sleep 1; done

staging="$(mktemp -d)"
ditto "$built" "$staging/Docket.app"
rm -rf /Applications/Docket.app
mv "$staging/Docket.app" /Applications/Docket.app
rmdir "$staging"

open /Applications/Docket.app
echo "Installed /Applications/Docket.app ($(defaults read /Applications/Docket.app/Contents/Info.plist CFBundleShortVersionString))"
