#!/bin/bash
# Publishes a GitHub release that installed copies of iShot pick up as an update.
#   1. bump VERSION in scripts/build-app.sh and commit
#   2. scripts/release.sh ["release notes"]
# Builds and signs the app (with "iShot Local Signing": the updater only accepts apps signed with
# the same certificate), zips it as iShot.zip, tags vVERSION, pushes and creates the release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/build-app.sh)"
TAG="v$VERSION"
NOTES="${1:-iShot $VERSION}"

[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first." >&2; exit 1; }
security find-identity -v -p codesigning | grep -q '"iShot Local Signing"' \
    || { echo "Missing \"iShot Local Signing\": run scripts/create-signing-cert.sh" >&2; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG already exists: bump VERSION in scripts/build-app.sh." >&2
    exit 1
fi

ISHOT_SIGN_IDENTITY="iShot Local Signing" scripts/build-app.sh
ZIP="$ROOT/build/iShot.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/build/iShot.app" "$ZIP"

git rev-parse "$TAG" >/dev/null 2>&1 || git tag -a "$TAG" -m "iShot $VERSION"
git push origin HEAD "$TAG"
gh release create "$TAG" "$ZIP" --title "iShot $VERSION" --notes "$NOTES"
echo "Released $TAG"
