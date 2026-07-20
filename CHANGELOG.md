# Changelog

All notable changes to LLM Cost Bar are documented here. Each GitHub release
carries its version's section as release notes.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-07-21

### Added
- Per-API-key spend now shows **three columns — today | MTD | 30d** — for all
  vendors, color-coded (blue / white / gray) and aligned under matching totals
  in each vendor card header.
- Vendor card headers show all three totals (today, month-to-date, trailing
  30 days) in both collapsed and expanded states.
- **OpenRouter per-key daily data**: real per-key dollars via the
  `api_key_hash` activity filter — OpenRouter's key list now matches the
  other vendors instead of showing a single lifetime number.
- New menu bar display option: **Last 30 days** (Settings → Menu bar shows).
- VoiceOver labels for the per-key spend columns.

### Changed
- Dropdown widened 380 → 440 pt to fit the three-column layout.
- Per-key totals for OpenRouter now cover the trailing 30 days (previously
  lifetime). Keys with no spend in the last 30 days no longer appear in the
  key list.
- Anthropic per-key figures remain estimates (allocated from org cost by
  token share, now day-by-day) and are labeled "est. spend"; OpenAI and
  OpenRouter per-key figures are real dollars.

### Fixed
- Per-key 30-day totals are clipped to the same 30-day window as the header,
  so a key row can no longer exceed the vendor total above it.
- Key rows keep a stable order between refreshes when spend values tie.

## [1.0.0] - 2026-07-19

Initial public release.

- macOS menu bar app + background daemon tracking LLM API spend across
  **OpenRouter, Anthropic, and OpenAI**.
- Today / month-to-date totals, 30-day per-vendor bar charts, per-key spend,
  credits/balance display where the vendor exposes it.
- API keys stored in the macOS Keychain only; all data stays on device.
- Notarized DMG distribution.

[1.1.0]: https://github.com/kpnemo/llm-cost-bar/releases/tag/v1.1.0
[1.0.0]: https://github.com/kpnemo/llm-cost-bar/releases/tag/v1.0.0
