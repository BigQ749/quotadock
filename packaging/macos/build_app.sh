#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MAC_DIR="$ROOT_DIR/macos/QuotaDockMac"
DIST_DIR="$ROOT_DIR/dist"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
APP_DIR="$DIST_DIR/QuotaDock.app"
ZIP_PATH="$DIST_DIR/QuotaDock-macOS-v${VERSION}.zip"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid VERSION: $VERSION" >&2
  exit 1
fi

cd "$MAC_DIR"
swift build -c release

rm -rf "$APP_DIR" "$ZIP_PATH"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/QuotaDock" "$APP_DIR/Contents/MacOS/QuotaDock"
chmod +x "$APP_DIR/Contents/MacOS/QuotaDock"
sed "s/__VERSION__/${VERSION}/g" "$MAC_DIR/Info.plist" > "$APP_DIR/Contents/Info.plist"

if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [[ -f "$ROOT_DIR/assets/app/QuotaDock-v2.png" ]]; then
  ICONSET="$DIST_DIR/QuotaDock.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$ROOT_DIR/assets/app/QuotaDock-v2.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$ROOT_DIR/assets/app/QuotaDock-v2.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/QuotaDock.icns"
  rm -rf "$ICONSET"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string QuotaDock" "$APP_DIR/Contents/Info.plist"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH"
echo "MAC_APP=$APP_DIR"
echo "MAC_ZIP=$ZIP_PATH"
