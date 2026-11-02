#!/bin/bash
# Builds a Docket release for Apple silicon, packages it as dist/Docket-<version>.dmg with a signed
# Sparkle update feed (dist/appcast.xml), and optionally creates a draft GitHub Release with both attached.
#
# Usage:
#   tools/release.sh                Developer ID signed and notarized DMG (the real release build)
#   tools/release.sh --adhoc        Ad hoc signed, not notarized, no update feed: a local dry run only
#   tools/release.sh --publish      As the first form, then create a draft GitHub Release v<version>
#   tools/release.sh --test-update  Two Developer ID signed test builds for trying an update locally
#                                   (docs/releasing.md, "Testing an update")
#
# The version comes from MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml.
# Signing and notarization read these from the environment, never from the repository:
#   DOCKET_SIGN_IDENTITY      codesign identity (default "Developer ID Application")
#   DOCKET_NOTARY_PROFILE     notarytool keychain profile (default "docket-notary"); create it with
#                             xcrun notarytool store-credentials docket-notary
#   DOCKET_SPARKLE_ACCOUNT    Keychain account of the EdDSA update signing key (default "docket")
#   DOCKET_BUNDLE_ID_PREFIX   bundle ID prefix for the release (default io.github.docket)
#   DOCKET_RELEASE_REPO       GitHub owner/repo that hosts releases (default: the origin remote)
set -euo pipefail
cd "$(dirname "$0")/.."

mode=release
publish=false
for arg in "$@"; do
  case "$arg" in
    --adhoc) mode=adhoc ;;
    --test-update) mode=test ;;
    --publish) publish=true ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
if [ "$mode" != release ] && $publish; then
  echo "--publish needs a notarized build; it cannot be combined with --$mode." >&2
  exit 2
fi

identity="${DOCKET_SIGN_IDENTITY:-Developer ID Application}"
notary_profile="${DOCKET_NOTARY_PROFILE:-docket-notary}"
sparkle_account="${DOCKET_SPARKLE_ACCOUNT:-docket}"
bundle_prefix="${DOCKET_BUNDLE_ID_PREFIX:-io.github.docket}"
repo="${DOCKET_RELEASE_REPO:-$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Cannot tell the GitHub repository; set DOCKET_RELEASE_REPO=owner/repo." >&2; exit 1; }
derived=.build/Dist
sparkle_bin="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"

if $publish; then
  [ -z "$(git status --porcelain)" ] || { echo "Commit or discard local changes before publishing." >&2; exit 1; }
  command -v gh >/dev/null || { echo "Publishing needs the GitHub CLI (gh)." >&2; exit 1; }
fi

if [ "$mode" = adhoc ]; then
  identity=-
  sign_settings=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
else
  security find-identity -v -p codesigning | grep -q "\"$identity" ||
    { echo "No codesigning identity matching \"$identity\" in the keychain. Use --adhoc for a dry run." >&2; exit 1; }
  if [ "$mode" = release ]; then
    # Fail now rather than after the build if the notary profile is missing.
    xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null ||
      { echo "Notary profile \"$notary_profile\" not found. See docs/releasing.md." >&2; exit 1; }
  fi
  # Xcode otherwise adds the debugging entitlement get-task-allow, which notarization rejects.
  sign_settings=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" "OTHER_CODE_SIGN_FLAGS=--timestamp"
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi

sign() {
  if [ "$identity" = - ]; then
    codesign --force --sign - --options runtime "$@"
  else
    codesign --force --sign "$identity" --options runtime --timestamp "$@"
  fi
}

# Builds Docket.app into $derived and prints its path. Arguments are extra build settings.
# Settings on the command line win over Config/Local.xcconfig, so a personal development setup
# never leaks into a release build.
build_app() {
  rm -rf "$derived/Build"
  xcodebuild -project Docket.xcodeproj -scheme Docket -configuration Release -destination "generic/platform=macOS" \
    -derivedDataPath "$derived" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO "${sign_settings[@]}" "$@" \
    build | grep -E '(error|warning):|BUILD' | grep -v -i -E 'appintents|CoreSimulator' >&2 || true

  local app="$derived/Build/Products/Release/Docket.app"
  [ -d "$app" ] || { echo "Build failed: $app not found" >&2; exit 1; }

  # Sparkle's helpers ship with their own signature; notarization needs ours, with the hardened
  # runtime and a timestamp. Inside out: helpers, then the framework, then the app.
  local fw="$app/Contents/Frameworks/Sparkle.framework"
  sign "$fw/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$fw/Versions/B/XPCServices/Downloader.xpc"
  sign "$fw/Versions/B/Autoupdate"
  sign "$fw/Versions/B/Updater.app"
  sign "$fw"
  sign --preserve-metadata=entitlements,requirements,flags "$app"

  codesign --verify --strict --deep "$app"
  if [ "$identity" != - ] && codesign -d --entitlements - "$app" 2>/dev/null | grep -q get-task-allow; then
    echo "The app has the get-task-allow entitlement, which notarization rejects." >&2
    exit 1
  fi
  [ "$(lipo -archs "$app/Contents/MacOS/Docket")" = arm64 ] || { echo "Expected an arm64-only binary." >&2; exit 1; }
  echo "$app"
}

plist_value() { /usr/libexec/PlistBuddy -c "Print $2" "$1/Contents/Info.plist"; }

# Packages an app into a DMG with an Applications shortcut.
make_dmg() {
  local app="$1" dmg="$2" volume="$3" staging
  staging="$(mktemp -d)"
  ditto "$app" "$staging/Docket.app"
  ln -s /Applications "$staging/Applications"
  rm -f "$dmg"
  # hdiutil warns that it is deprecated on recent macOS; it still works and runs on older build Macs too.
  hdiutil create -volname "$volume" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null 2> >(grep -v -i deprecated >&2)
  rm -rf "$staging"
}

# Writes a one-item Sparkle feed for a DMG, signed with the EdDSA key in the Keychain.
write_appcast() {
  local dmg="$1" url="$2" version="$3" build="$4" notes="$5" out="$6" signature
  [ -x "$sparkle_bin/sign_update" ] || { echo "Sparkle's sign_update not found in $sparkle_bin" >&2; exit 1; }
  signature="$("$sparkle_bin/sign_update" --account "$sparkle_account" "$dmg")"
  [[ "$signature" =~ ^sparkle:edSignature=\"[A-Za-z0-9+/=]+\"\ length=\"[0-9]+\"$ ]] ||
    { echo "sign_update failed. Is the update signing key in the Keychain? See docs/releasing.md." >&2; exit 1; }
  cat > "$out" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Docket</title>
    <item>
      <title>Docket $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$notes</sparkle:fullReleaseNotesLink>
      <enclosure url="$url" $signature type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
}

xcodegen generate >/dev/null
mkdir -p dist

if [ "$mode" = test ]; then
  out=dist/test-update
  port=8765
  feed="http://127.0.0.1:$port/appcast.xml"
  test_prefix="$bundle_prefix.test"
  rm -rf "$out" && mkdir -p "$out"

  # The newer copy gets the project's version with the next build number; the older one is 0.0.1, build 1.
  version="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)"
  build="$(( $(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"$/\1/p' project.yml) + 1 ))"
  new_app="$(build_app "BUNDLE_ID_PREFIX=$test_prefix" "DOCKET_UPDATE_FEED_URL=$feed" "CURRENT_PROJECT_VERSION=$build")"
  make_dmg "$new_app" "$out/Docket-test.dmg" "Docket $version"
  write_appcast "$out/Docket-test.dmg" "http://127.0.0.1:$port/Docket-test.dmg" "$version" "$build" \
    "https://github.com/$repo/releases" "$out/appcast.xml"

  old_app="$(build_app "BUNDLE_ID_PREFIX=$test_prefix" "DOCKET_UPDATE_FEED_URL=$feed" MARKETING_VERSION=0.0.1 CURRENT_PROJECT_VERSION=1)"
  ditto "$old_app" "$out/Docket.app"
  cat <<EOF
Test update ready in $out (bundle ID $test_prefix.Docket).
  1. Serve the feed:   python3 -m http.server $port --bind 127.0.0.1 --directory $out
  2. Open the old app: open $out/Docket.app
  3. Choose Docket > Check for Updates… and install. Docket $version (build $build) should relaunch.
EOF
  exit 0
fi

if [ "$mode" = release ]; then
  app="$(build_app "BUNDLE_ID_PREFIX=$bundle_prefix" "DOCKET_UPDATE_FEED_URL=https://github.com/$repo/releases/latest/download/appcast.xml")"
else
  app="$(build_app "BUNDLE_ID_PREFIX=$bundle_prefix")"
fi
version="$(plist_value "$app" CFBundleShortVersionString)"
build="$(plist_value "$app" CFBundleVersion)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected version \"$version\" in the app's Info.plist" >&2; exit 1; }
[[ "$build" =~ ^[0-9]+$ ]] || { echo "Unexpected build number \"$build\" in the app's Info.plist" >&2; exit 1; }

# notarytool exits 0 even when Apple rejects a submission, so check the status it reports.
notarize() {
  local result id status
  result="$(xcrun notarytool submit "$1" --keychain-profile "$notary_profile" --wait --timeout 30m --output-format json)"
  id="$(/usr/bin/plutil -extract id raw -o - - <<<"$result")"
  status="$(/usr/bin/plutil -extract status raw -o - - <<<"$result")"
  echo "Notarization of $(basename "$1"): $status"
  if [ "$status" != Accepted ]; then
    xcrun notarytool log "$id" --keychain-profile "$notary_profile" >&2 || true
    exit 1
  fi
}

if [ "$mode" = release ]; then
  # Installed copies only accept an update with a higher build number, so catch a missed bump now.
  published="$(curl -fsL "https://github.com/$repo/releases/latest/download/appcast.xml" 2>/dev/null |
    sed -n 's#.*<sparkle:version>\([0-9]*\)</sparkle:version>.*#\1#p' | head -1 || true)"
  if [ -n "$published" ] && [ "$build" -le "$published" ]; then
    echo "Build $build is not higher than the published build $published. Bump CURRENT_PROJECT_VERSION in project.yml." >&2
    exit 1
  fi

  # Notarize and staple the app itself so it opens without a network check once copied out of the DMG.
  zip="$derived/Docket-notarize.zip"
  ditto -c -k --keepParent "$app" "$zip"
  notarize "$zip"
  xcrun stapler staple "$app"
  rm -f "$zip"
fi

suffix=""
[ "$mode" = adhoc ] && suffix="-adhoc"
dmg="dist/Docket-$version$suffix.dmg"
make_dmg "$app" "$dmg" "Docket $version"

if [ "$mode" = release ]; then
  codesign --sign "$identity" --timestamp "$dmg"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
  # Sign the final, stapled DMG: Sparkle checks the bytes it downloads.
  write_appcast "$dmg" "https://github.com/$repo/releases/download/v$version/$(basename "$dmg")" "$version" "$build" \
    "https://github.com/$repo/releases/tag/v$version" dist/appcast.xml
fi

(cd dist && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
echo "Built $dmg (version $version, build $build, $mode)"

if $publish; then
  tag="v$version"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    echo "$tag already exists. Bump MARKETING_VERSION in project.yml." >&2
    exit 1
  fi
  # A draft creates no tag until it is published, and installed copies only see published releases,
  # so nothing is public or offered as an update until you choose to publish it.
  gh release create "$tag" "$dmg" "$dmg.sha256" dist/appcast.xml --repo "$repo" --draft --target "$(git rev-parse HEAD)" \
    --title "Docket $version" --generate-notes
  echo "Created draft release $tag. Review it on GitHub, then publish it there or with: gh release edit $tag --repo $repo --draft=false"
fi
