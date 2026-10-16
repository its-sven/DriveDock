#!/bin/zsh
# Creates a self-signed code signing certificate for release builds and prints it as
# base64 for the GitHub secrets RELEASE_CERT_P12 / RELEASE_CERT_PASSWORD.
#
# Why: ad hoc signed builds get a new identity with every release, so macOS asks users
# for keychain access again after each update. Signing every release with the same
# certificate keeps that permission. It does NOT replace an Apple Developer ID –
# Gatekeeper still asks on first launch (see docs/RELEASING.md).
#
# Usage: scripts/make-release-cert.sh [output-dir]
set -euo pipefail

NAME="DriveDock Release Signing"
OUT="${1:-$PWD/release-cert}"
mkdir -p "$OUT"
chmod 700 "$OUT"

cat > "$OUT/cert.cnf" <<EOF
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

PASSWORD="$(/usr/bin/openssl rand -base64 24)"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$OUT/cert.cnf" -keyout "$OUT/key.pem" -out "$OUT/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$OUT/key.pem" -in "$OUT/cert.pem" \
  -name "$NAME" -out "$OUT/release-signing.p12" -passout "pass:$PASSWORD"
rm -f "$OUT/key.pem" "$OUT/cert.cnf"
base64 -i "$OUT/release-signing.p12" > "$OUT/RELEASE_CERT_P12.txt"
print -r -- "$PASSWORD" > "$OUT/RELEASE_CERT_PASSWORD.txt"

cat <<EOF
Created in $OUT:
  release-signing.p12        keep this safe and private (never commit it)
  RELEASE_CERT_P12.txt       -> GitHub secret RELEASE_CERT_P12
  RELEASE_CERT_PASSWORD.txt  -> GitHub secret RELEASE_CERT_PASSWORD

Add both under Settings → Secrets and variables → Actions, then delete the .txt files.
EOF
