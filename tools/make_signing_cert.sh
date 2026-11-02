#!/bin/zsh
# Creates a self-signed code-signing identity in its OWN keychain, so rebuilt DisplayTune.app bundles keep a stable
# code requirement (macOS ties the Accessibility permission to it; ad-hoc signatures change on every build).
# It touches neither your login keychain nor any trust settings, and never asks for a password.
#
# Usage: tools/make_signing_cert.sh [--reset]     (--reset throws the identity away and creates a new one;
#                                                  the new one has a different certificate, so Accessibility must be granted again)
#
# Security notes: the keychain password is random per machine and kept in a 0600 file next to the keychain; the keychain
# is locked again after every build. Anything running as YOUR user can still read that file, so treat the identity as a
# local developer convenience (see "Security notes" in the README).
set -euo pipefail
umask 077

NAME="DisplayTune Local Signing"
KC="$HOME/Library/Keychains/displaytune-signing.keychain-db"
PASS_FILE="$HOME/Library/Keychains/displaytune-signing.pass"

# Locks the keychain, unlocks it with the stored password and signs a throw-away binary: proves the whole chain works.
self_test() {
  local probe; probe=$(mktemp -d)/probe; cp /bin/ls "$probe"
  security lock-keychain "$KC"
  security unlock-keychain -p "$(<"$PASS_FILE")" "$KC" \
    || { echo "error: cannot unlock $KC with the stored password" >&2; return 1; }
  codesign --force --options runtime --sign "$NAME" --keychain "$KC" "$probe" >/dev/null 2>&1 \
    || { echo "error: codesign with '$NAME' failed" >&2; security lock-keychain "$KC"; return 1; }
  security lock-keychain "$KC"
  rm -rf "${probe:h}"
}

if [[ "${1:-}" == "--reset" ]]; then
  rm -f "$KC" "$PASS_FILE"
elif [[ -f "$KC" && -f "$PASS_FILE" ]] && security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  chmod 600 "$KC" "$PASS_FILE"
  if self_test; then echo "Signing identity OK ($KC)"; exit 0; fi
  echo "The existing identity is unusable. Run: tools/make_signing_cert.sh --reset" >&2; exit 1
fi

KC_PASS=$(uuidgen)
printf '%s' "$KC_PASS" > "$PASS_FILE"; chmod 600 "$PASS_FILE"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT      # mktemp -d is 0700
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
export P12PASS=$(uuidgen)
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/id.p12" -passout env:P12PASS

security create-keychain -p "$KC_PASS" "$KC"
chmod 600 "$KC"
security set-keychain-settings "$KC"                      # never auto-lock (build.sh locks it after signing)
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" >/dev/null
self_test
echo "Created signing identity '$NAME' in $KC (leaf SHA-1: $(security find-certificate -c "$NAME" -Z "$KC" | awk '/SHA-1/{print $3}'))"
