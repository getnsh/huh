#!/usr/bin/env bash
# Creates a self-signed code-signing certificate for local development.
#
# TCC records permission grants against the application's code signature. An
# ad-hoc signature changes with every build, so each build is treated as a new
# application and Microphone and Accessibility must be granted again. A stable
# certificate avoids this.
#
# This is a development convenience only. Distribution requires a Developer ID
# certificate; see scripts/notarize.sh.
#
# Run once:   sudo ./scripts/make-signing-cert.sh
# Then build: SIGN_ID="Huh Dev" ./scripts/build.sh
set -euo pipefail

NAME="${1:-Huh Dev}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "$EUID" -ne 0 ]; then
    echo "!! run with sudo — adding a trusted certificate needs admin rights"
    exit 1
fi

# SUDO_USER is unset when the script is elevated through a GUI authorisation
# prompt rather than sudo, in which case $USER is root and the certificate would
# be imported into the wrong keychain. The console owner is authoritative.
REAL_USER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
LOGIN_KEYCHAIN="$(eval echo "~$REAL_USER")/Library/Keychains/login.keychain-db"

echo "==> generating key + certificate for \"$NAME\""
cat > "$TMP/ext.cnf" <<CNF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3
[ dn ]
CN = $NAME
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/ext.cnf" 2>/dev/null

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/bundle.p12" -passout pass: -name "$NAME"

echo "==> importing into $REAL_USER's login keychain"
sudo -u "$REAL_USER" security import "$TMP/bundle.p12" \
    -k "$LOGIN_KEYCHAIN" -P "" -A -T /usr/bin/codesign

echo "==> trusting it for code signing (system keychain)"
security add-trusted-cert -d -r trustRoot \
    -p codeSign -k /Library/Keychains/System.keychain "$TMP/cert.pem"

echo
echo "Done. Build with a stable signature:"
echo "    SIGN_ID=\"$NAME\" ./scripts/build.sh release"
