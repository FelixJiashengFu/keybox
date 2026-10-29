#!/bin/bash
# Runs the debug app in its --ui-snapshot test mode on a throwaway data folder and saves the
# screenshots to ${1:-shots}. Exit status is the test result. Needs scripts/build-app.sh debug first.
set -uo pipefail
cd "$(dirname "$0")/.."

SHOTS="$(cd "$(dirname "${1:-shots}")" && pwd)/$(basename "${1:-shots}")"
mkdir -p "$SHOTS"
DATA="$(mktemp -d)"

"dist/debug/密钥匣.app/Contents/MacOS/KeyBox" --data "$DATA" --ui-snapshot "$SHOTS" &
PID=$!
( sleep 300; kill "$PID" 2>/dev/null ) &
GUARD=$!
wait "$PID"
CODE=$?
kill "$GUARD" 2>/dev/null
screencapture -x "$SHOTS/zz-whole-screen.png" 2>/dev/null || true
if [ "$CODE" -ne 0 ]; then
  # show where it crashed
  REPORT="$(ls -t ~/Library/Logs/DiagnosticReports/KeyBox* 2>/dev/null | head -1)"
  [ -n "$REPORT" ] && { echo "--- $REPORT"; head -c 12000 "$REPORT"; cp "$REPORT" "$SHOTS/"; }
fi
rm -rf "$DATA"
exit "$CODE"
