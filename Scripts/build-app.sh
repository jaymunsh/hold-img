#!/bin/bash
set -euo pipefail

APP_NAME="HoldImg"
CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

cd "$ROOT"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
find "$ROOT/Resources" -type f ! -name 'Info.plist' -exec cp {} "$APP_DIR/Contents/Resources/" \;

# Sign with a stable dev identity when available so TCC grants survive rebuilds
# (ad-hoc signatures are cdhash-based and invalidate TCC on every rebuild).
KC="$HOME/.local/share/holdimg-dev/holdimg.keychain-db"
if security find-certificate -c "HoldImg Local Dev" "$KC" >/dev/null 2>&1; then
  codesign --force --keychain "$KC" --sign "HoldImg Local Dev" "$APP_DIR"
else
  codesign --force --sign - "$APP_DIR" 2>/dev/null || true
fi

echo "Built $APP_DIR"
