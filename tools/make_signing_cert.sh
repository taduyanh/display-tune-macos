#!/bin/zsh
# Creates a self-signed code-signing identity in its OWN keychain, so rebuilt DisplayTune.app bundles keep a stable
# code requirement (macOS ties the Accessibility permission to it; ad-hoc signatures change on every build).
# It touches neither your login keychain nor any trust settings, and never asks for a password.
set -euo pipefail

NAME="DisplayTune Local Signing"
KC="$HOME/Library/Keychains/displaytune-signing.keychain-db"
KC_PASS="displaytune"      # the keychain only guards a throw-away local signing key

if [[ -f "$KC" ]] && security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  echo "Signing identity already exists in $KC"; exit 0
fi

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
P12PASS=$(uuidgen)
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/id.p12" -passout "pass:$P12PASS"

rm -f "$KC"
security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings "$KC"                      # never auto-lock
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" >/dev/null
echo "Created signing identity '$NAME' in $KC"
