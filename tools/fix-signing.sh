#!/bin/bash
# Creates a self-signed code-signing certificate so macOS stops forgetting Sill's
# Accessibility permission every time the app is rebuilt.
#
# WHY THIS IS NEEDED
# macOS ties the Accessibility grant to a "designated requirement" — its record of which
# app was approved. With an ad-hoc signature (the default here) that requirement is a hash
# of the binary itself, so it changes with every build and the grant silently dies. The
# System Settings toggle still *looks* on, which is why the app keeps asking.
#
# With a certificate, the requirement becomes "the app named app.sill.Sill signed by this
# certificate" — stable across every rebuild, forever.
#
# It asks for your login password once, to let `codesign` use the key it just made.
# Free, offline, no Apple Developer account.
set -euo pipefail

NAME="Sill Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "→ '$NAME' already exists and is valid. Nothing to do."
    exit 0
fi

echo "→ creating the certificate"
cat > "$TMP/cfg" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Sill Dev
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/k.pem" -out "$TMP/c.pem" \
    -days 3650 -nodes -config "$TMP/cfg" 2>/dev/null
openssl pkcs12 -export -out "$TMP/sill.p12" -inkey "$TMP/k.pem" -in "$TMP/c.pem" \
    -name "$NAME" -passout pass:sill 2>/dev/null

echo "→ adding it to your login keychain"
security import "$TMP/sill.p12" -k "$KEYCHAIN" -P sill -T /usr/bin/codesign -A >/dev/null

echo "→ trusting it for code signing (asks for your login password)"
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$TMP/c.pem"

echo "→ allowing codesign to use the key (asks for your login password again)"
read -r -s -p "   login password: " PW; echo
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KEYCHAIN" >/dev/null 2>&1

echo
echo "Done. From now on build with:"
echo "    SILL_SIGN_IDENTITY=\"$NAME\" ./build.sh"
echo
echo "Then grant Accessibility one last time — it will stick after that."
