#!/bin/sh
# Creates the local code-signing identity that Window Columns is signed with.
#
# Why this exists
# ---------------
# An ad-hoc signature (`codesign --sign -`) has no certificate, so the bundle's
# designated requirement is a bare content hash:
#
#     designated => cdhash H"4254ff3d...."
#
# macOS records that requirement when you grant Accessibility. Every rebuild
# produces a different binary, so the hash changes and the stored grant stops
# matching — while System Settings still shows the switch turned on, because
# that row is keyed by bundle identifier. The app is untrusted and keeps asking
# for a permission you already gave it.
#
# Signing with a certificate instead makes the requirement
#
#     designated => identifier "com.adimaskil.WindowColumns"
#                   and certificate leaf = H"<certificate hash>"
#
# which is identical for every future build, so the grant is given once and
# survives every rebuild.
#
# The certificate is self-signed, usable only for code signing, and stays in
# your login keychain. It is deliberately NOT added to your trust settings:
# codesign accepts an untrusted local certificate, and the requirement above is
# pinned to the certificate either way, so there is no reason to install a
# trusted root or ask for your password.
#
# Run once:  make signing-identity
set -eu

IDENTITY_NAME=${WINDOW_COLUMNS_IDENTITY:-Window Columns Local Signing}
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Apple's own LibreSSL. Homebrew's OpenSSL 3 defaults to a PKCS#12 MAC that
# `security import` rejects with "MAC verification failed", so do not take
# whichever openssl happens to be first on PATH.
OPENSSL=/usr/bin/openssl

if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY_NAME"; then
    echo "Signing identity \"$IDENTITY_NAME\" already exists. Nothing to do."
    exit 0
fi

# A previous run can leave certificates behind with no private key, which are
# useless and clutter Keychain Access. Clear them before making a new one.
while security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; do
    HASH=$(security find-certificate -c "$IDENTITY_NAME" -Z "$KEYCHAIN" 2>/dev/null \
        | awk '/^SHA-256 hash:/ { print $3; exit }')
    [ -n "${HASH:-}" ] || break
    security delete-certificate -Z "$HASH" "$KEYCHAIN" >/dev/null 2>&1 || break
    echo "Removed a leftover certificate from an earlier attempt."
done

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

echo "Creating a self-signed code-signing certificate..."
"$OPENSSL" req -x509 -newkey rsa:2048 \
    -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" \
    -days 3650 -nodes -subj "/CN=$IDENTITY_NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

if ! "$OPENSSL" x509 -in "$WORK_DIR/cert.pem" -noout -text | grep -q "Code Signing"; then
    echo "The generated certificate is missing the codeSigning usage." >&2
    exit 1
fi

"$OPENSSL" pkcs12 -export \
    -out "$WORK_DIR/identity.p12" \
    -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -name "$IDENTITY_NAME" -passout pass:windowcolumns >/dev/null 2>&1

echo "Adding it to your login keychain..."
security import "$WORK_DIR/identity.p12" \
    -k "$KEYCHAIN" -P windowcolumns \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

if ! security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY_NAME"; then
    echo "The identity was imported but codesign cannot see it." >&2
    echo "Check Keychain Access for \"$IDENTITY_NAME\" and that it has a private key." >&2
    exit 1
fi

echo
echo "Done. \"$IDENTITY_NAME\" will be used automatically by 'make install'."
echo "If a keychain dialog appears during the first build, choose Always Allow."
echo
echo "Next:"
echo "  make reset-permission   # clear the stale ad-hoc grants"
echo "  make run                # rebuild, install, and launch"
echo "Then grant Accessibility once. It will survive every rebuild from now on."
