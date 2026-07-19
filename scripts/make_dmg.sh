#!/usr/bin/env bash
# Build the app and package it into a drag-to-Applications .dmg installer.
# Does NOT install anything — it just produces build/LLM Cost Bar.dmg, which
# you double-click and drag into Applications (Finder prompts to replace if it
# already exists).
#
# Run scripts/setup_local_signing.sh once first so the app gets the stable
# signature (keeps Keychain ACLs / grants across reinstalls).
set -euo pipefail
cd "$(dirname "$0")/.."

CERT="LLM Cost Bar Dev"
APP_NAME="LLM Cost Bar"
SRC="build/dd/Build/Products/Release/LLMCostBar.app"
STAGE="build/dmg-stage"
DMG="build/$APP_NAME.dmg"

if ! security find-identity -p codesigning | grep -q "$CERT"; then
  echo "ERROR: stable signing identity \"$CERT\" not found." >&2
  echo "Run scripts/setup_local_signing.sh once to create it, then re-run this." >&2
  exit 1
fi

echo "==> Building (Release, unsigned)..."
xcodegen generate
xcodebuild -project LLMCostBar.xcodeproj -scheme LLMCostBar -configuration Release \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build >/dev/null
echo "    build ok"

if [ ! -d "$SRC" ]; then
  echo "ERROR: build product not found at $SRC" >&2
  exit 1
fi

echo "==> Staging + signing the app (inside-out)..."
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$SRC" "$STAGE/$APP_NAME.app"

# Sign the embedded daemon first, then the outer app bundle. No --entitlements:
# App/*.entitlements declare a keychain-access-groups group that requires a
# provisioning profile; with a self-signed cert that would block launch. The
# app doesn't rely on that access group (login-keychain ACL + Always Allow is
# the working model), so signing without entitlements is correct here.
codesign --force --options runtime --sign "$CERT" \
  "$STAGE/$APP_NAME.app/Contents/MacOS/llmcostd"
codesign --force --options runtime --sign "$CERT" \
  "$STAGE/$APP_NAME.app"
echo "    signed with stable identity ($CERT)"

codesign --verify --strict "$STAGE/$APP_NAME.app"
echo "    signature verified"

if [ -f "scripts/generate_dmg_background.swift" ]; then
  echo "==> Generating installer background..."
  swift scripts/generate_dmg_background.swift || echo "    (background generation failed, continuing without it)"
fi

echo "==> Building the .dmg..."
rm -f "$DMG"
mkdir -p build

if command -v create-dmg >/dev/null 2>&1; then
  BG_ARGS=()
  if [ -f "build/dmg_background.png" ]; then
    BG_ARGS=(--background "build/dmg_background.png")
  fi
  # create-dmg sometimes exits non-zero even when the .dmg is fine; verify by file.
  create-dmg \
    --volname "$APP_NAME" \
    "${BG_ARGS[@]}" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 120 \
    --icon "$APP_NAME.app" 150 200 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 450 200 \
    --no-internet-enable \
    "$DMG" \
    "$STAGE" || true
fi

if [ ! -f "$DMG" ]; then
  echo "==> create-dmg unavailable or failed; falling back to hdiutil..."
  ln -sf /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi

if [ -f "$DMG" ]; then
  echo "==> Done: $DMG"
  open -R "$DMG"  # reveal it in Finder
else
  echo "ERROR: DMG was not created"; exit 1
fi
