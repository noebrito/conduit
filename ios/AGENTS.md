# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## iOS 27 "limited history" — per-type HealthKit access floors, detected via `HistoryAccessProbing`

iOS 27 added a two-stage choice to the HealthKit read-authorization sheet: alongside Allow/Don't
Allow, the user can grant "Past 30 Days and Future Data" instead of "All Recorded Data and Future
Data". A read entirely outside that window returns an **empty page with `error == nil`** —
indistinguishable, to `HistoryImporter`'s paging loop, from "the user has no older data" — so
without this feature an "All time" import under a 30-day grant silently staged only the in-range
samples while still recording `status = completed, isSuccess = true` (identical in every persisted
field to a genuinely complete import).

`HistoryAccessProbing`/`HealthKitHistoryAccessProbe` (`Services/HealthKit/HistoryAccessProbe.swift`)
wraps `HKHealthStore.earliestAuthorizedSampleDate(for:)` and returns `HistoryAccessFloors`:
`.resolved(floors)` or `.unresolved`. **`.resolved([:])` and `.unresolved` are different facts** —
the first says iOS confirmed full access (also the pre-iOS-27 answer, and the answer for an empty
type list), the second says the probe failed and nothing is confirmed. Collapsing the failure into
an empty floors dictionary is what re-creates the original bug, so a run whose probe is
`.unresolved` is never allowed to reach `.completed`/`isSuccess` (see `ImportRunner.execute`); it
stays `.interrupted` and a Resume re-probes. The pure static `floors(for:from:)` mapping takes the
**latest** (most restrictive) floor among a Conduit type's constituent HealthKit types — a composite
type like blood pressure is only fully readable where EVERY constituent is — and is unit-tested with
no live store (`HistoryAccessProbeTests`).

**Detection is per data type, never a single app-wide flag** — a grant can be limited for one type
while another keeps full access (§6.6 of the originating scout report,
`data/conduit-ios27-limited-history-scout/report.md` in the firstmate home, if still retained).

`ImportRunner.execute` probes **after** the per-type loop finishes, not inline during it — inline
would work only by accident: the loop `break`s the run entirely the first time ANY type ends up
`.interrupted` (correct for a cancellation or a stuck outbox, both of which really do stop the whole
run), and a history-access floor must NOT do that, since another type's grant may still be full. The
post-loop pass (`downgradeTypesThatReachedTheirFloor`) re-probes fresh (the grant can change mid-run)
and flips any wrongly-`.completed` type back to `.interrupted`, which also makes a later Resume
actually revisit it. The result reuses the existing `stopCause` machinery (a new `.historyLimited`
case) rather than a new top-level `ImportRunStatus` — `.interrupted` is already resumable and already
not styled as success, so no exhaustive switch needed a new case. `autoResume` stays `false` for this
cause (same reasoning as `queueNotDraining`): auto-resuming would re-read the same unreadable window
on every foreground until the user manually widens access in Settings. An explicit Resume deliberately
has **no** pre-flight "still limited?" check — it just runs `execute`, whose post-loop probe re-parks
the run on `.historyLimited` after one cheap empty read per limited type. A pre-flight short-circuit
looks like a free optimization but silently skipped types the user enabled after the run parked,
whose readable in-window history then never staged at all.

The floor is persisted as `import_run.history_floor` (migration `v11-import-history-floor`, additive
in the same shape as v8/v9/v10 — see the migration comments in `Database.swift`).

UI: `SettingsView`'s range picker **annotates** presets (a footer line) rather than
hiding/disabling any of them, including "All time" — a mixed per-type grant makes a global
hide/disable wrong. Only the *custom* date picker's lower bound clamps, and only when
`SettingsViewModel.commonHistoryAccessFloor` finds every enabled type sharing the exact same floor.
Settings is the only screen that carries this annotation, deliberately: onboarding's
data-type-picker step runs BEFORE the HealthKit permission step, so there is no grant to probe there
and a second copy of the rule would be dead code drifting out of sync with this one.

## Workout enrichment capture (brand/indoor/HR stats/events) — `HKStatistics` cannot be constructed in a unit test

`AnchoredReader`'s `.workout` case maps `HKWorkout` into the enriched `WorkoutValue` (the matching
server-side mapping already shipped in the private monorepo that owns the ingester). It follows the
same split `WorkoutRouteReader.makeRouteSample`
uses: a thin, HealthKit-touching wrapper (in `case .workout:`) extracts values, and a pure static
core (`AnchoredReader.makeWorkoutValue`) does the presence/absence mapping.

**The split is drawn differently here than in the original design sketch, for a concrete reason:**
`HKStatistics` (`workout.statistics(for:)`, avg/max/min heart rate) has `init` marked
`NS_UNAVAILABLE` and no public factory method — it can genuinely never be constructed outside a live
`HKWorkoutBuilder`/`HKLiveWorkoutBuilder`. So `makeWorkoutValue` takes **plain `Double?`**
(`avgHeartRateBpm`/`maxHeartRateBpm`/`minHeartRateBpm`), already extracted by the thin wrapper, not
an `HKStatistics?`. That is what makes the presence/absence branching (the part with actual
behavior) fully unit-testable with real numbers; an `HKStatistics?`-typed parameter would leave the
"present" branch permanently untestable no matter where the split falls. `HKWorkoutEvent`s, by
contrast, genuinely can be constructed in a test (the deprecated
`HKWorkout(activityType:start:end:workoutEvents:totalEnergyBurned:totalDistance:metadata:)`
initializer and `HKWorkoutEvent(type:dateInterval:metadata:)` both work on an iOS 17 target,
deprecation warning only), so `makeWorkoutValue` takes real `[HKWorkoutEvent]`.

**Privacy gate:** `SyncEngine.includeHeartRateStatisticsForWorkouts()` resolves whether
avg/max/min HR may be sent, from the user's own Heart Rate data-type toggle (`DataTypeConfigDAO`) —
turning Heart Rate off suppresses these fields in the workout payload even though Workouts stays on.
The public privacy policy (`conduit/api/internal/handler/privacy.html`, served at
`https://health.noebrito.dev/privacy`) now promises exactly that, so the gate is a published,
App-Review-facing contract — deleting it makes that copy false, not just less cautious.
Threaded through `AnchoredReader.read`/`readImportPage`/`makeSample` as `includeHeartRateStatistics`
(default `true`, so every pre-existing call site — routes, running dynamics, correlation tests — is
unaffected). Any future workout-payload field with the same "derived from a toggleable type" shape
should reuse this exact gate-resolution pattern rather than inventing a new one.

**Still unverified on a real device:** whether `HKWorkoutBuilder`-recorded Apple Watch workouts
actually populate `statistics(for:)` (no Apple Watch was available while implementing this).
`WorkoutEnrichmentEvidenceTests` proves the mapping end-to-end, but its workout is built via the
deprecated initializer, which never carries statistics — so it can only assert their honest
*absence*, not prove presence on a real workout. Do this device check before shipping a
TestFlight/App Store build that emits these fields.

## GPS routes are the one type NOT read by `AnchoredReader` — and they need no location permission

`HKWorkoutRouteTypeIdentifier` (`HealthStream.route`) is registered like any other type, but it is
the only one the generic anchored read cannot produce: a route is a **two-step async read** (find a
workout's route objects, then stream `CLLocation` batches until `done`), so `WorkoutRouteReader`
owns it and `AnchoredReader.makeSample` returns nil for `.route`. `ObserverCoordinator` registers
**no** observer for it — HealthKit associates only forward (workout → route, no reverse lookup), so
capture rides the **workout** wake: `SyncEngine.captureRecentRoutes` re-scans workouts from the last
`WorkoutRouteReader.rescanWindowDays` on each wake, because Apple attaches a route **shortly after**
its workout ends and the first wake usually predates it. That re-scan is safe only because routes
stage via `stageImport` (never advances an anchor — routes have none) and the outbox's UNIQUE
`hk_sample_uuid` dedupes a re-read route to a no-op. Only definitive captures are memoized
(`workoutsWithCapturedRoute`, in-memory); a routeless workout is deliberately re-attempted, which is
what catches a late-finalized route. **No route is the common case** (indoor/manual/GPS-off) — stage
nothing, no error. History import routes through the same reader (`SyncEngine.importRoutes`, driven
by the enabled-registry loop in `ImportRunner`, so routes checkpoint and resume like every other
type). A route read that fails for ONE workout is still skipped and logged, but an error from the
workout scan or from staging propagates so the run is recorded as failed, not silently short.

**Privacy (do not regress):** reading a *stored* route needs the HealthKit read auth for
`HKSeriesType.workoutRoute()` and **nothing else** — no CoreLocation permission, no
`NSLocation*UsageDescription`, no new entitlement. Never put the route type in a `toShare` set.

**Downsampling** (`WorkoutRouteReader.downsample`) bounds a route to `pointBudget` so one route = one
document under the 16 MiB body cap: at/under budget it is sent **verbatim**, above it Douglas–Peucker
(~5 m, shape-preserving) then stride-decimation, always keeping the endpoints. ⚠️ The wire
`RouteValue` carries only `{workout_uuid, activity_type, points}` — the ingester **derives**
`point_count`/`distance_m` from the points it receives (`ingester/ingest/indexer.go` `buildRoute`),
so for a simplified route those reflect the drawn path, not the raw series. **This is accepted by
design — do not "fix" it by adding true_point_count/true_distance_m proto fields.** The workout's own
`total_distance_m` is the authoritative headline distance (that is what a map should render), and the
drawn path's point count is not a user-facing metric, so the ≤1% distance imprecision a simplified
route introduces is immaterial. Pinned by `testSimplifiedRouteKeepsItsDistance`.

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

## `MARKETING_VERSION` must lead the released App Store version, or every Archive fails

Xcode Cloud's **Archive - iOS** action ends in "Prepare build for App Store Connect", which uploads
the archive — and App Store Connect **rejects a build whose `CFBundleShortVersionString` is not
higher than the version already approved/released**. So the moment a version goes live, every
subsequent Xcode Cloud archive fails with the opaque `Preparing build for App Store Connect failed`
(one error, no annotations, no compiler diagnostic) while **Build - iOS and Test - iOS stay green** —
the code is fine; only the upload is refused. `ci_scripts/ci_post_clone.sh` only stamps
`CURRENT_PROJECT_VERSION` from `$CI_BUILD_NUMBER`, so the build number is never the problem;
`MARKETING_VERSION` is hand-managed in `Conduit.xcodeproj/project.pbxproj` (4 occurrences — app +
test target, Debug + Release; keep them equal).

**A manual archive is not an escape hatch** — the refusal comes from App Store Connect, not Xcode
Cloud, so an Organizer/Transporter upload of the same version is rejected too, just with the reason
spelled out: `ITMS-90062` (`CFBundleShortVersionString` must exceed the approved version) and
`ITMS-90186` (that version's pre-release train is **closed**, so no further build — TestFlight
included — is accepted at that number). Treat either signature as the same problem.

**So: bump `MARKETING_VERSION` as soon as the previous one is released, not at submission time.**
Confirm what is actually live with
`curl -s "https://itunes.apple.com/lookup?id=6786544769&country=us"` (`.results[0].version`) — that
public lookup needs no App Store Connect credentials and is the fastest way to tell this failure
apart from a real build break.

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
  returned nil) only when `SyncEngine.outboxIsFullyDrained` reports **both** zero pending rows
  **and** zero `.inflight` rows — a clean, up-to-date outbox. If pending rows exist but are all in
  backoff, or a batch is still (or stuck) `.inflight`, there IS undelivered data, so it does not
  claim a fresh sync. See "Stuck `.inflight` outbox rows" below for why the inflight half of this
  check was added.

`HomeViewModel` (`ViewModels/HomeViewModel.swift`): `deriveStatus(lastSynced:latestDelivery:)` is
the pure status resolver (a fresh delivery failure newer than the last success shows `.error`,
else the `sync_state` stamp wins, else back-fill from a successful `delivery_log` entry for
installs predating v5, else `.idle`). The Home `ValueObservation` now also tracks `sync_state` +
`delivery_log`, so the label updates **reactively** the moment a background upload lands or an
empty flush stamps; the relative-time wording itself is ticked forward by a `HomeView`
`TimelineView`, not a DB-reading poll timer (the old 10 s status-refresh `Timer` was removed as
pure duplication of the observation). The transient "a Sync Now is running" state
is a separate stored `isSyncing` bool (no longer a `SyncStatus.syncing` enum case) so an in-flight
completion can update `syncStatus` without the two fighting. Tests: `SyncStateTests` (DAO +
commitSent stamp + `deriveStatus` branches, incl. empty-but-successful), `DatabaseMigrationTests`
(`sync_state` table/columns).

## Stuck `.inflight` outbox rows — two reconciliation mechanisms, not one

`Uploader.reconcileInflight` resets `.inflight` rows back to `.pending`
**only when the background `URLSession` no longer reports their batch as active**, and it runs
**only once, at app cold launch** — it was designed as crash recovery ("a single crash can
permanently strand samples"). A 2026-08-11 home-internet/power outage exposed the gap that leaves:
a batch's background upload can go silently quiet mid-request (the destination drops off the
network for hours) while the **app process never dies** — nothing about that kind of outage
kills/relaunches a foreground/backgrounded phone app — so launch-time reconciliation never re-runs,
and no other code path ever reconsiders that batch. It stays `.inflight` forever: `Batcher.buildBatch`
only ever drains `.pending` rows, so the stuck batch is invisible to every future flush, including a
manually-tapped "Sync Now". A second bug masked the symptom: `SyncEngine.flush`'s empty-batch branch
stamped `sync_state.last_synced_at` by checking only `count(.pending) == 0`, blind to `.inflight`
rows — so the Home screen showed a fresh green "Synced 0 seconds ago" while the stuck batch sat
undelivered, because some *other*, unrelated batch had delivered successfully around the same time.

The fix added a **second, independent, time-based** reclaim: `OutboxDAO.reclaimStaleInflight`
(migration `v10-outbox-inflight-at` adds `outbox.inflight_at`, stamped by `Batcher.buildBatch`) resets
any row that's been `.inflight` longer than `SyncEngine.staleInflightTimeout` (30 min) back to
`.pending`, **independent of whatever the session currently reports** — `reconcileInflight`'s
session-active check and this elapsed-time check catch different failure shapes; keep both.
`SyncEngine.flush` runs this reclaim **before** `Batcher.buildBatch` on every flush (manual, observer
wake, background task, import drain), so a reclaimed row is immediately eligible for that same flush's
batch. Reclaiming a row that turns out to still be genuinely in flight is safe: the ingester indexes by
`sample.uuid` with `op_type: create` (`conduit/ingester/ingest/indexer.go`), so a redundant delivery
409s and dedupes rather than duplicating — the same idempotency `reconcileInflight` already relies on.
The masking bug is fixed by `SyncEngine.outboxIsFullyDrained(pendingCount:inflightCount:)` (a pure,
directly-tested helper) — "last synced" may only stamp when **both** are zero.

A row already `.inflight` from before this migration has `inflight_at == NULL`; `reclaimStaleInflight`
treats `NULL` as immediately eligible rather than permanently unreclaimable, the same conservative
direction as every other nullable-timestamp backstop in this codebase.

## Screen snapshot tests — opt-in (the CI that recorded the baselines is gone)

Image-snapshot coverage for the five primary screens lives in
`ConduitTests/ScreenSnapshotTests.swift` (+ `SnapshotSupport.swift`), using
**pointfree's swift-snapshot-testing** (`SnapshotTesting` product, pinned via SPM; linked to the
`ConduitTests` target only). Each screen is captured across a 2×2 matrix — {light, dark} ×
{default (`.large`), large (`.accessibilityExtraExtraExtraLarge`) Dynamic Type} = **20 reference
PNGs** under `ConduitTests/__Snapshots__/ScreenSnapshotTests/`. The five screens: Onboarding
Welcome (`WelcomeStepView`), HealthKit permission (`HKPermissionStepView`), Home (`HomeView`),
Settings (`SettingsView`), Activity (`ActivityLogView`).

**The comparison is opt-in and `XCTSkip`s by default** (`SnapshotEnv.isEnabled`) — see the detailed
section below for why and how to run it.

## App Store marketing screenshots — generated, one command

App Store Connect screenshots are **generated, not hand-taken**, by a single gated
XCTest: `ConduitTests/AppStoreScreenshotTests.swift`. Output (committed): 20 PNGs under
`ios/docs/appstore-screenshots/<device>/<light|dark>/<n>-<screen>.png` — the 5
marketing screens (home, activity, settings, healthkit-permission, welcome) × two Apple-required
iPhone sizes (**6.9″ 1320×2868 required**, **6.5″ 1284×2778 accepted fallback**) × light/dark.
See `docs/appstore-screenshots/README.md`.

Regenerate (any booted iPhone sim works — the generator forces each screen's exact
point-size × scale-3 off-screen, so the destination device doesn't change output pixels):
```
cd ios
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
(`ios/fastlane/`, `Gemfile`). One command (the captain exports an **App Store Connect API
key** at runtime — nothing is committed):
```
cd ios && bundle install   # first time
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
the lane fast before any network call. Full docs: `ios/fastlane/README.md`. fastlane isn't
in CI — validate config with `ruby -c fastlane/Fastfile` (+ Appfile/Deliverfile) or `bundle exec
fastlane lanes`.

## Screen snapshot tests — opt-in (the CI that recorded the baselines is gone)

**The pixel-diff assertions `XCTSkip` unless you opt in.** They are gated on `SnapshotEnv.isEnabled`
(`SNAPSHOT_TESTS=1`, or `SNAPSHOT_RECORD=1` when re-recording) — the same shape as
`AppStoreScreenshotTests`' `GENERATE_APPSTORE_SCREENSHOTS` gate. Under `xcodebuild` the var needs the
`TEST_RUNNER_` prefix to reach the test process:
```
TEST_RUNNER_SNAPSHOT_TESTS=1 xcodebuild test -project ios/Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=<fresh sim>' \
  -only-testing:ConduitTests/ScreenSnapshotTests CODE_SIGNING_ALLOWED=NO
```

**Why the gate exists.** The 20 references were recorded on the `conduit-ios` GitHub Actions
simulator, and that job **no longer exists** — all GitHub Actions macOS CI was deleted for 10x
billing in the private monorepo this app used to live in. A renderer other than the one that
recorded a reference mismatches it wholesale (a different iOS version's rendering differs far more
than the `precision`/`perceptualPrecision` tolerance absorbs), so on **Xcode Cloud** — now the only
CI that runs `ConduitTests` — all five screens failed on *every* commit, including untouched ones
like Welcome. That is a permanently-red gate carrying no signal: it can't distinguish a real layout
regression from the environment, and it drowns the ~133 logic tests it runs beside. Skipping by
default keeps those honest; the images and the suite stay in the repo and still run on demand.

**Re-recording needs a decision, not a local run.** `SNAPSHOT_RECORD=1` (`record: .all`) rewrites the
PNGs *for whatever simulator you run it on* — committing those makes the baselines match your Mac and
nothing else, which is the trap the old "never record locally" rule guarded against. The old
record-on-CI path (push with references deleted → the run records + fails → download the "Upload
snapshot references/diffs" artifact → commit the PNGs) died with the job. Until a recording
environment is re-established (e.g. an Xcode Cloud post-action that exports `__Snapshots__/**`, or a
pinned simulator runtime everyone agrees on), **the baselines are stale by definition** — notably
they predate the v1.1 Nutrition section in Settings — so don't treat a local diff against them as a
regression signal.

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

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
