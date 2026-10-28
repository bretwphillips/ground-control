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
codesign --force --sign - "$app"

echo "$app"
