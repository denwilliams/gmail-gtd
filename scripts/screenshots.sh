#!/bin/zsh
# Renders the README screenshots from the DEMO mailbox (fictional people), never a real one.
#   scripts/screenshots.sh              writes docs/screenshots/*.png
#
# A window opens and flips through four views while the on-device model writes the summaries. It takes
# two or three minutes, closes itself, and needs to be left open. Existing screenshots are replaced only
# when all four new ones are done.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$PWD/docs/screenshots"
NEW="$PWD/docs/screenshots.new"
APP="$PWD/build/GmailGTD.app"
BIN="$APP/Contents/MacOS/GmailGTD"
EXPECTED=4

./scripts/make-app.sh debug >/dev/null
rm -rf "$NEW"
mkdir -p "$NEW"

echo "Launching the demo app. A window will open and flip through $EXPECTED views: please leave it open (2-3 minutes)."
open -n "$APP" --args --demo --export-screenshots "$NEW"

seen=0; gone=0
for _ in {1..420}; do
  count=$(find "$NEW" -name '*.png' | wc -l | tr -d ' ')   # find, not a glob: zsh treats an empty glob as an error
  if pgrep -f "$BIN" >/dev/null; then seen=1; gone=0; else [[ $seen == 1 ]] && gone=$((gone + 1)); fi

  if [[ "$count" -ge "$EXPECTED" && $gone -ge 2 ]]; then
    rm -rf "$OUT"; mv "$NEW" "$OUT"
    echo "Done."
    ls -lh "$OUT"
    echo "Open them with: open docs/screenshots"
    exit 0
  fi
  if [[ $gone -ge 5 ]]; then
    echo "The app closed after $count of $EXPECTED screenshots (was its window closed early?). Existing screenshots were left alone." >&2
    exit 1
  fi
  sleep 1
done

echo "Timed out with $count of $EXPECTED screenshots. Stopping the app." >&2
pkill -f "$BIN" || true
exit 1
