#!/bin/sh
# Builds "build/Ground Control.app" from the Swift package.
set -e
cd "$(dirname "$0")/.."

swift build -c release

app="build/Ground Control.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/GroundControl "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
# Signed with scripts/make-cert.sh's identity when it exists, so the Accessibility grant survives rebuilds.
identity="Ground Control Dev"
security find-certificate -c "$identity" >/dev/null 2>&1 || identity="-"
codesign --force --sign "$identity" "$app"

echo "$app"
