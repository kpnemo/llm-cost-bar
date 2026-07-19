#!/usr/bin/env bash
# Build the app, install it to /Applications, sign it with the stable local
# identity (so Keychain ACLs and daemon registration persist across rebuilds),
# and launch it.
#
# Run scripts/setup_local_signing.sh once first to create the identity.
# Set NO_LAUNCH=1 to install without launching (e.g. to observe a genuine
# first-run from Finder yourself).
set -euo pipefail
cd "$(dirname "$0")/.."

CERT="LLM Cost Bar Dev"
APP_NAME="LLM Cost Bar"
DEST="/Applications/$APP_NAME.app"
SRC="build/dd/Build/Products/Release/LLMCostBar.app"

# Stable signing is a correctness requirement, not a nicety: an ad-hoc signature
# changes every build, which invalidates Keychain ACLs and can affect
# SMAppService daemon registration. Fail loudly instead of silently degrading.
if ! security find-identity -p codesigning | grep -q "$CERT"; then
  echo "ERROR: stable signing identity \"$CERT\" not found." >&2
  echo "Run scripts/setup_local_signing.sh once to create it, then re-run this." >&2
  exit 1
fi

xcodegen generate
xcodebuild -project LLMCostBar.xcodeproj -scheme LLMCostBar -configuration Release \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build

if [ ! -d "$SRC" ]; then
  echo "ERROR: build product not found at $SRC" >&2
  exit 1
fi

echo "==> Stopping any running app/daemon..."
pkill -f LLMCostBar 2>/dev/null || true
pkill -f llmcostd 2>/dev/null || true
sleep 0.3

echo "==> Installing to $DEST..."
rm -rf "$DEST"
ditto "$SRC" "$DEST"

echo "==> Signing (inside-out, stable identity)..."
# Sign the embedded daemon first, then the outer app bundle. No --entitlements
# — see make_dmg.sh for why (keychain-access-groups needs a provisioning
# profile that a self-signed cert can't provide, and the code doesn't need it).
codesign --force --options runtime --sign "$CERT" "$DEST/Contents/MacOS/llmcostd"
codesign --force --options runtime --sign "$CERT" "$DEST"
echo "    signed with stable identity ($CERT)"

# Sanity-check the signature is the dev leaf and NOT ad-hoc.
codesign --verify --strict "$DEST"
codesign -dr - "$DEST" 2>/dev/null | grep -qi adhoc && { echo "ERROR: bundle is ad-hoc signed" >&2; exit 1; }

if [ -n "${NO_LAUNCH:-}" ]; then
  echo "Installed (not launched): $DEST"
else
  open "$DEST"
  echo "Installed and launched: $DEST"
fi
