#!/bin/bash
#
# Create the persistent self-signed code-signing identity used for releases.
#
# Run once on the release machine. See docs/signing.md for why a stable identity matters (ad-hoc
# signatures change every build, which makes macOS treat each release as a different program).
#
# Local development does NOT need this: project.yml and Tools/build-app.sh both default to ad-hoc
# signing, so a fresh clone builds with an empty keychain.

set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Nib Self-Signed"
OUT="Tools/.signing"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists in the keychain. Nothing to do."
    echo "To recreate it, delete it in Keychain Access first."
    exit 0
fi

mkdir -p "$OUT"
chmod 700 "$OUT"

read -r -s -p "Passphrase for the exported .p12: " P12_PASSWORD
echo
[ -n "$P12_PASSWORD" ] || { echo "A passphrase is required."; exit 1; }

echo "==> generating a 10-year code-signing certificate"

# extendedKeyUsage=codeSigning is the part that matters -- without it codesign rejects the identity.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$OUT/nib.key" -out "$OUT/nib.crt" \
    -subj "/CN=$NAME/O=Nib/C=US" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    2>/dev/null

openssl pkcs12 -export \
    -inkey "$OUT/nib.key" -in "$OUT/nib.crt" \
    -out "$OUT/nib.p12" -name "$NAME" \
    -passout pass:"$P12_PASSWORD"

echo "==> importing into the login keychain"
# This may prompt for your login password, and may ask you to allow codesign access to the key.
security import "$OUT/nib.p12" -f pkcs12 -P "$P12_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security

rm -f "$OUT/nib.key" "$OUT/nib.crt"

echo
printf '\x00' > "$OUT/.probe"
echo "==> done"
# `find-identity -p codesigning` lists identities the system *trusts* for that policy, and a
# self-signed certificate is not trusted by default. It will not appear there, and that is fine:
# codesign signs with it regardless. Only verification against a trust policy needs trust, and
# Gatekeeper was never going to accept a self-signed app anyway. So check the certificate is
# present and prove it can actually sign, rather than asking a question with a misleading answer.
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "certificate \"$NAME\" is in the keychain"
    if codesign --force --sign "$NAME" --timestamp=none "$OUT/.probe" 2>/dev/null; then
        echo "and codesign can use it"
    fi
else
    echo "WARNING: \"$NAME\" is not in the keychain. Something went wrong above."
fi

echo
echo "For CI, store these two GitHub secrets:"
echo "  SIGNING_P12_PASSWORD  = the passphrase you just entered"
echo "  SIGNING_P12_BASE64    = the base64 below"
rm -f "$OUT/.probe"
echo
base64 < "$OUT/nib.p12"
echo
echo "Then delete $OUT/nib.p12 -- it is gitignored, but it does not need to stay on disk."
