#!/bin/zsh
# Creates a local, self-signed code signing identity "DriveDock Local Signing" in the
# login keychain (once). build-app.sh signs with it, so DriveDock keeps the same identity
# across rebuilds and macOS asks for keychain access only once ("Immer erlauben").
# The certificate is not trusted system-wide and only used for signing this app.
set -euo pipefail

NAME="DriveDock Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Signatur-Zertifikat „$NAME“ ist schon vorhanden."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

cat > "$TMP/cert.cnf" <<EOF
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
EOF

# macOS' own LibreSSL writes a PKCS#12 file that `security import` can read.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/identity.p12" -passout pass:drivedock

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P drivedock -T /usr/bin/codesign >/dev/null
echo "Signatur-Zertifikat „$NAME“ angelegt."
