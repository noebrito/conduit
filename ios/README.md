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
│   │                    SyncHealthIntent (Shortcuts), entitlements
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
│   │   ├── Sync/        SyncEngine, ShortcutSync, Throttle, Batcher
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

## Heart-rate notifications and cycle tracking

High and low heart-rate notifications now carry the threshold the user set in the
Watch app as `category.heartRateEventThresholdBpm` (from
`HKMetadataKeyHeartRateEventThreshold`). It is the threshold, not the measured
rate: the readings behind a notification are the Heart Rate samples inside the
event's window (see [`docs/webhook/PAYLOADS.md`](../docs/webhook/PAYLOADS.md#heart-rate-notifications)).
Irregular rhythm notifications carry no threshold.

Cycle tracking adds a **Cycle Tracking** group with the core set below. Every type
is `isSensitive` in `HealthTypeRegistry`, which means:

- **Off by default**, on fresh onboarding and on upgrade. The upgrade writes a
  disabled row for each new type and never turns one on.
- **Lazy authorization.** Sensitive types are outside the launch-time re-prompt
  signature (`HealthTypeRegistry.defaultReadTypes`), so an update shows no
  "Reproductive Health" sheet. HealthKit is asked when the user turns a type on:
  onboarding's permission step, or Settings → Save Changes, which also starts
  capturing newly enabled types right away.
- **Held back from the one public test endpoint the app recognizes.** While it
  is the destination, sensitive types are not read or staged (their anchors stay
  put, so nothing is lost), rows already staged for another receiver are held in
  the outbox instead of drained to it, and an import of a sensitive type fails
  with the same explanation the app shows in Settings and onboarding. That
  endpoint also drops these types server-side.
  Held rows still count as pending (in the pending count, and they keep "last
  synced" from advancing) until the webhook URL changes.
- The Import History confirmation names each enabled sensitive group (Cycle
  Tracking, [Medications](#medications)).

| Type | `hkTypeId` | Shape | `valueName` or unit |
| --- | --- | --- | --- |
| Menstrual Flow | `HKCategoryTypeIdentifierMenstrualFlow` | category | `unspecified`, `light`, `medium`, `heavy`, `none`; plus `menstrualCycleStart` |
| Spotting | `HKCategoryTypeIdentifierIntermenstrualBleeding` | category | `notApplicable` |
| Infrequent Periods | `HKCategoryTypeIdentifierInfrequentMenstrualCycles` | category | `notApplicable` |
| Irregular Cycles | `HKCategoryTypeIdentifierIrregularMenstrualCycles` | category | `notApplicable` |
| Persistent Spotting | `HKCategoryTypeIdentifierPersistentIntermenstrualBleeding` | category | `notApplicable` |
| Prolonged Periods | `HKCategoryTypeIdentifierProlongedMenstrualPeriods` | category | `notApplicable` |
| Cervical Mucus Quality | `HKCategoryTypeIdentifierCervicalMucusQuality` | category | `dry`, `sticky`, `creamy`, `watery`, `eggWhite` |
| Ovulation Test Result | `HKCategoryTypeIdentifierOvulationTestResult` | category | `negative`, `luteinizingHormoneSurge`, `indeterminate`, `estrogenSurge` |
| Basal Body Temperature | `HKQuantityTypeIdentifierBasalBodyTemperature` | quantity | `degC` |

`menstrualCycleStart` (from `HKMetadataKeyMenstrualCycleStart`) is present as
`true` or `false` when HealthKit reported it and absent otherwise. Sexual
activity, contraception, pregnancy, lactation, pregnancy and progesterone tests,
the menopause types, and cycle symptoms are deliberately not exported. All types
are available on every supported iOS version.

## ECG recordings

Apple Watch ECG recordings (`HKDataTypeIdentifierElectrocardiogram`) are in the
**Heart Events** group, on by default like other new types: on upgrade the
toggle defaults on and the grown read set triggers one HealthKit authorization
request. Each recording is one sample in its own `electrocardiogram` shape (see
[`docs/webhook/PAYLOADS.md`](../docs/webhook/PAYLOADS.md#electrocardiogram--an-ecg-recording-summary)):

| Field | Source |
| --- | --- |
| `classification` | Apple's classification, unchanged: `sinusRhythm`, `atrialFibrillation`, `inconclusiveLowHeartRate`, `inconclusiveHighHeartRate`, `inconclusivePoorReading`, `inconclusiveOther`, `notSet`, `unrecognized`, or `classification<N>` |
| `averageHeartRateBpm` | Average heart rate during the recording; absent (not `0`) when HealthKit has none |
| `symptomsStatus` | `notSet`, `none`, `present`, or `symptomsStatus<N>` |
| `samplingFrequencyHz`, `numberOfVoltageMeasurements` | Recording details; the frequency is absent when HealthKit has none |
| `appleEcgAlgorithmVersion` | `HKMetadataKeyAppleECGAlgorithmVersion`, when present |

The waveform is never read or sent, and neither are the symptoms a user logs
with a recording (separate HealthKit types). Conduit adds no interpretation.
`HKElectrocardiogram` cannot be constructed in a test, so the mapping is
unit-tested through `AnchoredReader.makeElectrocardiogramValue`; whether a real
recording wakes the app in the background is not yet verified on a device (if
not, it is picked up on the next sync of any other type).

## Medications

Doses logged in the iOS 26 Medications feature of the Health app
(`HKMedicationDoseEventTypeIdentifierMedicationDoseEvent`, iOS 26 or later) are
in their own **Medications** group. It is sensitive like cycle tracking (off by
default, also on upgrade, and held back from the public test endpoint), with one
difference: HealthKit grants medications **per medication**, in a system sheet
listing the medications in the Health app, never through the normal permission
request (putting the dose-event type there raises an exception that kills the
whole permission flow). Doses arrive only for the medications picked in that
sheet, which opens from **Choose Medications to Share…** in onboarding's
permission step and in Settings → Data Types → Medications (which also turns the
toggle on). Allow Health Access and Save Changes never open it, so turning the
Medications toggle on alone shares nothing until a medication is picked. The
sheet appears on every request, so only that button opens it; tap again to add
or remove a medication. Below iOS 26 the button is not offered and Medications
cannot be turned on.

Each dose event is one sample in its own `medicationDose` shape (see
[`docs/webhook/PAYLOADS.md`](../docs/webhook/PAYLOADS.md#medicationdose--one-medication-dose-event)).
The medication is joined on-device from the shared medication list and sent by
name and general form only, never its nickname or clinical codes. Every log
status is sent, including the `notInteracted` and `notificationNotSent`
placeholders HealthKit writes for unanswered reminders, and a status change
arrives as a tombstone plus a new sample.

| Field | Source |
| --- | --- |
| `medicationName`, `generalForm` | The medication as picked in the Health app (`displayText`, form such as `tablet`); empty if the dose's medication is no longer shared |
| `scheduleType` | `schedule`, `asNeeded`, or `scheduleType<N>` |
| `logStatus` | `taken`, `skipped`, `snoozed`, `notInteracted`, `notificationNotSent`, `notLogged`, or `logStatus<N>` |
| `scheduledUnixMs`, `scheduledDoseQuantity` | When the dose was due and how much; absent for an as-needed dose |
| `doseQuantity`, `unit` | The logged amount (`0` for a skipped dose, absent when HealthKit has none) and its HealthKit unit |

`HKMedicationDoseEvent` cannot be constructed in a test, so the mapping is
unit-tested through `AnchoredReader.makeMedicationDoseValue`. The sheet itself,
the delete-and-recreate on a status change, background delivery, and what
un-sharing a medication reports can be checked only on a device.

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

Settings → About always offers the explicit App Store write-review link, a
clearly identified public GitHub Help & Feedback link, and a Webhook Payload
Format link to [`docs/webhook/README.md`](../docs/webhook/README.md), with no
automatic data attachments. See Apple's [RequestReviewAction documentation](https://developer.apple.com/documentation/storekit/requestreviewaction):
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

For enabled types available on this iOS version other than GPS routes, each run
captures at most one incremental page (up to 200 objects), with atomic
enqueue/anchor update. Types without a valid forward anchor are skipped and
reported as not yet initialized; open Conduit to
initialize them through its normal start-of-today capture before retrying the action.
GPS routes scan up to 10 recent workouts per run and do not require an anchor.
Capture stops between reads/workouts on cancellation or after a 20-second
cooperative budget; an in-progress HealthKit query can exceed that budget.
Outbox capacity still applies.
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
