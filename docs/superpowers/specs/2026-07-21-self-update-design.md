# Self-Update — design spec

Date: 2026-07-21
Status: approved (brainstormed interactively; UX options validated via visual mockups)

## Problem

LLM Cost Bar is distributed as a notarized DMG on GitHub Releases
(`kpnemo/llm-cost-bar`). Users have no way to learn that a new version exists,
and updating means manually downloading the DMG and dragging the app over.
The app should detect new releases, offer the update unobtrusively, and — on
one click — download, verify, install, and relaunch itself.

## Decisions

| Question | Decision |
|---|---|
| Mechanism | **Custom updater**, no Sparkle. The already-published notarized `LLMCostBar.dmg` release asset is the update artifact; zero release-pipeline changes. |
| Discovery | **Automatic daily check + manual** "Check for Updates…" in Settings. |
| Surface | **Quiet row in the popover** ("⬆ Update available — vX.Y.Z [Install]") plus an Updates section in Settings. No notifications, no modal alerts. |
| Install flow | **Fully automatic**: Install click → download progress in the row → verify → swap bundle → self-relaunch. One click total. |

Why custom over Sparkle: the release pipeline already produces exactly what an
updater needs (immutable versioned notarized DMGs at a stable asset URL), the
app is non-sandboxed (entitlements are keychain-group only), and Sparkle would
add a framework dependency, an appcast to generate/host, and EdDSA key
management to every release for no additional safety here — the downloaded
bundle is verified against the Developer ID team before install.

## Architecture

Logic in Core (testable), orchestration in the App. This is deliberately an
exception to "network I/O lives in the daemon": that rule exists for vendor
usage syncing; the updater must run in the app process because the app has to
replace and relaunch itself, and the row/progress UI lives there.

```
Core: UpdateService                      App: UpdaterModel (ObservableObject)
  ReleaseInfo {version, dmgURL, notes}     idle / checking / available /
  parse releases/latest JSON               downloading(pct) / installing /
  select asset "LLMCostBar.dmg"            upToDate / failed(message)
  semver isNewer(remote, local)            check ~10 s after launch, then 24 h
                                         App: UpdateInstaller
                                           download → mount → verify → swap → relaunch
```

- Check: `GET https://api.github.com/repos/kpnemo/llm-cost-bar/releases/latest`
  (unauthenticated; 60 req/h limit is ample for 1/day). `tag_name` = `vX.Y.Z`;
  running version from `Bundle.main` `CFBundleShortVersionString`.
- Config: `autoCheckUpdates: Bool = true` in `AppConfig` (per-field decode).

## Install sequence

1. Download DMG to a temp dir (`URLSession` download task; progress → row).
2. `hdiutil attach -nobrowse -readonly`, `ditto` the `.app` to a staging dir,
   `hdiutil detach`.
3. Verify the staged bundle **before touching anything**:
   `codesign --verify --deep --strict` passes, TeamIdentifier equals `R5QHA2A8Z9` (the Developer ID release-signing team — NOT the
   dev DEVELOPMENT_TEAM 4KY3876TB2), and staged `CFBundleShortVersionString` matches the release.
4. Strip quarantine from the staged bundle (post-verification) so relaunch
   avoids Gatekeeper translocation.
5. Stop the daemon: `launchctl bootout gui/<uid>/com.mikeb.llmcostd` and
   delete the heartbeat file — the relaunched app's `DaemonManager.ensure()`
   then takes its missing-heartbeat path and re-bootstraps. Booting out first
   also disarms the watchdog so it can't relaunch the old app mid-swap.
6. Swap at `Bundle.main.bundleURL`: move the current bundle to the Trash
   (the running process keeps its inode), `ditto` the staged app into place.
7. Relaunch: detached `/bin/sh -c 'sleep 1; /usr/bin/open -n "<path>"'`, then
   `NSApp.terminate` (clean-quit mark is written by `applicationWillTerminate`).
8. Any failure → restore the old bundle if it was moved,
   `DaemonManager.ensure(force: true)`, state `failed(message)` with Retry.
   Log via `os.Logger`. `sync_log` is not used (vendor syncs only).

## UI

- Popover (`DropdownView`): tinted row between content and footer, hidden when
  idle/up-to-date. States: available (Install button) → downloading (percent +
  progress bar) → installing → transient "✓ Updated" post-relaunch; failed
  shows the error with Retry.
- Settings (`GeneralTab`): "Updates" section — current version, auto-check
  toggle, "Check for Updates…" button, last-check status line.

## Testing

- Unit (Core): semver compare (incl. `1.2.0` < `1.10.0`), release JSON fixture
  parsing, asset selection among multiple assets, malformed JSON → error.
- Manual E2E: build locally with version lowered to `1.1.0` → row offers the
  real latest release → Install → verify swap, relaunch, daemon heartbeat.
- Negative: offline check fails silently (status only in Settings); a bundle
  failing signature/team verification aborts with the old app untouched.

## Out of scope

Sparkle/appcast, EdDSA keys, release-pipeline changes, "skip this version",
delta updates, in-app release-notes rendering.
