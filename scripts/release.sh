#!/usr/bin/env bash
# Build a SIGNED + NOTARIZED + STAPLED .dmg for direct distribution.
# Result: users double-click the .dmg, drag to Applications, and launch with no
# Gatekeeper warning.
#
# Prerequisites (one-time):
#   1) A "Developer ID Application" certificate in your keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
#   2) Notarization credentials, via EITHER:
#      a) A stored profile (local use; shared with Polish My Writing):
#           xcrun notarytool store-credentials pmw-notary \
#             --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"
#      b) An App Store Connect API key (CI-friendly) via env vars:
#           NOTARY_KEY=/path/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<uuid> scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="LLM Cost Bar"
SRC="build/dd/Build/Products/Release/LLMCostBar.app"
STAGE="build/dmg-stage"
DMG="build/$APP_NAME.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-pmw-notary}"

# Auto-detect the Developer ID Application identity.
DEV_ID=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed -E 's/^[^"]*"([^"]+)".*/\1/')
if [ -z "$DEV_ID" ]; then
  echo "ERROR: No 'Developer ID Application' certificate found." >&2
  exit 1
fi
echo "==> Signing identity: $DEV_ID"

echo "==> Building (Release)…"
xcodegen generate
xcodebuild -project LLMCostBar.xcodeproj -scheme LLMCostBar -configuration Release \
  -derivedDataPath build/dd \
  CODE_SIGNING_ALLOWED=NO build >/dev/null
echo "    build ok"

echo "==> Staging + signing (inside-out: daemon first, then the app)…"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$SRC" "$STAGE/$APP_NAME.app"
codesign --force --options runtime --timestamp --sign "$DEV_ID" \
  "$STAGE/$APP_NAME.app/Contents/MacOS/llmcostd"
codesign --force --options runtime --timestamp --sign "$DEV_ID" \
  "$STAGE/$APP_NAME.app"
codesign --verify --strict --verbose=2 "$STAGE/$APP_NAME.app"

if [ -f "scripts/generate_dmg_background.swift" ]; then
  echo "==> Generating installer background…"
  swift scripts/generate_dmg_background.swift || echo "    (skipped)"
fi

echo "==> Building the .dmg…"
rm -f "$DMG"
BG_ARGS=()
[ -f "build/dmg_background.png" ] && BG_ARGS=(--background "build/dmg_background.png")
create-dmg \
  --volname "$APP_NAME" \
  "${BG_ARGS[@]}" \
  --window-pos 200 120 --window-size 600 400 --icon-size 120 \
  --icon "$APP_NAME.app" 150 200 --hide-extension "$APP_NAME.app" \
  --app-drop-link 450 200 --no-internet-enable \
  "$DMG" "$STAGE" || true
[ -f "$DMG" ] || { echo "ERROR: dmg not created"; exit 1; }

echo "==> Signing the .dmg…"
codesign --force --sign "$DEV_ID" --timestamp "$DMG"

echo "==> Notarizing (uploads to Apple; usually 1-5 min)…"
if [ -n "${NOTARY_KEY:-}" ]; then
  xcrun notarytool submit "$DMG" \
    --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
else
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
fi

echo "==> Stapling the notarization ticket…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Gatekeeper assessment…"
spctl -a -vvv -t install "$DMG" || true

echo ""
echo "DONE: $DMG  (signed + notarized + stapled)"
[ -z "${CI:-}" ] && open -R "$DMG" || true
