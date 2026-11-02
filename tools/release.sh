#!/bin/bash
# Builds a Docket release for Apple silicon, packages it as dist/Docket-<version>.dmg, and
# optionally creates a draft GitHub Release with the DMG attached.
#
# Usage:
#   tools/release.sh              Developer ID signed and notarized DMG (the real release build)
#   tools/release.sh --adhoc      Ad hoc signed, not notarized: a local dry run only
#   tools/release.sh --publish    As the first form, then create a draft GitHub Release v<version>
#
# The version comes from MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml.
# Signing and notarization read these from the environment, never from the repository:
#   DOCKET_SIGN_IDENTITY      codesign identity (default "Developer ID Application")
#   DOCKET_NOTARY_PROFILE     notarytool keychain profile (default "docket-notary"); create it with
#                             xcrun notarytool store-credentials docket-notary
#   DOCKET_BUNDLE_ID_PREFIX   bundle ID prefix for the release (default io.github.docket)
set -euo pipefail
cd "$(dirname "$0")/.."

mode=release
publish=false
for arg in "$@"; do
  case "$arg" in
    --adhoc) mode=adhoc ;;
    --publish) publish=true ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
if [ "$mode" = adhoc ] && $publish; then
  echo "--publish needs a notarized build; it cannot be combined with --adhoc." >&2
  exit 2
fi

identity="${DOCKET_SIGN_IDENTITY:-Developer ID Application}"
notary_profile="${DOCKET_NOTARY_PROFILE:-docket-notary}"
bundle_prefix="${DOCKET_BUNDLE_ID_PREFIX:-io.github.docket}"

if $publish; then
  [ -z "$(git status --porcelain)" ] || { echo "Commit or discard local changes before publishing." >&2; exit 1; }
  command -v gh >/dev/null || { echo "Publishing needs the GitHub CLI (gh)." >&2; exit 1; }
fi

if [ "$mode" = release ]; then
  security find-identity -v -p codesigning | grep -q "\"$identity" ||
    { echo "No codesigning identity matching \"$identity\" in the keychain. Use --adhoc for a dry run." >&2; exit 1; }
  # Fail now rather than after the build if the notary profile is missing.
  xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null ||
    { echo "Notary profile \"$notary_profile\" not found. See docs/releasing.md." >&2; exit 1; }
  sign_settings=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" "OTHER_CODE_SIGN_FLAGS=--timestamp")
else
  sign_settings=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

# Settings on the command line win over Config/Local.xcconfig, so a personal development setup
# never leaks into a release build.
xcodegen generate >/dev/null
rm -rf .build/Dist
xcodebuild -project Docket.xcodeproj -scheme Docket -configuration Release -destination "generic/platform=macOS" \
  -derivedDataPath .build/Dist ARCHS=arm64 ONLY_ACTIVE_ARCH=NO "BUNDLE_ID_PREFIX=$bundle_prefix" "${sign_settings[@]}" \
  build | grep -E '(error|warning):|BUILD' | grep -v -i appintents || true

app=".build/Dist/Build/Products/Release/Docket.app"
[ -d "$app" ] || { echo "Build failed: $app not found" >&2; exit 1; }
codesign --verify --strict --deep "$app"
[ "$(lipo -archs "$app/Contents/MacOS/Docket")" = arm64 ] || { echo "Expected an arm64-only binary." >&2; exit 1; }

plist="$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected version \"$version\" in $plist" >&2; exit 1; }

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$notary_profile" --wait --timeout 30m
}

if [ "$mode" = release ]; then
  # Notarize and staple the app itself so it opens without a network check once copied out of the DMG.
  zip=".build/Dist/Docket-notarize.zip"
  ditto -c -k --keepParent "$app" "$zip"
  notarize "$zip"
  xcrun stapler staple "$app"
  rm -f "$zip"
fi

mkdir -p dist
suffix=""
[ "$mode" = adhoc ] && suffix="-adhoc"
dmg="dist/Docket-$version$suffix.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Docket.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "Docket $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null

if [ "$mode" = release ]; then
  codesign --sign "$identity" --timestamp "$dmg"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi

(cd dist && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
echo "Built $dmg (version $version, build $build, $mode)"

if $publish; then
  tag="v$version"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || gh release view "$tag" >/dev/null 2>&1; then
    echo "$tag already exists. Bump MARKETING_VERSION in project.yml." >&2
    exit 1
  fi
  # A draft creates no tag until it is published, so nothing is public until you choose to publish it.
  gh release create "$tag" "$dmg" "$dmg.sha256" --draft --target "$(git rev-parse HEAD)" \
    --title "Docket $version" --generate-notes
  echo "Created draft release $tag. Review it on GitHub, then publish it there or with: gh release edit $tag --draft=false"
fi
