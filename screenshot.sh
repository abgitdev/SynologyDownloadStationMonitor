#!/bin/bash
# Capture only the app's front window (clean shot, no surrounding desktop).
# Usage: ./screenshot.sh [output.png]
set -euo pipefail
OUT="${1:-build/shots/shot.png}"
APP_MATCH="SynologyDownload"
mkdir -p "$(dirname "$OUT")"

# Bring the app window to the front (activate is more reliable than System Events frontmost).
osascript -e 'tell application id "com.abgitdev.SynologyDownloadStationMonitor" to activate' >/dev/null 2>&1 || true
osascript -e "tell application \"System Events\" to set frontmost of (first process whose name contains \"$APP_MATCH\") to true" >/dev/null 2>&1 || true
osascript -e 'delay 1.2' >/dev/null 2>&1 || true

# Read front window position+size (points).
BOUNDS=$(osascript -e "tell application \"System Events\" to tell (first process whose name contains \"$APP_MATCH\") to get (get {position, size} of front window)" 2>/dev/null || echo "")

if [ -n "$BOUNDS" ]; then
  X=$(echo "$BOUNDS" | awk -F', *' '{print $1}')
  Y=$(echo "$BOUNDS" | awk -F', *' '{print $2}')
  W=$(echo "$BOUNDS" | awk -F', *' '{print $3}')
  H=$(echo "$BOUNDS" | awk -F', *' '{print $4}')
  screencapture -x -R"${X},${Y},${W},${H}" "$OUT"
else
  echo "  (window bounds not found; full-screen capture)"
  screencapture -x "$OUT"
fi
echo "$OUT"
