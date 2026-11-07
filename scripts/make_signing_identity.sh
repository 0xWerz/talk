#!/usr/bin/env bash
# Creates a stable, self-signed code-signing identity for Talk.
#
# Why this exists: an ad-hoc signature (`codesign -s -`) carries no identity, so
# macOS keys Talk's Accessibility, Input Monitoring and Microphone grants to the
# binary's hash. Every rebuild then silently invalidates them — System Settings
# still lists Talk and still shows the toggle, but it no longer applies to the
# new binary. Signing with a real (if self-signed) certificate gives the app a
# stable designated requirement, so grants survive rebuilds.
#
# Safe to re-run: it does nothing if the identity already exists.
set -euo pipefail

IDENTITY="${TALK_SIGN_IDENTITY:-Talk Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "Signing identity '$IDENTITY' already exists — nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/req.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "==> Generating a 20-year self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/req.cnf" 2>/dev/null

# macOS cannot read OpenSSL 3's default PKCS#12 encryption, hence the old algorithms.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/id.p12" -passout pass:talk -name "$IDENTITY" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "==> Importing into your login keychain"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P talk -T /usr/bin/codesign -A >/dev/null

echo
echo "Created '$IDENTITY'. Rebuild with ./scripts/bundle.sh, grant permissions"
echo "once, and they will survive every future rebuild."
echo
echo "To remove it later: security delete-certificate -c '$IDENTITY'"
