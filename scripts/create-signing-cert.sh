#!/bin/bash
# Creates a self-signed code-signing certificate ("iShot Local Signing") in the login keychain.
#
# Why: an ad-hoc signed app is identified by macOS privacy (TCC) only through the hash of its
# binary, so every rebuild looks like a brand-new app and the Screen Recording permission is lost.
# Signing every build with the same certificate gives the app a stable identity
# (bundle ID + certificate), so the permission survives rebuilds.
#
# Run once. build-app.sh picks the certificate up automatically.
set -euo pipefail

NAME="${ISHOT_CERT_NAME:-iShot Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl   # system LibreSSL: its PKCS#12 output is readable by `security import`

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Certificate \"$NAME\" already exists in the login keychain."
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

    echo "==> Generating key and certificate (valid 10 years)"
    "$OPENSSL" req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
        -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

    PASS="ishot-$RANDOM$RANDOM"
    "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -name "$NAME" -out "$TMP/cert.p12" -passout "pass:$PASS"

    echo "==> Importing into the login keychain (codesign is allowed to use the key)"
    security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
    echo "Imported \"$NAME\"."
fi

# codesign only accepts identities whose certificate is trusted for code signing.
if security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "\"$NAME\" is a valid code-signing identity."
    exit 0
fi

echo "==> Trusting the certificate for code signing (macOS will ask for your password)"
CERT_PEM="$(mktemp)"
trap 'rm -f "$CERT_PEM"' EXIT
security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$CERT_PEM"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_PEM"

security find-identity -v -p codesigning "$KEYCHAIN" | grep "\"$NAME\"" \
    && echo "Done: \"$NAME\" is ready. Now run scripts/build-app.sh --install"
