#!/bin/bash
# Attaches the built zip for the current build to a GitHub release on the private repo.
#   scripts/publish.sh   (after scripts/release.sh and pushing the build-<N> tag)
# Never pushes: the tag must already be on GitHub, so publishing is always deliberate.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${OHMAI_RELEASE_REPO:-nicwestvold/ohmai}"

setting() {
  xcodebuild -project ohmai.xcodeproj -scheme ohmai -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' -v k="$1" '$1 ~ "^ *"k"$" {print $2; exit}'
}
VERSION=$(setting MARKETING_VERSION)
BUILD=$(setting CURRENT_PROJECT_VERSION)
NAME="ohmai-${VERSION}-${BUILD}"
ZIP="build/release/${NAME}.zip"
TAG="build-${BUILD}"

[[ -f "$ZIP" ]] || { echo "error: $ZIP not found; run make release first" >&2; exit 1; }
git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1 \
  || { echo "error: tag ${TAG} isn't on origin. Tag the released commit and push it first:" >&2
       echo "  git tag ${TAG} && git push origin ${TAG}" >&2; exit 1; }

gh release create "$TAG" "$ZIP" "${ZIP}.sha256" --repo "$REPO" --verify-tag \
  --title "ohmai ${VERSION} (${BUILD})" \
  --notes "Signed and notarized. Unzip and move ohmai.app to /Applications. SHA-256 in the attached .sha256 file."
