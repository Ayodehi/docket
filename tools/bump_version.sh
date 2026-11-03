#!/bin/bash
# Sets the next release version in project.yml, counting from the latest published GitHub Release.
#
# Usage: tools/bump_version.sh --patch | --minor | --major
#
# MARKETING_VERSION becomes the latest release's version with one part increased (0.2.0 -> 0.2.1,
# 0.3.0, or 1.0.0). CURRENT_PROJECT_VERSION becomes one more than the higher of its current value
# and the published feed's build number, so installed copies offer the update.
# Prints "<version> <build>". Only edits project.yml; it does not commit.
#
#   DOCKET_RELEASE_REPO   GitHub owner/repo that hosts releases (default: the origin remote)
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  --patch|--minor|--major) part="${1#--}" ;;
  *) echo "Usage: tools/bump_version.sh --patch | --minor | --major" >&2; exit 2 ;;
esac

repo="${DOCKET_RELEASE_REPO:-$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Cannot tell the GitHub repository; set DOCKET_RELEASE_REPO=owner/repo." >&2; exit 1; }

current="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)"
build="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"$/\1/p' project.yml)"
[[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Cannot read MARKETING_VERSION from project.yml." >&2; exit 1; }
[[ "$build" =~ ^[0-9]+$ ]] || { echo "Cannot read CURRENT_PROJECT_VERSION from project.yml." >&2; exit 1; }

# The latest published release; drafts and prereleases are not "latest". With none yet, start from project.yml.
latest="$(gh release view --repo "$repo" --json tagName --jq .tagName 2>/dev/null || true)"
if [ -n "$latest" ]; then
  [[ "$latest" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected latest release tag \"$latest\"." >&2; exit 1; }
  if [ "${latest#v}" != "$current" ]; then
    echo "project.yml says $current but the latest release is $latest. Set MARKETING_VERSION to ${latest#v} or release $current as is." >&2
    exit 1
  fi
fi

IFS=. read -r major minor patch <<<"$current"
case "$part" in
  patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  major) major=$((major + 1)); minor=0; patch=0 ;;
esac
version="$major.$minor.$patch"

published="$(curl -fsL "https://github.com/$repo/releases/latest/download/appcast.xml" 2>/dev/null |
  sed -n 's#.*<sparkle:version>\([0-9]*\)</sparkle:version>.*#\1#p' | head -1 || true)"
[ -n "$published" ] && [ "$published" -gt "$build" ] && build="$published"
build=$((build + 1))

sed -i '' -E "s/^( *MARKETING_VERSION: )\"[^\"]*\"$/\1\"$version\"/; s/^( *CURRENT_PROJECT_VERSION: )\"[^\"]*\"$/\1\"$build\"/" project.yml
echo "$version $build"
