# Conduit — iOS app

Conduit streams Apple HealthKit data from an iOS device to a user-configured
webhook over HTTPS. The user controls where their data goes; the app stores
nothing in the cloud.

This directory contains the full app: onboarding, Home, Settings, Activity Log,
and the HealthKit permissions detail screen, built on top of the HealthKit
sync engine and SQLite outbox — plus a sync-status-only Lock Screen widget.

## Requirements

- Xcode 15 or later
- iOS 17.0+ deployment target
- An Apple Developer team for signing (project is configured for team
  `3K72BT899D`)

## Project layout

```
ios/
├── Conduit.xcodeproj
├── Conduit/
│   ├── App/             ConduitApp, AppDelegate, AppState (shared observable
│   │                    singleton: database, sync engine, onboarding flag),
│   │                    entitlements
│   ├── Models/
│   │   ├── Generated/   protoc output (sync.pb.swift — regenerate with
│   │   │                scripts/generate-swift-proto.sh)
│   │   ├── WebhookConfig.swift, DataTypeConfig.swift, OutboxRow.swift
│   │   └── DeliveryLogEntry.swift
│   ├── Services/
│   │   ├── HealthKit/   HealthTypeRegistry, HealthKitAuthorizer,
│   │   │                ObserverCoordinator, AnchoredReader,
│   │   │                WorkoutRouteReader (GPS routes),
│   │   │                HistoryAccessProbe (iOS 27 limited-history floors)
│   │   ├── Sync/        SyncEngine, Throttle, Batcher
│   │   ├── Networking/  Uploader, BackgroundSession, BackoffPolicy,
│   │   │                WebhookTester (foreground Test Connection probe)
│   │   ├── Storage/     Database (GRDB) + DAOs, incl. DeliveryLogDAO
│   │   └── Security/    KeychainStore (bearer token + device_id)
│   ├── ViewModels/      One per screen (Home, Onboarding, Settings, ActivityLog)
│   ├── Views/
│   │   ├── Onboarding/  Welcome → Webhook setup → Data Type picker → HK
│   │   │                permission trigger
│   │   ├── Home/        Status line, sample counts, Sync Now
│   │   ├── Settings/    Webhook/Sync/Data Types/About + HK permissions detail
│   │   ├── Activity/    Reverse-chrono delivery log + batch detail
│   │   └── Shared/      MaskedTokenField, WebhookTestView
│   ├── Assets.xcassets
│   └── Info.plist
├── ConduitShared/       ConduitStatusSnapshot (App Group transport type,
│                        compiled into both Conduit and ConduitWidgets)
├── ConduitWidgets/      Lock Screen sync-status widget extension
└── ConduitTests/
```

## Supported recovery data

Version 1.9 adds the four recovery types below. The full supported type list is
defined in [`HealthTypeRegistry.swift`](Conduit/Services/HealthKit/HealthTypeRegistry.swift).
Recovery additions travel as ordinary quantity samples with their own identifier,
source and timestamps; Conduit exports raw readings without diagnosis or scoring.

| Type | Canonical wire unit | Minimum iOS | Recording requirements |
| --- | --- | --- | --- |
| Heart Rate Variability (RMSSD) | `ms` | 27 | Requires a compatible HealthKit writer; API availability alone does not guarantee samples. Separate from the existing SDNN type. |
| Sleeping Wrist Temperature | `degC` | 16 (app requires 17) | [Apple Watch Series 8+, Ultra, or SE 3](https://support.apple.com/en-us/102674), with sleep tracking and Sleep Focus configured. Separate from Body Temperature. |
| Sleeping Breathing Disturbances | `count` | 18 | [Apple Watch Series 9+, Ultra 2+, or SE 3](https://support.apple.com/en-us/120031) with sleep tracking; these are raw measurements, not a sleep-apnea notification or diagnosis. |
| Time in Daylight | `min` | 17 | [Apple Watch SE, Series 6+, or Ultra](https://support.apple.com/en-us/119065) with watchOS 10+ uses its ambient light sensor; no supporting writer means no samples. |

Sleeping wrist temperature is the absolute HealthKit temperature, not the deviation
from baseline shown in Health ([Apple’s API documentation](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applesleepingwristtemperature)).

Identifiers unavailable on the running OS are skipped for HealthKit authorization,
observation, reading and permission warnings. On upgrade, all four new Conduit
toggles default **on**, existing choices remain intact, and the grown available
read set triggers one HealthKit authorization request. Users still control
HealthKit read permission and can turn each type off in Conduit. A subsequent OS
upgrade that makes another type available grows the authorization set and triggers
another request. This follows
the athlete-metrics precedent; sensitive-category expansion would need a separate
consent/default-off decision and is outside this batch.

## Dependencies (Swift Package Manager)

Declared in the project; Xcode resolves them on first open / build:

- [`apple/swift-protobuf`](https://github.com/apple/swift-protobuf) — proto3
  models + canonical JSON serialization (used by the committed `sync.pb.swift`).
- [`groue/GRDB.swift`](https://github.com/groue/GRDB.swift) — SQLite outbox
  and delivery log storage, single shared connection owned by `AppState`.

## Regenerating the proto models

`Conduit/Models/Generated/sync.pb.swift` is committed, generated output — it's
not hand-edited. If [`../proto/conduit/v1/sync.proto`](../proto/conduit/v1/sync.proto)
changes, regenerate it with:

```bash
ios/scripts/generate-swift-proto.sh
```

See that script's header comment for the required `protoc`/`protoc-gen-swift`
versions.

## Open, build, run

```bash
# Open in Xcode
open ios/Conduit.xcodeproj

# Build for the simulator from the command line
xcodebuild \
  -project ios/Conduit.xcodeproj \
  -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  build

# Run the unit tests
xcodebuild \
  -project ios/Conduit.xcodeproj \
  -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test
```

In Xcode: select the **Conduit** scheme and an iPhone 15 simulator, then
Run (⌘R). First launch walks through onboarding (webhook setup, data type
selection, HealthKit permission prompt); subsequent launches open directly to
Home.

## Signing

The project uses automatic signing. To build to a device or archive, select
your team in **Signing & Capabilities**, or override `DEVELOPMENT_TEAM` on the
command line. The bundle identifier is `dev.noebrito.Conduit`.

## Capabilities

- HealthKit + HealthKit background delivery (`Conduit/App/Conduit.entitlements`)
- App Groups: `group.dev.noebrito.Conduit`, on both the app and the widget
  extension (`ConduitWidgets/ConduitWidgets.entitlements`) — carries the
  sync-status snapshot the Lock Screen widget reads
- Background Modes: `fetch`, `processing` (`Conduit/Info.plist`)
- `NSHealthShareUsageDescription` — the shipped reason string; it names the data
  Conduit reads (App Review reads it, so keep it honest and specific)
- `BGTaskSchedulerPermittedIdentifiers` — `dev.noebrito.Conduit.flush` (upload drain,
  `BGAppRefreshTask`) and `dev.noebrito.Conduit.import` (history-import resumption,
  `BGProcessingTask`)

## Continuous integration

`ci_scripts/ci_post_clone.sh` stamps `CURRENT_PROJECT_VERSION` with the Xcode
Cloud build number so each TestFlight upload has a unique, increasing build
number.

## App Store reviews

Automatic reviews use SwiftUI's native `requestReview` on iOS 17+, owned by a
single `AppState.reviewPrompt` coordinator. Eligibility starts prospectively at
the first 10-second uninterrupted visit to settled, visible Home with a recent
nonempty successful delivery. Each counted visit needs a delivery newer than the
previous counted delivery. It requires three local Gregorian days (at least 20
elapsed hours apart) and 14 elapsed days of tenure. After 30 continuous
foreground seconds, a cancellable two-second pause and a fresh readiness read
precede the request. Setup, permission, configuration, import and troubleshooting
sessions are suppressed until a true background/foreground transition. These
intervals are product defaults, not Apple requirements or measured optima.

One local UserDefaults record holds the bounded current-cycle day keys, delivery
watermark, and attempt/version history; onboarding, configuration and queue resets
do not clear it. Attempts require 180 elapsed days, three new qualifying days and
an unrequested marketing version thereafter. The coordinator persists an attempt
before calling StoreKit, including when StoreKit silently declines to display it;
there is no displayed/submitted/rating callback, inferred outcome, analytics or
Keychain review identity. Clock anomalies, corrupt state and missing versions
defer requests. A clock change across a terminated process cannot be independently
verified without an external time source; future stored timestamps still defer.

Settings → About always offers the explicit App Store write-review link and a
clearly identified public GitHub Help & Feedback link, with no automatic data
attachments. See Apple's [RequestReviewAction documentation](https://developer.apple.com/documentation/storekit/requestreviewaction):
development rendering and TestFlight behavior do not establish production prompt
display or review submission.

`ReviewEligibilityTests`, `ReviewPromptCoordinatorTests`, `ReviewReadinessTests`
and `ReviewLinkTests` exercise the policy, persistence, injected lifecycle and
transactional evidence. `ReviewSettingsEvidenceTests` captures Settings from an
empty fixture in a real simulator window when `TEST_RUNNER_CONDUIT_EVIDENCE_DIR`
is passed to `xcodebuild test`; point it outside the repository. This is a rendering
check; physical-device StoreKit presentation and end-to-end link opening remain
unverified.

## Shortcuts — Sync Health Data

After setup, add **Conduit → Sync Health Data** in Apple's Shortcuts app, or use
Conduit's provided **Sync Health Data** app shortcut. It uses only the existing
destination, token and enabled types; it does not request new permissions.
The action requires local device authentication and checks protected-data
availability before opening the database. HealthKit reads may be unavailable
while locked: unlock the iPhone and retry. A lock during capture is reported as
partial progress, preserving data already queued. An empty HealthKit read does
not prove that no samples exist or that read permission was granted.

Each run captures one incremental page (up to 200 objects) per enabled type,
with the normal first-read start-of-today floor and atomic enqueue/anchor update.
Routes use a deduplicated scan of up to 10 recent workouts. Capture stops between
reads/workouts on cancellation or after a 20-second cooperative budget; an
in-progress HealthKit query can exceed that budget. Outbox capacity still applies.
More data may remain; the existing observer/import paths continue normally.

The result distinguishes samples captured, new samples queued, deletions
processed, and samples **submitted for background upload**. Submission may
include older queued data. It does **not** wait for or claim receiver acceptance;
check Activity Log for the actual delivery result. It flushes one batch, respecting
existing backoff and batch-size limits. Cancellation retains committed pages and
skips starting a new upload. There is no new background scheduler or relay.

Local simulator and injected tests do not verify appearance/execution inside the
native Shortcuts app, Siri, physical-device locked-data behavior, cancellation by
Shortcuts/iOS, or large-queue behavior.
Validate those on an iPhone before an App Store release.
