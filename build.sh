#!/usr/bin/env bash
# Builds Simpla Recorder.app. Build products stay outside the (Google Drive) project folder.
#
#   ./build.sh           build and install to /Applications
#   ./build.sh run       same, then (re)launch the app
#   ./build.sh release   build an ad-hoc signed zip for distribution (path is printed)
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH="$HOME/Library/Caches/SimplaRecorder-build"
MODE="${1:-}"

swift build -c release --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c release --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH" --show-bin-path)"

# Assembles the bundle at $1 and signs it with identity $2.
assemble() {
    local app="$1" identity="$2"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$BIN_DIR/SimplaRecorder" "$app/Contents/MacOS/SimplaRecorder"
    cp "$PROJECT_DIR/Resources/Info.plist" "$app/Contents/Info.plist"
    cp "$PROJECT_DIR/Resources/"*.png "$PROJECT_DIR/Resources/AppIcon.icns" "$app/Contents/Resources/"
    echo "Signing with identity: $identity"
    codesign --force --sign "$identity" "$app"
}

if [[ "$MODE" == "release" ]]; then
    # Ad-hoc signature: runs on any Apple Silicon Mac and embeds no personal certificate.
    DIST="$SCRATCH/dist"
    rm -rf "$DIST"
    mkdir -p "$DIST"
    assemble "$DIST/Simpla Recorder.app" "-"
    ditto -c -k --keepParent "$DIST/Simpla Recorder.app" "$DIST/SimplaRecorder.zip"
    echo "$DIST/SimplaRecorder.zip"
    exit 0
fi

APP="/Applications/Simpla Recorder.app"
if [[ "$MODE" == "run" ]]; then
    pkill -x SimplaRecorder 2>/dev/null && sleep 1 || true
fi

# A stable signing identity keeps the Screen Recording permission across rebuilds.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/^ *[0-9]+\)/ { print $2; exit }' || true)"
fi
assemble "$APP" "${IDENTITY:--}"
echo "$APP"

if [[ "$MODE" == "run" ]]; then
    open "$APP"
fi
