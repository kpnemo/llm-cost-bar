# Responsiveness measurements

The local performance build keeps cached dashboard data visible while a worker
actor reads SQLite and files. It applies only changed values, observes individual
properties, and prepares chart points outside SwiftUI rendering. Refresh requests
coalesce instead of accumulating. UTC day rollover and live-spend estimates retain
the existing accounting rules.

## What the timing means

For menu opening, popup tab changes, and Settings tab changes:

- Start: the original local `NSEvent.timestamp` on mouse-down or key-down. This
  includes time the event waited before the app handled it (and mouse-button hold
  time for controls that activate on mouse-up).
- `mouse_hold_ms` and `release_to_render_ms` separate button hold time from
  the response after release, when a matching mouse-up was observed.
- `queue_ms`: event creation to its delivery to the local event monitor.
- `draw_pass_ms`: event creation to the main-queue turn after the target view's
  drawing sentinel was drawn by AppKit.
- `render_proxy_ms`: event creation to the first display-refresh timestamp after
  that drawing pass. It includes a display-refresh interval; it is a practical
  estimate of visible readiness, **not a measured GPU/compositor presentation
  fence or physical pixel latency**. It does not wait for fresh network data.

`onAppear` and SwiftUI body evaluation are not treated as render completion. The
probe invalidates only its transparent sentinel on cached popup reopens, so a
reused screen is measured even without a SwiftUI body update. It does not force extra layout, flush Core Animation, or run a permanent display
link. A display link runs only for a pending interaction and stops after completion
or a five-second timeout. Overlapping interactions, closes, and timeouts are logged
as incomplete and counted separately. Non-mouse/keyboard openings are labeled
`programmatic`; do not mix those into click percentiles.

A lightweight timer additionally records main-runloop delays above 100 ms. These
are scheduling delays, not proof of a particular expensive function. Refresh
entries measure loading plus application of the result, not the subsequent render.
`worker_ms` separates background loading and `apply_ms` measures the brief MainActor
application step; total time may also include executor scheduling delays.

## Read the results

Logs: `~/Library/Logs/LLMCostBar/performance.jsonl`, with two rotated backups.
Each file is approximately capped at 1 MiB. Logs contain operation names, timings,
version/build, session UUID, and app uptime; they contain no account names, spend,
API keys, cookies, or response bodies. Logging uses a utility queue.

```sh
python3 scripts/performance_report.py
python3 scripts/performance_report.py --session SESSION_UUID
```

The report shows sample count, median (p50), p95, maximum, and incomplete counts.
Compare the same action, input type, measurement endpoint, and display configuration.
For test isolation, `LLMCOSTBAR_PERFORMANCE_LOG_DIR` overrides the log folder.

## Local comparison

1. Use a Release build with the existing Developer ID signature. Keep the same
   accounts, default tab, expanded vendors, display, and power settings.
2. Record the first popup open separately. Then open/close ten times and switch
   between API Spend and Subscriptions ten times, allowing each screen to finish.
3. Repeat Settings tab changes. Leave the popup open through several refreshes
   and try interactions while a refresh runs.
4. Compare median and p95; aim for p95 below 100 ms after mouse release for warmed interactions.
   Keep the full mouse-down-to-render number too, and examine button hold time.
   Ten samples are only a smoke test; use at least 30 for a more useful p95.
5. Repeat after hours/days of uptime. A fresh restart alone can improve behavior;
   short-run measurements do not prove the reported long-running slowdown is fixed.

For this investigation, the original installed bundle is backed up in
`build/performance-original/LLM Cost Bar.app`. An instrumented version of the
original code is retained in `build/performance-baseline/LLM Cost Bar.app` with
its isolated sources under `build/performance-baseline-source`. The optimized
bundle is retained under `build/performance-improved/LLM Cost Bar.app`. Local
bundles are stamped with `PerformanceBuild` so their logs can be distinguished.
None of these artifacts is a published release.

## Regression checks

```sh
cd Core && swift test
# From repository root:
xcodegen generate
xcodebuild -scheme LLMCostBar -destination 'platform=macOS' test
xcodebuild -scheme LLMCostBar -configuration Release build
```

The app-model tests are hostless and use temporary databases/configuration. They
verify that a blocked database doesn't block MainActor, unchanged refreshes don't
invalidate the dashboard, rapid configuration edits persist the latest value,
an old refresh cannot undo a setting, and a failed refresh preserves cached data.
Core tests cover UTC rollover, live-spend chart values, and weekly window selection.

## Initial validation (2026-09-05)

- Core: 208 tests passed. App-model: 6 tests passed. Release build passed.
- Same copied user database, Release code, 5 warm-ups followed by 50 refreshes:

  | Data preparation only | Median | p95 |
  | --- | ---: | ---: |
  | Original refresh queries | 6.56 ms | 7.25 ms |
  | New snapshot (including prepared charts) | 5.31 ms | 5.79 ms |

  This is roughly 19% less data-preparation time. It is **not click latency**;
  moving that work off MainActor and reducing view invalidations is the main UI
  change. No before/after click percentile is claimed until real clicks are logged.
- A pre-restart stack sample was saved to
  `/tmp/llmcostbar-performance-before.txt`; the original process had 33 days of
  uptime. A local restart changes that condition, so longer-term testing remains
  necessary.

The installed `responsive-v2` build produced real mouse-event samples in session
`34E346B0-4E43-4DAF-8EED-5F0FCEFB9663`. Early popup/tab samples were roughly
145–161 ms, with a 266 ms first menu-open sample. This is a small smoke-test sample,
not a statistically meaningful p95 or a before/after comparison. In six refreshes,
the MainActor application step was 0.04–0.21 ms (0.04–0.11 ms after startup).
The click-to-display proxy remains above the 100 ms target in these early samples;
use the logs and user feedback to guide the next pass rather than claiming the
remaining delay is solved. Mouse-up fields appear only when that event is observed
before measurement completion; AppKit tracking/early activation can omit them.
