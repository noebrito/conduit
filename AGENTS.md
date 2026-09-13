# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Only `ios/` is developed in this repo — `proto/` and `docs/webhook/` are a one-way mirror

This repo is the real build source for Conduit iOS: `ios/` is developed, reviewed, and released
straight from here (see [`RELEASING.md`](RELEASING.md)). `proto/` and `docs/webhook/` are different —
they stay canonical in a private monorepo (alongside the server/ingester code that isn't in this
repo at all) and are synced here as-is, the same way they always have been. Don't edit those two
directories expecting the change to stick; it would be overwritten by the next sync. See
[`ios/AGENTS.md`](ios/AGENTS.md) for iOS-specific build/test/release knowledge.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
