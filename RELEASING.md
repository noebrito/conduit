# Releasing

1. **Bump the version.** Open a PR that raises `MARKETING_VERSION` in
   `ios/Conduit.xcodeproj/project.pbxproj` (4 occurrences — app + test target,
   Debug + Release — keep them equal). It must be higher than whatever's
   currently live; see [`ios/AGENTS.md`](ios/AGENTS.md) for why App Store
   Connect rejects an archive otherwise.
2. **Merge to `main`.** Xcode Cloud picks up the merge, archives the app, and
   uploads the build to TestFlight automatically — no manual archive step.
3. **Once the build ships** (TestFlight, then App Store release), tag the
   commit `vX.Y` matching the released `MARKETING_VERSION` and
   [create a GitHub release](https://github.com/noebrito/conduit/releases/new)
   from that tag.

That's it — there's no separate build/upload step to run by hand.
