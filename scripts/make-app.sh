#!/bin/zsh
# Builds build/GmailGTD.app: a double-clickable app with a real icon, from the SwiftPM executable.
#   scripts/make-app.sh          release build
#   scripts/make-app.sh debug    debug build (faster)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
APP=build/GmailGTD.app
BUNDLE_ID=dev.denw.gmail-gtd   # also the name of the settings suite, so settings carry over from `swift run`

swift build -c "$CONFIG" --product GmailGTD
BIN=$(swift build -c "$CONFIG" --product GmailGTD --show-bin-path)/GmailGTD

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GmailGTD"

# The app draws its own icon; ask it for the PNGs, then let iconutil make the .icns.
"$BIN" --export-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Gmail GTD</string>
    <key>CFBundleDisplayName</key><string>Gmail GTD</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>GmailGTD</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally. (Distributing to other Macs needs a Developer ID and notarisation.)
codesign --force --sign - "$APP"
echo "Built $APP"
