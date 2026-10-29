#!/bin/sh
# Builds "build/Ground Control.app" from the Swift package.
set -e
cd "$(dirname "$0")/.."

swift build -c release

app="build/Ground Control.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/GroundControl "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
# Signed with scripts/make-cert.sh's identity when it exists, so the Accessibility grant survives rebuilds.
identity="Ground Control Dev"
security find-certificate -c "$identity" >/dev/null 2>&1 || identity="-"
if ! codesign --force --sign "$identity" "$app"; then
  # A dismissed keychain prompt lands here; an unsigned build would launch without its permissions.
  rm -rf "$app"
  echo "Signing failed: allow codesign to use the \"$identity\" key (Always Allow) and run again." >&2
  exit 1
fi

echo "$app"
