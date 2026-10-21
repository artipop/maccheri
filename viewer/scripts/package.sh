#!/bin/sh
# Builds MaccheriViewer.app (ad-hoc signed) and zips it for copying to another Mac.
set -eu
cd "$(dirname "$0")/.."
DERIVED="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/MaccheriViewer}"
xcodebuild -project MaccheriViewer.xcodeproj -scheme MaccheriViewer -configuration Release -destination generic/platform=macOS \
    -derivedDataPath "$DERIVED" build 2>&1 | grep -E "error:|BUILD" || true
APP="$DERIVED/Build/Products/Release/MaccheriViewer.app"
codesign --verify "$APP"
mkdir -p build
rm -f build/MaccheriViewer.zip
ditto -c -k --keepParent "$APP" build/MaccheriViewer.zip
echo "$PWD/build/MaccheriViewer.zip"
