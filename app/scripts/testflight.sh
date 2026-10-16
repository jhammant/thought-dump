#!/usr/bin/env bash
# Archive Thought Dump (iPhone/iPad app + embedded Watch app), export it for
# App Store Connect and upload it to TestFlight.
#
# Signing is automatic: with the App Store Connect API key, Xcode registers the
# bundle IDs and makes the distribution profiles itself. The key's settings live
# in ~/.appstoreconnect/brain.env (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH).
# The App Store Connect app record must exist first (the API can't create one).
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
# shellcheck disable=SC1090
source "${ASC_ENV:-$HOME/.appstoreconnect/brain.env}"
set +a
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
ARCHIVE=build/testflight/ThoughtDump.xcarchive
EXPORT_DIR=build/testflight/export

if [[ "${SKIP_ARCHIVE:-}" != "1" ]]; then
  rm -rf build/testflight
  mkdir -p build/testflight
  xcodegen generate >/dev/null
  echo "Archiving build ${BUILD_NUMBER}..."
  # To a log file, not a pipe: Xcode's helpers can hold a pipe open after xcodebuild exits.
  if ! xcodebuild -project ThoughtDump.xcodeproj -scheme ThoughtDump -configuration Release \
      -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" "${AUTH[@]}" \
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive > build/testflight-archive.log 2>&1 < /dev/null; then
    grep -E "error:" build/testflight-archive.log | head -20
    echo "ARCHIVE FAILED (full log: build/testflight-archive.log)"
    exit 1
  fi
  echo "** ARCHIVE SUCCEEDED **"
fi
rm -rf "$EXPORT_DIR"
mkdir -p build/testflight
cp scripts/ExportOptions.plist build/testflight/ExportOptions.plist

echo "Exporting..."
# Xcode's IPA packaging runs the first rsync on PATH; Homebrew's rejects Apple's flags.
if ! PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist build/testflight/ExportOptions.plist "${AUTH[@]}" > build/testflight-export.log 2>&1 < /dev/null; then
  grep -E "error:" build/testflight-export.log | head -20
  echo "EXPORT FAILED (full log: build/testflight-export.log)"
  exit 1
fi
echo "** EXPORT SUCCEEDED **"

[[ "${SKIP_UPLOAD:-}" == "1" ]] && exit 0
IPA=$(find "$EXPORT_DIR" -name '*.ipa' | head -1)
echo "Uploading $(basename "$IPA") ($(du -h "$IPA" | cut -f1))..."
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format normal
echo "Uploaded build ${BUILD_NUMBER}. It appears in TestFlight once App Store Connect finishes processing (5-15 minutes)."
