# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## This repo is a read-only public mirror — regenerated, not developed

`github.com/noebrito/conduit` is a **read-only public mirror** of the Conduit
iOS app. Real development happens in the private `home-projects` monorepo under
`conduit/ios` and `conduit/proto`; this repo is the flattened, published copy
(`conduit/ios/*` → `ios/`, `conduit/proto/*` → `proto/`), carrying only the
working tree — **no upstream git history**. External pull requests are not
accepted (see `CONTRIBUTING.md` / the PR template); contributions are via
GitHub Issues only.

**When re-syncing from the monorepo, re-apply these publish-time fixes** (the
monorepo still carries the private originals):
- `proto/conduit/v1/sync.proto` `option go_package` must be the public module
  path `github.com/noebrito/conduit/proto/conduit/v1;conduitv1`, NOT the private
  `github.com/noebrito/home-projects/...` path.
- `ios/ConduitTests/AppStoreScreenshotTests.swift` uses the fake webhook token
  `"demo-token-for-screenshots"` (the upstream `sk_live_…` string trips GitHub
  secret scanning / push protection even though it's not a real credential).
- Verify before publishing: `grep -rn "home-projects" .` and
  `grep -rn "sk_live_" .` must both return nothing.

The public Apple `DEVELOPMENT_TEAM = 3K72BT899D` in
`ios/Conduit.xcodeproj/project.pbxproj` is intentionally kept (public, enables
one-command builds, can't sign without the private certs which aren't here).
