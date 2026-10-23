#!/bin/zsh
# Renders the README screenshots from the DEMO mailbox (fictional people), never a real one.
#   scripts/screenshots.sh              writes docs/screenshots/*.png
#
# Run it from Terminal.app (or iTerm), NOT from inside Claude Code: an app started from there can't show a
# window, so the export never begins and the script times out. It builds the app bundle and launches it with
# `open`; the app opens its window, waits for the on-device model to write the summaries, saves the PNGs
# and quits itself.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$PWD/docs/screenshots"
APP="$PWD/build/GmailGTD.app"
EXPECTED=4

./scripts/make-app.sh debug >/dev/null
rm -rf "$OUT"
mkdir -p "$OUT"

echo "Launching the demo app and rendering $EXPECTED screenshots (a minute or two)..."
open -n "$APP" --args --demo --export-screenshots "$OUT"

# `open` returns at once, so wait for the files and for the app to exit.
for _ in {1..360}; do
  count=$(find "$OUT" -name '*.png' | wc -l | tr -d ' ')   # find, not a glob: zsh treats an empty glob as an error
  if [[ "$count" -ge "$EXPECTED" ]] && ! pgrep -f "$APP/Contents/MacOS/GmailGTD" >/dev/null; then
    echo "Done."
    ls -lh "$OUT"
    echo "Open them with: open docs/screenshots"
    exit 0
  fi
  sleep 1
done

echo "Timed out with $count of $EXPECTED screenshots. Stopping the app." >&2
pkill -f "$APP/Contents/MacOS/GmailGTD" || true
exit 1
