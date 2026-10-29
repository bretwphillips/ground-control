#!/bin/sh
# Creates a self-signed code signing identity in the login keychain and trusts it
# for code signing, once. macOS ties the Accessibility grant to a trusted identity,
# so it survives rebuilds; an untrusted one gets pinned to a single build instead.
set -e
name="Ground Control Dev"
keychain=~/Library/Keychains/login.keychain-db

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

if ! security find-certificate -c "$name" >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$name" \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  openssl pkcs12 -export -legacy -passout pass:groundcontrol \
    -inkey "$dir/key.pem" -in "$dir/cert.pem" -out "$dir/identity.p12"
  security import "$dir/identity.p12" -k "$keychain" -P groundcontrol -T /usr/bin/codesign
  echo "Created \"$name\""
fi

# Asks for your password once.
security find-certificate -c "$name" -p > "$dir/cert.pem"
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$dir/cert.pem"
echo "\"$name\" is trusted for code signing"

# Lets codesign use the key without asking on every build ("Always Allow" alone doesn't stick).
# Asks for your login password once.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$keychain" >/dev/null
echo "codesign can use it without asking"
