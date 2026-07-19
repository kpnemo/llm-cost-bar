# LLM Cost Bar

A macOS menu bar app that shows your LLM API spend across vendors in one place —
today's burn, month-to-date, prepaid balance, and top API keys — with a
supervised background daemon that keeps collecting even when you're not looking.

**Status:** MVP — OpenRouter supported. OpenAI, Anthropic, and Gemini are next
(the provider interface is designed for it; see `docs/ARCHITECTURE.md`).

## Features

- Menu bar glance: icon + today's spend (configurable: icon only / today / MTD)
- Dropdown with per-vendor cards: today, MTD, balance, top API keys
- One-click pairing: browser-based OAuth (PKCE) for OpenRouter — no key pasting
  (paste fallback available, and used for vendors without OAuth)
- API keys stored in the macOS Keychain, never on disk
- Background daemon (launchd) polls on your schedule, backfills after sleep,
  and relaunches the app if it crashes; launchd relaunches the daemon
- Every sync attempt logged to a Diagnostics view — no silent failures

## Install (from source)

Requirements: macOS 14+, Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), an Apple Development signing identity.

    git clone <this repo> && cd LLM-cost-bar
    echo "DEVELOPMENT_TEAM = <your team id>" > Signing.xcconfig
    xcodegen generate
    xcodebuild -scheme LLMCostBar -configuration Release build
    # copy the built LLMCostBar.app to /Applications and open it

On first launch, approve the background item in
System Settings → General → Login Items.

### Signing

The app and daemon share a Keychain access group, which needs a real team ID
to resolve `$(AppIdentifierPrefix)` in the entitlements. Two ways to build:

- **Signed (recommended):** open Xcode, sign into your Apple ID (Settings →
  Accounts), then put that team's ID in `Signing.xcconfig` as shown above.
  Free Apple ID accounts work fine for local, unnotarized builds.
- **Unsigned local build:** skip `Signing.xcconfig` and pass
  `CODE_SIGNING_ALLOWED=NO` to `xcodebuild` instead. This builds without any
  Apple ID, but Keychain sharing between the app and daemon won't work
  correctly, so pairing/credential storage may misbehave — fine for reading
  the code or running `swift test`, not for daily use.

## Development

Core logic is a SwiftPM package — fast tests, no Xcode needed:

    cd Core && swift test

Layout: `Core/` (all logic: models, SQLite store, providers, sync engine),
`Daemon/` (llmcostd loop), `App/` (SwiftUI menu bar UI). Design docs live in
`docs/superpowers/specs/`, implementation plans in `docs/superpowers/plans/`,
architecture overview in `docs/ARCHITECTURE.md`.

## License

[MIT](LICENSE)
