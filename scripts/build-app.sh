#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TokenRec"
BUNDLE_DIR="$ROOT_DIR/dist/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications/$APP_NAME.app"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
cp "scripts/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"
cp ".build/release/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
codesign --force --deep --sign - "$BUNDLE_DIR"

mkdir -p "$HOME/Applications"
rm -rf "$INSTALL_DIR"
cp -R "$BUNDLE_DIR" "$INSTALL_DIR"

echo "Built $BUNDLE_DIR"
echo "Installed $INSTALL_DIR"
