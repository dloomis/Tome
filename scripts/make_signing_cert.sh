#!/usr/bin/env bash
#
# Create the stable self-signed code-signing certificate that
# build_swift_app.sh auto-detects (default name "Tome Self-Signed",
# override with SELF_SIGNED_IDENTITY). Free — no Apple account.
#
# Why: an ad-hoc signature (`codesign -s -`) hashes differently on every
# build, so TCC (mic / Screen & System Audio Recording) treats each build
# as a new app and the toggles must be re-added after every install.
# Signing every build with the SAME certificate keeps the app's designated
# requirement stable, so TCC grants persist across rebuilds.
#
# Run once. Expect two GUI prompts:
#   1. keychain password when trusting the new cert
#   2. on the first build, "codesign wants to sign using key ..." — click
#      "Always Allow" so later builds sign without prompting
#
# After the FIRST build signed with this cert, macOS sees a new identity one
# last time: re-add Tome's mic + screen recording grants once more. Every
# rebuild after that keeps them.

set -euo pipefail

NAME="${SELF_SIGNED_IDENTITY:-Tome Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "A valid identity named \"$NAME\" already exists:"
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# 10-year self-signed cert with the Code Signing extended key usage.
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE"

# Bundle into PKCS#12 and import key+cert into the login keychain,
# pre-authorizing codesign to use the key.
P12_PASS="tome-$(date +%s)"
openssl pkcs12 -export -out "$WORKDIR/cert.p12" \
  -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
  -passout "pass:$P12_PASS"
security import "$WORKDIR/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security

# Trust the cert for code signing (user trust domain). This is what makes
# `security find-identity -v` report the identity as valid; expect a
# keychain-password prompt here.
echo "Trusting \"$NAME\" for code signing (you may be prompted for your password)..."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORKDIR/cert.pem"

echo
if security find-identity -v -p codesigning | grep "$NAME"; then
  echo "Done. build_swift_app.sh will now pick up \"$NAME\" automatically."
else
  echo "Cert imported but not reported valid yet — check Keychain Access ▸ login ▸ My Certificates." >&2
  exit 1
fi
