#!/bin/bash
# Builds a signed, notarized, stapled ohmai release zip.
#
#   scripts/release.sh              # full release
#   scripts/release.sh --no-notarize  # sign and verify only (no upload to Apple)
#
# Needs: Developer ID Application certificate in the login keychain, and notarytool
# credentials stored once with:
#   xcrun notarytool store-credentials "ohmai-notary" --apple-id … --team-id …
# Override the profile name with NOTARY_PROFILE. Team ID and versions come from
# Config/*.xcconfig (and Config/Local.xcconfig); nothing is hard-coded here.

set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0
PROFILE="${NOTARY_PROFILE:-ohmai-notary}"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || fail "working tree has uncommitted changes; commit first so the build matches a commit"

step "Generating project"
xcodegen generate --quiet

setting() {
  xcodebuild -project ohmai.xcodeproj -scheme ohmai -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' -v k="$1" '$1 ~ "^ *"k"$" {print $2; exit}'
}
TEAM=$(setting OHMAI_TEAM_ID)
VERSION=$(setting MARKETING_VERSION)
BUILD=$(setting CURRENT_PROJECT_VERSION)
[[ -n "$TEAM" && -n "$VERSION" && -n "$BUILD" ]] || fail "couldn't read team/version from build settings"

NAME="ohmai-${VERSION}-${BUILD}"
OUT="build/release/${NAME}"
rm -rf "$OUT"
mkdir -p "$OUT"
echo "ohmai ${VERSION} (${BUILD}), team ${TEAM}, commit $(git rev-parse --short HEAD)"

# Sparkle compares CFBundleVersion: never reuse or decrease it.
if git tag --list "build-*" | sed 's/build-//' | awk -v b="$BUILD" '$1 >= b {found=1} END {exit !found}'; then
  fail "build number ${BUILD} isn't higher than an existing build-* tag; bump CURRENT_PROJECT_VERSION in Config/Shared.xcconfig"
fi

step "Archiving (Release)"
xcodebuild -project ohmai.xcodeproj -scheme ohmai -configuration Release \
  -archivePath "$OUT/ohmai.xcarchive" -derivedDataPath build/release-derived \
  archive -quiet

step "Exporting with Developer ID"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>${TEAM}</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$OUT/ohmai.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" -quiet
APP="$OUT/export/ohmai.app"
HELPER="$APP/Contents/MacOS/ohmai-lidhelper"

step "Verifying signatures"
codesign --verify --deep --strict --verbose=1 "$APP"
for bin in "$APP" "$HELPER"; do
  info=$(codesign -dvv "$bin" 2>&1)
  grep -q "Authority=Developer ID Application" <<<"$info" || fail "$bin isn't signed with Developer ID"
  grep -q "TeamIdentifier=${TEAM}" <<<"$info" || fail "$bin has the wrong team"
  grep -q "flags=.*runtime" <<<"$info" || fail "$bin lacks the hardened runtime"
  if codesign -d --entitlements - --xml "$bin" 2>/dev/null | grep -q "get-task-allow"; then
    fail "$bin has get-task-allow (a debug entitlement); notarization would reject it"
  fi
done
[[ -f "$APP/Contents/Library/LaunchDaemons/com.westvold.ohmai.lidhelper.plist" ]] || fail "lid helper launchd plist missing"
echo "signatures OK: app and lid helper, Developer ID, team ${TEAM}, hardened runtime"

if [[ $NOTARIZE == 0 ]]; then
  step "Skipping notarization (--no-notarize)"
  echo "Signed app: $APP"
  exit 0
fi

step "Notarizing (uploads the zip to Apple; usually a few minutes)"
ditto -c -k --keepParent "$APP" "$OUT/${NAME}-upload.zip"
xcrun notarytool submit "$OUT/${NAME}-upload.zip" --keychain-profile "$PROFILE" --wait --output-format plist \
  > "$OUT/notarization.plist" || true
STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$OUT/notarization.plist" 2>/dev/null || echo "unknown")
SUBMISSION=$(/usr/libexec/PlistBuddy -c "Print :id" "$OUT/notarization.plist" 2>/dev/null || echo "")
echo "status: ${STATUS} (submission ${SUBMISSION})"
if [[ "$STATUS" != "Accepted" ]]; then
  [[ -n "$SUBMISSION" ]] && xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" "$OUT/notarization-log.json" || true
  fail "notarization ${STATUS}; see $OUT/notarization-log.json"
fi
rm "$OUT/${NAME}-upload.zip"

step "Stapling and checking Gatekeeper"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | tee "$OUT/gatekeeper.txt"
grep -q "Notarized Developer ID" "$OUT/gatekeeper.txt" || fail "Gatekeeper doesn't report a notarized Developer ID app"

step "Packaging"
ditto -c -k --keepParent "$APP" "build/release/${NAME}.zip"
shasum -a 256 "build/release/${NAME}.zip" | tee "build/release/${NAME}.zip.sha256"

# Keep the zip and dSYMs; remove the loose app copies. Extra copies with the same bundle ID
# confuse macOS's background-item records (the lid helper's approval can't stick).
mv "$OUT/ohmai.xcarchive/dSYMs" "$OUT/dSYMs"
rm -rf "$OUT/ohmai.xcarchive" "$OUT/export"

cat <<EOF

Done: build/release/${NAME}.zip
Next:
  git tag build-${BUILD}        # records that build ${BUILD} shipped (local; push when you choose)
  bump CURRENT_PROJECT_VERSION in Config/Shared.xcconfig before the next release
EOF
