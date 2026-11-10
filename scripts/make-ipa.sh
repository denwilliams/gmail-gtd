#!/bin/sh
# Builds an unsigned build/GmailGTD.ipa for sideloading (AltStore signs it with each person's own Apple ID).
#   scripts/make-ipa.sh [version] [build]     e.g. scripts/make-ipa.sh 1.1 7
set -eu
cd "$(dirname "$0")/.."

VERSION="${1:-1.0}"
BUILD="${2:-1}"
DD=build/ios-release-dd
OUT=build/GmailGTD.ipa
# The published bundle ID (it must match the AltStore source), and no team: AltStore signs it. Its own copy of the
# project, so your signed iOS/GmailGTDiOS.xcodeproj is left alone.
export GMAIL_GTD_BUNDLE_ID=dev.denw.gmail-gtd.ios GMAIL_GTD_TEAM=
# (A wrapper spec beside project.yml, so its relative paths still hold; *.xcodeproj is gitignored.)
printf 'include: [project.yml]\nname: GmailGTDiOS-ipa\n' > iOS/ipa.yml
xcodegen generate --quiet --spec iOS/ipa.yml
rm -f iOS/ipa.yml
xcodebuild -project iOS/GmailGTDiOS-ipa.xcodeproj -scheme GmailGTDiOS -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DD" -quiet \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
    build

STAGE=build/ipa-stage
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/Payload"
cp -R "$DD/Build/Products/Release-iphoneos/Gmail GTD.app" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry ../GmailGTD.ipa Payload)
rm -rf "$STAGE"
echo "Built $OUT ($VERSION build $BUILD)"
