#!/bin/sh
# Creates a self-signed code signing identity in the login keychain, once.
# Builds signed with it keep the same identity, so macOS remembers the
# Accessibility permission across rebuilds instead of asking every time.
set -e
name="Ground Control Dev"

if security find-certificate -c "$name" >/dev/null 2>&1; then
  echo "\"$name\" already exists"
  exit 0
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$name" \
  -keyout "$dir/key.pem" -out "$dir/cert.pem" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -legacy -passout pass:groundcontrol \
  -inkey "$dir/key.pem" -in "$dir/cert.pem" -out "$dir/identity.p12"
security import "$dir/identity.p12" -k ~/Library/Keychains/login.keychain-db \
  -P groundcontrol -T /usr/bin/codesign

echo "Created \"$name\""
