# Conduit — App Store marketing screenshots

Reproducibly-generated App Store Connect screenshots for the Conduit iOS app,
across Apple's currently-required iPhone sizes in both light and dark appearance.

**These are generated, not hand-taken. Do not edit the PNGs by hand — regenerate.**

## What's here

```
docs/appstore-screenshots/
├── iphone-6.9-inch-1320x2868/     ← required slot (iPhone 16/17 Pro Max)
│   ├── light/ {1-home, 2-activity, 3-settings, 4-healthkit-permission, 5-welcome}.png
│   └── dark/  … same five …
└── iphone-6.5-inch-1284x2778/     ← still-accepted fallback (iPhone 14 Plus / 13 Pro Max class)
    ├── light/ … same five …
    └── dark/  … same five …
```

20 PNGs total = 5 screens × 2 device sizes × {light, dark}.

### Device sizes (verified against Apple, 2026)

| Slug | Portrait px | Class | App Store status |
|------|-------------|-------|------------------|
| `iphone-6.9-inch-1320x2868` | **1320 × 2868** | 6.9″ (iPhone 16/17 Pro Max) | **Required** |
| `iphone-6.5-inch-1284x2778` | **1284 × 2778** | 6.5″ (iPhone 14 Plus / 13 Pro Max) | Accepted (fallback) |

Apple requires at least one 6.9″ screenshot; the 6.5″ set is provided so you can
upload either. Both are rendered at exact pixel dimensions (scale 3) with **no
alpha channel** and RGB color — the format App Store Connect enforces (no
off-by-one tolerance). Uploading either device folder to App Store Connect is a
drag-and-drop.

> Uploading is owner-only (needs the App Store Connect account). This tooling
> produces the images; a human runs the upload. Drag-and-drop still works, **or**
> use the automated `fastlane deliver` lane — one command that stages these PNGs
> into App Store Connect (screenshots-only, never submits for review). See
> [`../../fastlane/README.md`](../../fastlane/README.md):
> `bundle exec fastlane ios upload_screenshots` (with the ASC API key env vars).

## Regenerate — one command

```bash
cd conduit/ios
TEST_RUNNER_GENERATE_APPSTORE_SCREENSHOTS=1 xcodebuild test \
  -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' \
  -only-testing:ConduitTests/AppStoreScreenshotTests \
  CODE_SIGNING_ALLOWED=NO
```

Then review the diff and commit the regenerated PNGs.

Notes:
- **Any booted iPhone simulator works** as the `-destination` — the generator
  forces each screen's exact point-size × scale-3 in an off-screen renderer, so
  the destination device does **not** change the output pixels. Pick whatever
  simulator you have (`xcrun simctl list devices available`).
- The `TEST_RUNNER_` prefix is required: `xcodebuild` only forwards host env
  vars into the simulator test process when they're prefixed with
  `TEST_RUNNER_` (it's stripped inside the process, so the test reads
  `GENERATE_APPSTORE_SCREENSHOTS`).
- Rendering on a newer local iOS (e.g. iOS 26) is fine — unlike the pixel-diffed
  `ScreenSnapshotTests`, these images aren't compared against a baseline; they
  just need to look right and be the exact App Store dimensions.

## How it works (mechanism)

The generator is a single gated XCTest —
[`ConduitTests/AppStoreScreenshotTests.swift`](../../ConduitTests/AppStoreScreenshotTests.swift) —
run via `xcodebuild test`. It **reuses the merged screen-snapshot infrastructure**
(`ConduitTests/SnapshotSupport.swift`): each SwiftUI screen is hosted in a real
key `UIWindow` over an in-memory, seeded `AppState`, the run loop is pumped so
lazy `.onAppear` loaders settle, and the live framebuffer is captured — then
written as a PNG at the target device's exact pixel size.

### Why this over `fastlane snapshot` / a live-app XCUITest

Conduit gates its Home surface behind completed onboarding **and** a live
HealthKit authorization dialog. A headless UITest can't script the HealthKit
permission sheet, and a populated Home needs seeded local data — so driving the
real app through navigation is fragile and non-deterministic. Rendering each
screen directly over seeded fixtures (the exact approach the merged
`ScreenSnapshotTests` already proved) means **zero app-code changes, no new
dependency, no fragile navigation**, and the marketing images track how the app
actually renders.

### Seeded (populated, not empty) data

Screens are fed deterministic fixtures so they look compelling:
- **Home** — "Synced 2 minutes ago", 3,847 staged today, 8 pending, 0 failed.
- **Activity** — a mixed delivery history: several successful batches, one HTTP
  500 failure, and an all-deduped ("156 sent · 0 new", highlighted) row.
- **Settings** — a saved webhook URL, 15-minute sync interval, and every data-type
  category enabled (15/15, 6/6, …).
- **Welcome / HealthKit Permission** — the onboarding hero + auth-grant steps.

Fixtures live in `AppStoreScreenshotTests.swift` (`AppStoreFixtures`) alongside
the shared `SnapshotFixtures.seedSettings`.

## CI safety

The test **skips instantly** (`XCTSkipUnless`) unless
`GENERATE_APPSTORE_SCREENSHOTS=1` is set, so the normal `conduit-ios` gate — which
runs the whole `ConduitTests` bundle — is never slowed or made flaky by it. CI
integration for regeneration is intentionally **not** wired in (it would add a
long simulator-render job to the gate for images a human uploads by hand anyway);
this documented one-command local flow is the source of truth.
