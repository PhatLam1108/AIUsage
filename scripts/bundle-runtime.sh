#!/bin/bash
# Xcode build phase of the AIUsage target: ship the background runtime inside the app.
# Copies runtime/*.sh and *.py, and compiles ClaudeHelper.swift into a universal
# ClaudeUsageHelper.app signed with the app's identity. On first launch the app's
# RuntimeInstaller copies both to ~/Library/Application Support/AIUsage.
set -euo pipefail

DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/runtime"
rm -rf "$DEST"
mkdir -p "$DEST"
# -X: no extended attributes (a synced Documents folder adds Finder info that breaks codesign).
cp -X "$PROJECT_DIR"/runtime/*.sh "$PROJECT_DIR"/runtime/*.py "$DEST/"
chmod 755 "$DEST"/*.sh "$DEST"/*.py

H="$DEST/ClaudeUsageHelper.app/Contents"
mkdir -p "$H/MacOS" "$H/Resources"
cp -X "$PROJECT_DIR/ClaudeHelper/Info.plist" "$H/Info.plist"
cp -X "$PROJECT_DIR/ClaudeHelper/AppIcon.icns" "$H/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION:-1.0}" \
                        -c "Set :LSMinimumSystemVersion ${MACOSX_DEPLOYMENT_TARGET}" "$H/Info.plist"

TMP="$DERIVED_FILE_DIR/helper"
mkdir -p "$TMP"
OUTS=()
for arch in ${ARCHS:-arm64}; do
  xcrun -sdk macosx swiftc -O -target "$arch-apple-macos$MACOSX_DEPLOYMENT_TARGET" \
    "$PROJECT_DIR/ClaudeHelper/ClaudeHelper.swift" -o "$TMP/helper-$arch" \
    -framework AppKit -framework WebKit
  OUTS+=("$TMP/helper-$arch")
done
lipo -create "${OUTS[@]}" -output "$H/MacOS/ClaudeUsageHelper"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -z "$IDENTITY" ] && IDENTITY="-"
codesign --force --sign "$IDENTITY" --timestamp=none "$DEST/ClaudeUsageHelper.app"
