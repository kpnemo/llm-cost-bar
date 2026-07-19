# LLM Cost Bar

[![Downloads](https://img.shields.io/github/downloads/kpnemo/llm-cost-bar/total?color=2ea44f&label=downloads)](https://github.com/kpnemo/llm-cost-bar/releases/latest)

A macOS menu-bar app that shows your LLM API spend across vendors in one
place — today's live burn, month-to-date, credits, 30-day charts, and per-key
breakdowns — with a supervised background daemon that keeps collecting even
when you're not looking.

**Supported vendors:** OpenRouter, Anthropic, OpenAI. Gemini is pending
(Google exposes no spend API for AI Studio keys yet).

- **One glance** — menu bar shows today's spend or MTD (configurable).
- **Per-vendor cards** — today, MTD, credits progress, a 30-day chart with
  hover, and your top API keys by spend.
- **Per-key spend** — real per-key dollars for OpenRouter and OpenAI;
  smart estimates for Anthropic (which has no per-key cost API).
- **Private by design** — no backend. Keys live in the macOS Keychain; usage
  data goes straight from the vendor APIs to a local SQLite DB. See
  [PRIVACY.md](PRIVACY.md).
- **No silent failures** — every sync attempt lands in a Diagnostics view.

## Install

1. Download **LLMCostBar.dmg** from the [latest release](../../releases/latest).
2. Open the DMG and drag **LLM Cost Bar** into **Applications**.
3. Launch it — it lives in the menu bar (no Dock icon). Open Settings and
   connect a provider.

The app is signed with a Developer ID and notarized by Apple — no Gatekeeper
warnings. When the background daemon first reads a newly added key, macOS asks
once per key; click **Always Allow**.

### Connecting providers

| Vendor | What you need |
| --- | --- |
| OpenRouter | A **management key** from [openrouter.ai/settings/provisioning-keys](https://openrouter.ai/settings/provisioning-keys) (regular API keys can't read usage) |
| Anthropic | An **Admin API key** (`sk-ant-admin…`) from [Claude Console → Admin keys](https://platform.claude.com/settings/admin-keys). Requires a team org — individual accounts must first use *Convert to team* in Console → Settings → Organization |
| OpenAI | An **Admin API key** (`sk-admin…`) from [Settings → Organization → Admin keys](https://platform.openai.com/settings/organization/admin-keys) (org owner role) |

These elevated keys are read-only for billing data in practice, but treat them
like secrets — the app stores them only in your Keychain.

## Build from source

Requires macOS 14+, Xcode 15+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
git clone https://github.com/kpnemo/llm-cost-bar && cd llm-cost-bar
echo "DEVELOPMENT_TEAM = <your team id>" > Signing.xcconfig   # or leave out for unsigned
xcodegen generate
xcodebuild -scheme LLMCostBar -configuration Release build
cd Core && swift test        # all logic lives in a SwiftPM package
```

For a local signed install there's `scripts/install_local.sh`; for a
notarized release DMG, `scripts/release.sh` (Developer ID required).

Layout: `Core/` (models, SQLite store, vendor providers, sync engine — all
logic and tests), `Daemon/` (`llmcostd` poll loop), `App/` (SwiftUI menu bar
UI). Architecture notes in `docs/`.

## Why isn't this on the Mac App Store?

It ships a launchd background daemon and reads org-level billing APIs with
keys you provide — a poor fit for sandbox review cycles. Like many menu-bar
utilities, it's distributed directly as a notarized, Developer ID-signed app.
It's free and open source.

## License

[MIT](LICENSE)
