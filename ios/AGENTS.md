# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Conduit is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`)

The Conduit app target ships **iPhone-only** — `TARGETED_DEVICE_FAMILY` is `1` (not the Universal
`"1,2"`) in both Debug and Release configs in `Conduit.xcodeproj/project.pbxproj`. This is
deliberate: an iPhone-only app doesn't require 13-inch iPad screenshots in App Store Connect and
avoids iPad-specific App Review scrutiny. The dead `UISupportedInterfaceOrientations~ipad` key was
removed from `Info.plist`. Keep the app target at `1` unless we intentionally add iPad support.

## Export compliance is auto-declared (`ITSAppUsesNonExemptEncryption = false`)

`Info.plist` sets `ITSAppUsesNonExemptEncryption` to `false` — Conduit uses only standard
HTTPS/TLS (the `URLSession` webhook upload) and Keychain storage, both **exempt** encryption, and
bundles no custom/proprietary crypto. This auto-declares "no non-exempt encryption," so every
uploaded build is immediately submittable without the per-build export-compliance prompt. Keep it
`false` unless genuinely non-exempt cryptography is added.

## "Last synced" is stamped on the shared completion path (`sync_state`), NOT inferred from `delivery_log`

The Home screen's "Synced X ago" comes from a dedicated single-row `sync_state` table
(migration `v5-sync-state`, `SyncStateDAO`), stamped with the time of the last **successful
sync**. Do NOT go back to inferring "last synced" purely from `DeliveryLogDAO.latest()`: a
`delivery_log` row is written only when a batch is actually delivered, so a "Sync Now" that finds
nothing to upload (empty-but-successful) never advanced the timestamp — the original bug (queue
drains / nothing fails, but the label stays stale).

The stamp lives on the **shared** path so every trigger (manual "Sync Now", HealthKit observer
wake, background `BGAppRefreshTask`) updates it consistently:
- `Uploader.commitSent` (`Services/Networking/Uploader.swift`) stamps `SyncStateDAO.setLastSyncedAt`
  on every 2xx delivery, in the same write transaction as the `delivery_log` row (so the queue
  actually drained = synced). This fires for an all-deduped 200 too — a successful sync that wrote
  0 new docs still counts as synced.
- `SyncEngine.flush` (`Services/Sync/SyncEngine.swift`) stamps on the empty branch (`buildBatch`
  returned nil) **only when there are no pending rows** — a clean, up-to-date outbox. If pending
  rows exist but are all in backoff, there IS undelivered data, so it does not claim a fresh sync.

`HomeViewModel` (`ViewModels/HomeViewModel.swift`): `deriveStatus(lastSynced:latestDelivery:)` is
the pure status resolver (a fresh delivery failure newer than the last success shows `.error`,
else the `sync_state` stamp wins, else back-fill from a successful `delivery_log` entry for
installs predating v5, else `.idle`). The Home `ValueObservation` now also tracks `sync_state` +
`delivery_log`, so the label updates **reactively** the moment a background upload lands or an
empty flush stamps — not only on the 10 s poll timer. The transient "a Sync Now is running" state
is a separate stored `isSyncing` bool (no longer a `SyncStatus.syncing` enum case) so an in-flight
completion can update `syncStatus` without the two fighting. Tests: `SyncStateTests` (DAO +
commitSent stamp + `deriveStatus` branches, incl. empty-but-successful), `DatabaseMigrationTests`
(`sync_state` table/columns).

## Screen snapshot tests — record baselines ON CI, never locally

Image-snapshot coverage for the five primary screens lives in
`ConduitTests/ScreenSnapshotTests.swift` (+ `SnapshotSupport.swift`), using
**pointfree's swift-snapshot-testing** (`SnapshotTesting` product, pinned via SPM; linked to the
`ConduitTests` target only). Each screen is captured across a 2×2 matrix — {light, dark} ×
{default (`.large`), large (`.accessibilityExtraExtraExtraLarge`) Dynamic Type} = **20 reference
PNGs** under `ConduitTests/__Snapshots__/ScreenSnapshotTests/`. The five screens: Onboarding
Welcome (`WelcomeStepView`), HealthKit permission (`HKPermissionStepView`), Home (`HomeView`),
Settings (`SettingsView`), Activity (`ActivityLogView`).

## App Store marketing screenshots — generated, one command

App Store Connect screenshots are **generated, not hand-taken**, by a single gated
XCTest: `ConduitTests/AppStoreScreenshotTests.swift`. Output (committed): 20 PNGs under
`conduit/ios/docs/appstore-screenshots/<device>/<light|dark>/<n>-<screen>.png` — the 5
marketing screens (home, activity, settings, healthkit-permission, welcome) × two Apple-required
iPhone sizes (**6.9″ 1320×2868 required**, **6.5″ 1284×2778 accepted fallback**) × light/dark.
See `docs/appstore-screenshots/README.md`.

Regenerate (any booted iPhone sim works — the generator forces each screen's exact
point-size × scale-3 off-screen, so the destination device doesn't change output pixels):
```
cd conduit/ios
TEST_RUNNER_GENERATE_APPSTORE_SCREENSHOTS=1 xcodebuild test \
  -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' \
  -only-testing:ConduitTests/AppStoreScreenshotTests CODE_SIGNING_ALLOWED=NO
```
The `TEST_RUNNER_` prefix is **required** — `xcodebuild` only forwards host env vars into the
simulator test process when prefixed with it (stripped inside → test reads
`GENERATE_APPSTORE_SCREENSHOTS`). Without the var the test **`XCTSkip`s instantly**, so the normal
`conduit-ios` gate (whole `ConduitTests` bundle) is never slowed. This is deliberately a *renderer*
(reuses `SnapshotSupport` hosting over an in-memory seeded `AppState`), NOT a live-app XCUITest —
Conduit gates Home behind onboarding + a HealthKit auth dialog a headless UITest can't script.
Images aren't pixel-diffed against a baseline, so rendering on a newer local iOS is fine (unlike
`ScreenSnapshotTests`). Uploading to App Store Connect is owner-only; this tool only produces images.

## App Store upload — `fastlane deliver` (screenshots-only, never submits)

The committed marketing screenshots are uploaded to App Store Connect via `deliver`
(`conduit/ios/fastlane/`, `Gemfile`). One command (the captain exports an **App Store Connect API
key** at runtime — nothing is committed):
```
cd conduit/ios && bundle install   # first time
ASC_API_KEY_ID=… ASC_API_ISSUER_ID=… ASC_API_KEY_PATH=/abs/AuthKey_….p8 \
  bundle exec fastlane ios upload_screenshots
```
Required env vars: `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_PATH` (path to the `.p8`).
Optional `CONDUIT_SCREENSHOT_APPEARANCE` = `light` (default) | `dark` — ASC has one screenshot slot
set per device size, so **one** appearance uploads; light is the committed default.

Lanes (`Fastfile`): `upload_screenshots` (prepare + upload), `prepare_screenshots` (arrange PNGs
only, no network), `upload_metadata` / `download_metadata` (text metadata, opt-in). **Safety
contract (do not weaken):** every lane sets `skip_binary_upload true`, `submit_for_review false`,
`automatic_release false`, `run_precheck_before_submit false` (`Deliverfile`) — it **only stages
marketing assets, never touches the binary, and NEVER submits for review**; a human submits from
ASC. `upload_screenshots` is screenshots-only (`skip_metadata true`) so it can't clobber listing
text; `overwrite_screenshots true` makes re-runs idempotent. There is deliberately no `--submit`.

`prepare_screenshots` copies `docs/appstore-screenshots/<device>/<appearance>/*.png` into
`fastlane/screenshots/en-US/` with per-device filename prefixes (`iphone69_…`/`iphone65_…`) —
`deliver` maps each PNG to its App Store display size **by pixel resolution** (1320×2868 → 6.9″,
1284×2778 → 6.5″), so both sizes upload from one run and folder naming is irrelevant. That dir (and
`fastlane/metadata/`) is **derived + gitignored**; the committed PNGs stay the single source of
truth. **Never commit a `.p8`** — `.gitignore` excludes `*.p8`/`AuthKey_*.p8`. Missing env vars fail
the lane fast before any network call. Full docs: `conduit/ios/fastlane/README.md`. fastlane isn't
in CI — validate config with `ruby -c fastlane/Fastfile` (+ Appfile/Deliverfile) or `bundle exec
fastlane lanes`.

## Screen snapshot tests — record baselines ON CI, never locally

**Baselines are recorded on the CI simulator, NOT on a dev machine.** The `conduit-ios` job
(`.github/workflows/ci-gate.yml`) provisions the newest iOS runtime on an **iPhone 16** simulator;
a dev Mac's Xcode renders a different iOS version (e.g. iOS 26 vs CI's iOS 18) and its PNGs will
**not** match CI — the mismatch is far larger than the `precision`/`perceptualPrecision` tolerance.
Workflow to (re)generate: push with the references deleted/changed → the first CI run records the
missing PNGs into the workspace and fails the snapshot assertions → the **"Upload snapshot
references/diffs"** artifact step (`if: always()`) uploads `__Snapshots__/**` → download that
artifact, commit the PNGs → the next CI run compares and goes green. Force a full local re-record
with `SNAPSHOT_RECORD=1` (sets `record: .all`); default is compare-only (records only missing).

**Sharp edges in the host harness (`SnapshotSupport.hostForSnapshot`):**
- The screens build their view model lazily in `.onAppear` (showing a `ProgressView` on the very
  first frame), so the view must be hosted in a **real key `UIWindow`** and the **main run loop
  pumped** (~1.2 s) before capture — otherwise you snapshot the spinner. `makeSnapshotAppState()`
  gives an in-memory `AppDatabase`; no screen touches live HealthKit/network on render.
- **Dark mode**: set the window's (and hosting controller's) **`overrideUserInterfaceStyle`** — a
  `traitOverrides.userInterfaceStyle` is NOT honored for a window's rendered appearance (it only
  leaks into SwiftUI's color scheme → a half-dark render: white text on white List cells). Dynamic
  Type, conversely, DOES go through `traitOverrides.preferredContentSizeCategory`.
- Capture with **`.image(drawHierarchyInKeyWindow: true)`** (live framebuffer). A plain
  `layer.render` left SwiftUI text and UIKit-backed List cell backgrounds on mismatched
  appearances.
- **Determinism**: chosen states avoid wall-clock/locale/time-zone-dependent output — Home is the
  clean idle state ("No syncs yet", zeroed counts; its data-populated variant depends on an inner
  `onAppear` load the static host doesn't pump), Activity is its empty state (no dated rows),
  Settings is seeded (`SnapshotFixtures.seedSettings`) because it loads in its **outer** `onAppear`.
  `setUp` clears any keychain webhook token so `hasToken` is stable.
