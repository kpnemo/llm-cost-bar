#!/usr/bin/env bash
# Build the notarized DMG and publish it as a NEW GitHub release.
#
# IMPORTANT: this NEVER deletes or overwrites prior releases or tags. Each
# version stays published so download counts and history accumulate. To ship a
# new version, bump CFBundleShortVersionString (project.yml → App/Info.plist)
# first; this script refuses to run if the tag already exists.
#
# Notarization credentials come from scripts/release.sh — provide EITHER a
# stored `pmw-notary` profile OR the App Store Connect API key via env:
#   NOTARY_KEY=/path/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<uuid> \
#     scripts/publish_release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="kpnemo/llm-cost-bar"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)
TAG="v$VERSION"

# Never clobber an existing release/tag — bump the version instead.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "ERROR: release $TAG already exists." >&2
  echo "Bump CFBundleShortVersionString (project.yml info properties) first." >&2
  exit 1
fi

# Build + sign (Developer ID, hardened runtime) + notarize + staple.
bash scripts/release.sh

# Stable, space-free asset name for a tidy, predictable download URL:
# https://github.com/kpnemo/llm-cost-bar/releases/latest/download/LLMCostBar.dmg
cp "build/LLM Cost Bar.dmg" "build/LLMCostBar.dmg"

# Publish a NEW release. Do NOT pass --cleanup-tag, and never call
# `gh release delete` on a prior version.
gh release create "$TAG" "build/LLMCostBar.dmg#LLM Cost Bar $VERSION (macOS, notarized)" \
  --repo "$REPO" --title "LLM Cost Bar $VERSION" --latest \
  --notes "${RELEASE_NOTES:-LLM Cost Bar $VERSION. Free macOS menu-bar app showing your LLM API spend across OpenRouter, Anthropic, and OpenAI. Download the .dmg, drag to Applications, launch. Requires macOS 14+ and your own vendor billing keys.}"

echo ""
echo "Published $TAG. Prior releases are left intact:"
gh release list --repo "$REPO" --limit 20
