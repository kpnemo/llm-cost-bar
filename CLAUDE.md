# LLM Cost Bar — agent guide

macOS menu bar app + launchd daemon showing LLM API spend across vendors.

## Layout
- `Core/` — SwiftPM package `LLMCostBarCore`: ALL logic lives here (models,
  GRDB/SQLite store, Keychain, vendor providers, sync engine). Test with
  `cd Core && swift test`. Prefer adding logic here, not in App/Daemon.
- `Daemon/main.swift` — llmcostd: poll loop, watchdog, heartbeat. Thin.
- `App/` — SwiftUI MenuBarExtra UI + Settings + pairing. Thin; reads SQLite via
  `UsageStore`, never calls vendor APIs directly.
- `project.yml` — XcodeGen. Regenerate with `xcodegen generate` after changing
  it. `Signing.xcconfig` is machine-local (gitignored): `DEVELOPMENT_TEAM = …`.

## Rules
- Vendor I/O only in the daemon via `VendorProvider` implementations.
- New vendor = new `VendorProvider` conformance in Core + tests with recorded
  JSON fixtures + a case in `SyncEngine.defaultProviderFactory` + Settings entry.
- All usage normalized to daily rows (`usage_daily`); upserts must stay
  idempotent on (vendor, account_id, api_key_id, model, day).
- API keys: Keychain only (`KeychainStore`). Never in config.json, SQLite, logs.
- Every sync attempt must land in `sync_log` — no silent failures.
- Errors follow the `ProviderError` taxonomy: transient (retry) / auth
  (needs_reauth, no retry) / http / decode.

## Verify changes
- `cd Core && swift test` — must pass.
- Full build: `xcodegen generate && xcodebuild -scheme LLMCostBar build`.
- Design spec: `docs/superpowers/specs/2026-07-19-llm-cost-bar-design.md`.
