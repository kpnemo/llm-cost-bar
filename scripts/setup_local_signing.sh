#!/usr/bin/env bash
# One-time setup: create a STABLE self-signed code-signing identity for local
# testing. A stable signature means macOS keeps Keychain ACLs / TCC grants
# across rebuilds, instead of re-prompting every time an ad-hoc build changes.
#
# Gatekeeper will still mark this cert untrusted — that's fine; it only matters
# for distribution (use a real Developer ID for a notarized .dmg). For running
# locally and keeping grants stable, this is all that's needed.
set -euo pipefail

CERT="LLM Cost Bar Dev"

if security find-identity -p codesigning | grep -q "$CERT"; then
  echo "Identity already exists: $CERT"
  exit 0
fi

echo "Creating self-signed code-signing identity \"$CERT\"..."
OSSL=$(openssl version)
LEGACY=""; case "$OSSL" in *"OpenSSL 3"*) LEGACY="-legacy";; esac

cat > /tmp/llmcostbar_openssl.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = LLM Cost Bar Dev
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout /tmp/llmcostbar_key.pem -out /tmp/llmcostbar_cert.pem \
  -days 3650 -nodes -config /tmp/llmcostbar_openssl.cnf
# Apple's keychain needs the legacy PKCS12 MAC/PBE algorithms.
openssl pkcs12 -export $LEGACY -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -inkey /tmp/llmcostbar_key.pem -in /tmp/llmcostbar_cert.pem -out /tmp/llmcostbar.p12 \
  -passout pass:llmcostbar -name "$CERT"
# -A lets codesign use the key without a keychain prompt on every build.
security import /tmp/llmcostbar.p12 -k ~/Library/Keychains/login.keychain-db -P llmcostbar -A -T /usr/bin/codesign
rm -f /tmp/llmcostbar_key.pem /tmp/llmcostbar_cert.pem /tmp/llmcostbar.p12 /tmp/llmcostbar_openssl.cnf

echo "Done. Identity \"$CERT\" created (shown as CSSMERR_TP_NOT_TRUSTED — expected)."
