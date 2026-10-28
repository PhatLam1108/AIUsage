#!/bin/bash
# Builds a universal (arm64 + x86_64) Release of AIUsage and packs it into
# dist/AIUsage-<version>.dmg with an Applications shortcut for drag-to-install.
# Usage: scripts/build-dmg.sh   (DEVELOPER_DIR may point at a beta Xcode)
set -euo pipefail
cd "$(dirname "$0")/.."

# Build outside the project: a synced Documents folder adds Finder metadata that breaks codesign.
BUILD="${TMPDIR:-/tmp}/AIUsage_release"
LOG=build/release.log
mkdir -p build dist
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release \
  -derivedDataPath "$BUILD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=non-global \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
  clean build > "$LOG" 2>&1 || true
grep -q "BUILD SUCCEEDED" "$LOG" || { grep -E "error:" "$LOG" | head -20; echo "Build failed, see $LOG"; exit 1; }

APP="$BUILD/Build/Products/Release/AIUsage.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
lipo -archs "$APP/Contents/MacOS/AIUsage"
codesign --verify --deep --strict "$APP"
# Stripped binaries must not carry build-machine paths (debug maps name every source file).
if find "$APP" -type f -perm -u+x -exec grep -l -a "$HOME" {} + 2>/dev/null | grep -q .; then
  echo "Build contains paths under $HOME; refusing to package."; exit 1
fi

# Keep the build copy out of LaunchServices so the widget never runs from it.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -u "$APP" 2>/dev/null || true

STAGE=$(mktemp -d)
ditto --norsrc --noextattr "$APP" "$STAGE/AIUsage.app"
ln -s /Applications "$STAGE/Applications"
OUT="dist/AIUsage-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "AIUsage $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" > /dev/null
rm -rf "$STAGE"
shasum -a 256 "$OUT"
echo "$OUT"
