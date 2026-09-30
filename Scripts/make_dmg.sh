#!/usr/bin/env bash
#
# Build an unsigned (ad-hoc signed) Human Detector.app and pack it into
# build/HumanDetector.dmg. Used by `make dmg` and the release workflow.
#
# The DMG name is fixed so that
#   https://github.com/<owner>/<repo>/releases/latest/download/HumanDetector.dmg
# always resolves to the newest release.
#
# Refuses to package model files: the YOLO and SCRFD weights are third-party
# (AGPL-3.0 / non-commercial research) and must not be redistributed from here.
# Set ALLOW_MODELS=1 to override, for a private build only.
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Human Detector"
APP_DIR="build/DerivedData/Build/Products/Release/${APP_NAME}.app"
STAGE="build/dmg"
DMG="build/HumanDetector.dmg"
ENTITLEMENTS="Sources/HumanDetectorApp/HumanDetector.entitlements"

echo "▶ xcodegen generate"
xcodegen generate >/dev/null

echo "▶ xcodebuild (Release, unsigned)"
xcodebuild \
  -project HumanDetector.xcodeproj \
  -scheme HumanDetector \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

[ -d "$APP_DIR" ] || { echo "error: $APP_DIR was not produced" >&2; exit 1; }

if [ "${ALLOW_MODELS:-0}" != "1" ]; then
  models="$(find "$APP_DIR" \( -name '*.mlmodelc' -o -name '*.mlpackage' -o -name '*.mlmodel' \) -print)"
  if [ -n "$models" ]; then
    echo "error: model files are inside the app bundle:" >&2
    echo "$models" >&2
    echo "Empty Resources/Models/ (keep .gitkeep) and rebuild, or set ALLOW_MODELS=1 for a private build." >&2
    exit 1
  fi
fi

# Apple Silicon refuses to run unsigned code, so sign ad hoc, keeping the sandbox entitlements.
echo "▶ codesign (ad hoc)"
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "▶ hdiutil"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP_DIR" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✔ $DMG ($(du -h "$DMG" | cut -f1))"
