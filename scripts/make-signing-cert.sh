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
REAL_HOME="$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[ -n "$REAL_HOME" ] || { echo "!! could not resolve the home directory for $REAL_USER" >&2; exit 1; }
LOGIN_KEYCHAIN="$REAL_HOME/Library/Keychains/login.keychain-db"

# The certificate name is interpolated into an OpenSSL config below, where a
# newline would inject directives.
case "$NAME" in
    *[!A-Za-z0-9\ ._-]*|"") echo "!! name may contain only letters, digits, spaces, dots, hyphens and underscores" >&2; exit 1 ;;
esac

# A one-off passphrase, so the exported key is never written to disk
# unprotected even for the seconds it exists in the temp directory.
#
# `head` has to come first. Written the other way round -- tr reading
# /dev/urandom, piped into head -- tr is still reading when head has taken
# what it wants, takes SIGPIPE, and exits 141; `set -o pipefail` propagates
# that and `set -e` kills the script before it generates anything. This
# script exited 141 on every run until it was written this way.
P12PASS="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32)"
if [ "${#P12PASS}" -ne 32 ]; then
    echo "!! could not generate a passphrase" >&2
    exit 1
fi

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
    -days 365 -config "$TMP/ext.cnf" 2>/dev/null

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/bundle.p12" -passout "pass:$P12PASS" -name "$NAME"

echo "==> importing into $REAL_USER's login keychain"
sudo -u "$REAL_USER" security import "$TMP/bundle.p12" \
    -k "$LOGIN_KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign

# Trusted for this user only, not machine-wide.
#
# An earlier version added this to the system keychain as a full trust root, and
# imported the private key with -A, which let any process on the machine sign
# code the system would accept. A local development convenience does not warrant
# either.
echo "==> trusting it for code signing ($REAL_USER's login keychain)"
sudo -u "$REAL_USER" security add-trusted-cert -r trustAsRoot \
    -p codeSign -k "$LOGIN_KEYCHAIN" "$TMP/cert.pem"

echo
echo "Done. Build with a stable signature:"
echo "    SIGN_ID=\"$NAME\" ./scripts/build.sh release"
echo
echo "To remove it later:"
echo "    security delete-certificate -c \"$NAME\" \"$LOGIN_KEYCHAIN\""
