# Conduit

**A privacy-first iOS health companion.**

Conduit streams your Apple HealthKit data to a webhook **you** configure, over
HTTPS. You choose exactly where your data goes. The app itself stores nothing in
the cloud and collects nothing about you.

## Verify, don't trust

Your health data stays on your device. The only time any of it leaves is when
Conduit sends it to the webhook endpoint you configured yourself — nowhere else.

That's a strong claim, so we made it checkable. This repository is the source of
the app that ships on the App Store, published **so you can verify that claim for
yourself** rather than taking our word for it. It mirrors the App Store
**"Data Not Collected"** privacy label: there is no analytics SDK, no telemetry,
no backend that we operate collecting your data.

## The wire schema is the receipt: [`proto/`](proto/)

If you want to know precisely what does — and does not — leave your device, read
[`proto/conduit/v1/sync.proto`](proto/conduit/v1/sync.proto).

That protobuf schema is the **authoritative wire-schema-of-record**: it is the
exact definition of the payload the app serializes and uploads to your webhook.
Nothing is sent that isn't described there. It carries HealthKit samples you
explicitly opted into — quantities, categories, workouts, correlations — tagged
with their source and timestamps, wrapped in a batch envelope keyed for
deduplication. No identifiers beyond a per-install device UUID that you can see
generated in the code. Inspect it and you can see the whole story of what's on
the wire.

## The app: [`ios/`](ios/)

The full Xcode project, Swift sources, tests, and release tooling live under
[`ios/`](ios/).

- Open [`ios/Conduit.xcodeproj`](ios/Conduit.xcodeproj) in Xcode (15 or later,
  iOS 17+ deployment target).
- Select the **Conduit** scheme and an iPhone simulator, then Run (⌘R).
- Contributors supply their own code signing. The project uses automatic
  signing; select your own Apple Developer team under **Signing &
  Capabilities**, or override `DEVELOPMENT_TEAM` on the command line. The
  committed team id enables one-command builds but cannot sign without the
  private certificates (which are not in this repo).

See [`ios/README.md`](ios/README.md) for the full build, test, and layout notes.

## License

Apache-2.0. See [`LICENSE`](LICENSE).

## Contributing

**This repository is a read-only public mirror** of the Conduit app that ships
on the App Store. Active development happens in a private monorepo, and this
mirror is regenerated from it — so **external pull requests are not accepted
here** (a PR against this repo can't be merged upstream and will be closed).

**Contributions are welcome via GitHub Issues only.** Found a bug, or have a
feature request? Please [open an issue](https://github.com/noebrito/conduit/issues).
That's the channel that reaches the maintainers.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for details.
