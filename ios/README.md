# Conduit — iOS app

Conduit streams Apple HealthKit data from an iOS device to a user-configured
webhook over HTTPS. The user controls where their data goes; the app stores
nothing in the cloud.

See [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) for the full design and
[`../docs/IMPLEMENTATION_PLAN.md`](../docs/IMPLEMENTATION_PLAN.md) for the phased
delivery plan. This directory now contains the **Phase I4 UI**: onboarding,
Home, Settings, Activity Log, and the HealthKit permissions detail screen, on
top of the HealthKit sync engine and SQLite outbox delivered in I2/I3.

## Requirements

- Xcode 15 or later
- iOS 17.0+ deployment target
- An Apple Developer team for signing (project is configured for team
  `3K72BT899D`, matching the other apps in this repo)

## Project layout

```
conduit/ios/
├── Conduit.xcodeproj
├── Conduit/
│   ├── App/             ConduitApp, AppDelegate, AppState (shared observable
│   │                    singleton: database, sync engine, onboarding flag),
│   │                    entitlements
│   ├── Models/
│   │   ├── Generated/   protoc output (sync.pb.swift, owned by Phase 0)
│   │   ├── WebhookConfig.swift, DataTypeConfig.swift, OutboxRow.swift
│   │   └── DeliveryLogEntry.swift
│   ├── Services/
│   │   ├── HealthKit/   HealthTypeRegistry, HealthKitAuthorizer,
│   │   │                ObserverCoordinator, AnchoredReader
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
└── ConduitTests/
```

## Dependencies (Swift Package Manager)

Declared in the project; Xcode resolves them on first open / build:

- [`apple/swift-protobuf`](https://github.com/apple/swift-protobuf) — proto3
  models + canonical JSON serialization (used by the committed `sync.pb.swift`).
- [`groue/GRDB.swift`](https://github.com/groue/GRDB.swift) — SQLite outbox
  and delivery log storage, single shared connection owned by `AppState`.

## Open, build, run

```bash
# Open in Xcode
open conduit/ios/Conduit.xcodeproj

# Build for the simulator from the command line
xcodebuild \
  -project conduit/ios/Conduit.xcodeproj \
  -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  build

# Run the unit tests
xcodebuild \
  -project conduit/ios/Conduit.xcodeproj \
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
- Background Modes: `fetch`, `processing` (`Conduit/Info.plist`)
- `NSHealthShareUsageDescription` — placeholder copy, finalized in Phase I5
- `BGTaskSchedulerPermittedIdentifiers` — `dev.noebrito.Conduit.flush`

## Continuous integration

`ci_scripts/ci_post_clone.sh` stamps `CURRENT_PROJECT_VERSION` with the Xcode
Cloud build number so each TestFlight upload has a unique, increasing build
number, matching the convention used by the other iOS apps in this repo.
