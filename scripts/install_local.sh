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

APP_NAME="LLM Cost Bar"
DEST="/Applications/$APP_NAME.app"
SRC="build/dd/Build/Products/Release/LLMCostBar.app"

# Identity preference order matters because of SMAppService launch constraints:
# BTM pins a code requirement for the registered daemon. A team-backed Apple
# certificate pins the TEAM (stable across rebuilds); a self-signed cert pins the
# exact binary, so every rebuild gets the daemon SIGKILLed (Launch Constraint
# Violation) until re-registration. Prefer real Apple identities.
CERT=$(security find-identity -v -p codesigning \
  | grep -E "Developer ID Application|Apple Development" | head -1 \
  | sed -E 's/^[^"]*"([^"]+)".*/\1/')
[ -z "$CERT" ] && CERT="LLM Cost Bar Dev"
if ! security find-identity -p codesigning | grep -q "$CERT"; then
  echo "ERROR: no signing identity found (Apple Development / Developer ID / local dev cert)." >&2
  echo "Run scripts/setup_local_signing.sh once to create the local dev cert, then re-run." >&2
  exit 1
fi
echo "==> Signing identity: $CERT"

xcodegen generate
xcodebuild -project LLMCostBar.xcodeproj -scheme LLMCostBar -configuration Release \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build

if [ ! -d "$SRC" ]; then
  echo "ERROR: build product not found at $SRC" >&2
  exit 1
fi

echo "==> Stopping any running app/daemon..."
# Bootout (not pkill) the daemon: with KeepAlive, a pkill'd daemon respawns
# instantly and can exec a half-copied binary mid-install (stale-code race).
launchctl bootout "gui/$(id -u)/com.mikeb.llmcostd" 2>/dev/null || true
pkill -f LLMCostBar 2>/dev/null || true
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

# Restore the daemon against the final signed binary (app launch also self-heals).
if [ -f "$HOME/Library/LaunchAgents/com.mikeb.llmcostd.plist" ]; then
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.mikeb.llmcostd.plist" 2>/dev/null || true
  launchctl kickstart "gui/$(id -u)/com.mikeb.llmcostd" 2>/dev/null || true
fi

if [ -n "${NO_LAUNCH:-}" ]; then
  echo "Installed (not launched): $DEST"
else
  open "$DEST"
  echo "Installed and launched: $DEST"
fi
