#!/bin/zsh
# Builds Gmail GTD and installs it to ~/Applications, replacing any previous copy.
#   scripts/install.sh               release build, install, launch
#   scripts/install.sh --debug       faster debug build
#   scripts/install.sh --no-open     install without launching
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
OPEN_AFTER=1
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --no-open) OPEN_AFTER=0 ;;
    *) echo "Unknown option: $arg" >&2; echo "Usage: scripts/install.sh [--debug] [--no-open]" >&2; exit 2 ;;
  esac
done

APP=GmailGTD.app
DEST="$HOME/Applications"
INSTALLED="$DEST/$APP"

./scripts/make-app.sh "$CONFIG"

# Replacing a running app leaves the old one in memory, so quit it first.
if pgrep -f "$INSTALLED/Contents/MacOS/GmailGTD" >/dev/null; then
  echo "Quitting the running copy..."
  osascript -e 'tell application id "dev.denw.gmail-gtd" to quit' >/dev/null 2>&1 || true
  for _ in {1..10}; do
    pgrep -f "$INSTALLED/Contents/MacOS/GmailGTD" >/dev/null || break
    sleep 0.5
  done
  pkill -f "$INSTALLED/Contents/MacOS/GmailGTD" 2>/dev/null || true
fi

mkdir -p "$DEST"
rm -rf "$INSTALLED"
ditto "build/$APP" "$INSTALLED"   # ditto keeps the code signature intact
echo "Installed $INSTALLED"

if [[ "$OPEN_AFTER" == 1 ]]; then
  open "$INSTALLED"
fi
