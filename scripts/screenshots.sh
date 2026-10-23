#!/bin/zsh
# Renders the README screenshots from the DEMO mailbox (fictional people), never a real one.
# Run it from a normal terminal in your logged-in session: it opens the app's window and uses the
# on-device model to write the summaries, so it takes a minute or two. The window closes itself.
#   scripts/screenshots.sh              writes docs/screenshots/*.png
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=docs/screenshots
swift build --product GmailGTD
BIN="$(swift build --product GmailGTD --show-bin-path)/GmailGTD"

rm -rf "$OUT"
mkdir -p "$OUT"
"$BIN" --demo --export-screenshots "$OUT"

echo
ls -lh "$OUT"
echo "Open them with: open $OUT"
