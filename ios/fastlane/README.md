# Conduit — App Store upload automation (`fastlane deliver`)

Uploads the **already-generated** App Store marketing screenshots (and, optionally,
text metadata) for **`dev.noebrito.Conduit`** to App Store Connect with one command,
using `deliver` (`upload_to_app_store`). The screenshots themselves are produced and
committed separately — see [`docs/appstore-screenshots/README.md`](../docs/appstore-screenshots/README.md).

## The one command

```bash
cd conduit/ios
bundle install                       # first time only — installs fastlane

ASC_API_KEY_ID=<key id> \
ASC_API_ISSUER_ID=<issuer id> \
ASC_API_KEY_PATH=/abs/path/to/AuthKey_<key id>.p8 \
  bundle exec fastlane ios upload_screenshots
```

That prepares the committed PNGs into the `deliver` layout and uploads them. It does
**not** submit the app, change the binary, or touch metadata.

## Auth — App Store Connect API key (env vars, never committed)

Create/download a key in App Store Connect → **Users and Access → Integrations →
App Store Connect API** (Admin/App Manager role). You get a **Key ID**, an **Issuer
ID**, and a one-time `.p8` download. Supply all three at runtime as environment
variables — nothing is stored in the repo:

| Env var | What | Example |
|---|---|---|
| `ASC_API_KEY_ID` | The key's ID | `2X9R4HXF34` |
| `ASC_API_ISSUER_ID` | The issuer ID (UUID) | `69a6de70-…` |
| `ASC_API_KEY_PATH` | Absolute path to the `.p8` file | `~/secrets/AuthKey_2X9R4HXF34.p8` |
| `CONDUIT_SCREENSHOT_APPEARANCE` *(optional)* | `light` (default) or `dark` | `dark` |

**Never commit the `.p8`** (or any key material). `.gitignore` already excludes
`*.p8` and `AuthKey_*.p8`; keep the key outside the repo. If any env var is missing
the lane fails fast and tells you which one.

## Lanes

| Lane | What it does | What it does **not** do |
|---|---|---|
| `ios upload_screenshots` | Prepares + uploads the screenshots to ASC | No binary, no metadata, **no submission** |
| `ios prepare_screenshots` | Only arranges the PNGs into `fastlane/screenshots/en-US/` (no network) | — |
| `ios upload_metadata` | Uploads **text metadata only** (requires `fastlane/metadata/` populated first) | No binary, no screenshots, **no submission** |
| `ios download_metadata` | Pulls the live ASC text metadata into `fastlane/metadata/` | No upload |

List them: `bundle exec fastlane lanes`.

### Safety contract (applies to every lane here)

- **Screenshots-only by default** — `upload_screenshots` sets `skip_metadata: true`
  and `skip_binary_upload: true`, so a screenshots run cannot clobber your listing
  text or the binary. `upload_metadata` is the mirror (metadata-only).
- **Never submits for review, never auto-releases** — `submit_for_review false`,
  `automatic_release false`, `run_precheck_before_submit false` (see `Deliverfile`).
  There is deliberately **no** `--submit` path. A human submits from ASC.
- **Idempotent** — `overwrite_screenshots true` replaces the device/locale set each
  run instead of appending, so re-running is safe.

## Which screenshots get uploaded

Source of truth is the committed set under
`docs/appstore-screenshots/<device>/<light|dark>/<n>-<screen>.png`:

- **Devices:** both `iphone-6.9-inch-1320x2868` (Apple-**required** 6.9″ slot) and
  `iphone-6.5-inch-1284x2778` (accepted 6.5″ fallback). `deliver` maps each PNG to
  its App Store display size by **pixel resolution**, so both sets upload from one run.
- **Appearance:** ASC has a single screenshot slot set per device size, so we upload
  **one** appearance. **Default = `light`** (broad, neutral App Store default). Switch
  to the dark set with `CONDUIT_SCREENSHOT_APPEARANCE=dark`.

`prepare_screenshots` copies the chosen set into `fastlane/screenshots/en-US/` with
per-device filename prefixes (`iphone69_…`, `iphone65_…`) to avoid name collisions and
preserve the on-store order (`1-home` → `5-welcome`). That directory is **derived and
gitignored** — the committed PNGs remain the single source of truth; regenerate them
via the screenshot generator, not by editing `fastlane/screenshots/`.

## Metadata (optional)

`fastlane/metadata/` is not committed. To manage listing text via fastlane:

```bash
# pull current listing text from ASC
ASC_API_KEY_ID=… ASC_API_ISSUER_ID=… ASC_API_KEY_PATH=… \
  bundle exec fastlane ios download_metadata
# edit the .txt files under fastlane/metadata/, then:
ASC_API_KEY_ID=… ASC_API_ISSUER_ID=… ASC_API_KEY_PATH=… \
  bundle exec fastlane ios upload_metadata
```

## Verifying config without credentials

You don't need a real key to confirm the config is valid:

```bash
ruby -c fastlane/Fastfile        # parses OK
ruby -c fastlane/Appfile
ruby -c fastlane/Deliverfile
bundle exec fastlane lanes       # lists the lanes (after `bundle install`)
```

Running an upload lane without the env vars stops immediately with a clear "missing
`ASC_API_*`" error before any network call.
