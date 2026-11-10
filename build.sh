#!/usr/bin/env bash
# Builds Simpla Recorder.app outside the (Google Drive) project folder.
# Usage: ./build.sh [run]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH="$HOME/Library/Caches/SimplaRecorder-build"
APP="$HOME/Applications/Simpla Recorder.app"

swift build -c release --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c release --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH" --show-bin-path)"

if [[ "${1:-}" == "run" ]]; then
    pkill -x SimplaRecorder 2>/dev/null && sleep 1 || true
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SimplaRecorder" "$APP/Contents/MacOS/SimplaRecorder"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/"*.png "$APP/Contents/Resources/"

# A stable signing identity keeps the Screen Recording permission across rebuilds.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/^ *[0-9]+\)/ { print $2; exit }' || true)"
fi
IDENTITY="${IDENTITY:--}"
echo "Signing with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" "$APP"

echo "$APP"

if [[ "${1:-}" == "run" ]]; then
    open "$APP"
fi
