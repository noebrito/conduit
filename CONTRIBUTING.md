# Contributing to Conduit

Thanks for your interest in Conduit!

## This is where Conduit iOS is built

This repository **is** the Conduit iOS app that ships on the App Store —
Xcode Cloud builds and ships TestFlight/App Store releases straight from
`main` here. It's public so that anyone can **verify** the app's privacy
claims by reading the source and the wire schema ([`proto/`](proto/)).

The wire-format proto and the webhook docs stay canonical in a private
monorepo (the server side isn't part of this repo) and are mirrored here
as-is; everything under [`ios/`](ios/) is developed directly in this repo.

## Pull requests are not accepted here

**External pull requests will not be merged** — this repo's release process
is maintainer-only, so any PR opened here will be closed with a pointer to
this policy. Please don't spend your effort on a PR.

## Please open an issue instead

**Contributions are welcome via GitHub Issues only.**

- 🐛 **Found a bug?** [Open an issue](https://github.com/noebrito/conduit/issues)
  describing what you expected and what happened.
- 💡 **Have a feature request or a question about what's on the wire?**
  [Open an issue](https://github.com/noebrito/conduit/issues) and tell us about
  it.

Issues are read by the maintainers and are the right channel for everything.
Thank you!
