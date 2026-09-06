# Building a webhook receiver for Conduit

Conduit POSTs your Apple HealthKit data — as proto3-canonical JSON — to a URL you own. This
directory is everything you need to receive it: the wire schema, the HTTP contract, and a runnable
example.

**These docs are generated and verified from [`../../proto/conduit/v1/sync.proto`](../../proto/conduit/v1/sync.proto)
in CI, so they cannot silently drift from what the app actually sends.** `envelope.schema.json` is
built by a Go test that walks the compiled proto descriptor on every run and fails the build if it
ever disagrees with the committed file, and every example under `examples/` is round-tripped
through the real ingestion code and validated against the published schema before it ships. See
[HTTP_CONTRACT.md](./HTTP_CONTRACT.md) and [PAYLOADS.md](./PAYLOADS.md) for the details; the point
here is just that "the docs match the wire" is a build-time guarantee, not a promise.

## Quickstart: see your data in five minutes, no phone required

1. Run the example receiver (Python 3, no installs — stdlib only):

   ```sh
   CONDUIT_TOKEN=dev-token python3 examples/receiver.py
   ```

2. Replay a real fixture at it, with `curl`:

   ```sh
   curl -sS -X POST http://localhost:8099 \
     -H "Authorization: Bearer dev-token" \
     -d @examples/01-quantity.json
   # -> {"accepted": 2, "deduped": 0, "deleted": 0}
   ```

   Send it again and you'll get `{"accepted": 0, "deduped": 2, "deleted": 0}` — the receiver dedupes
   on `sample.uuid`, which is exactly what your own receiver needs to do (see
   [HTTP_CONTRACT.md](./HTTP_CONTRACT.md#idempotency)).

3. To see it from a real device: in the Conduit app, point your webhook at a URL that reaches your
   receiver, then tap **Test Connection**. If you don't have a public URL yet and just want to see
   *something* arrive with zero setup, point the app at
   `https://health.noebrito.dev/webhook-test` instead — it's a permanent, public demo receiver
   (any bearer token works) that renders the last 50 requests it received, auto-refreshing, for 30
   minutes each.

   > ⚠️ **The demo receiver is public and unauthenticated: whatever you send it is readable by
   > anyone who opens that URL, for 30 minutes.** Use it to tap **Test Connection** (a probe that
   > carries no samples) or for a brief look at the wire format, then point the app back at your own
   > endpoint. Leaving it configured is not a private test — once sync runs, your real HealthKit
   > samples (heart rate, sleep, weight, workout GPS) get uploaded there and rendered on a
   > world-readable page.

## What's in this directory

| File | What it's for |
|---|---|
| [`HTTP_CONTRACT.md`](./HTTP_CONTRACT.md) | Auth, status codes, retries, idempotency, deletion tombstones — read this before writing any code |
| [`PAYLOADS.md`](./PAYLOADS.md) | The reference: the canonical-JSON rules, and one section per sample shape with a field table |
| [`envelope.schema.json`](./envelope.schema.json) | The wire format as a JSON Schema (draft 2020-12), generated from the proto — feed it to any JSON Schema validator |
| [`examples/`](./examples/) | Seven real, tested envelopes (one per sample shape, plus the Test Connection probe) and a ~70-line reference receiver |

## Five things that will bite you

These are the mistakes real receivers make against this wire format. Each one is demonstrated in a
fixture under `examples/`.

1. **A zero-valued field is omitted from the JSON entirely — it is not sent as `0`.** This is
   [proto3 canonical JSON](https://protobuf.dev/programming-guides/json/) behavior, and it bites
   real, common data: the Stand ring is sourced from a category sample where `stood == 0`, so that
   sample's JSON has no `value` key at all (see `examples/02-category.json`). Code that does
   `sample["category"]["value"]` will crash on it; code that does `.get("value")` and treats
   `None`/missing as "no data" will silently drop it. Read a missing scalar as its zero value, not
   as absent data. (The one deliberate exception is `workout.isIndoor`, which is declared `optional`
   precisely so `false` and absent stay distinguishable — see the `workout` section of
   [PAYLOADS.md](./PAYLOADS.md).)
2. **64-bit integers are JSON strings**, e.g. `"startUnixMs": "1756660800000"`, not a bare number —
   this is how the wire survives JavaScript's 53-bit safe-integer limit. Parse them as integers
   yourself; don't assume your JSON library already did.
3. **The Test Connection probe has no `batches` key at all** — not an empty array, an *absent* key
   (`examples/07-test-connection.json`). A receiver that requires `batches` to be present will 400
   this, and the user's onboarding will never complete. Default a missing `batches` to empty.
4. **Delivery is at-least-once. Dedupe on `sample.uuid`, not on `batchId`.** The app may resend the
   same sample under a brand-new `batchId` after a retry — `batchId` is a batch-level dedupe key,
   not a sample one. A primary key on `uuid` with `INSERT OR IGNORE` (or an upsert-by-id) is enough;
   see [HTTP_CONTRACT.md](./HTTP_CONTRACT.md#idempotency).
5. **Ignoring `deletedUuids` accumulates ghost rows.** When a logging app edits or removes a
   HealthKit entry, Apple represents that as a delete-and-recreate, not an update — so the old
   sample's UUID shows up in a batch's `deletedUuids` array. If your receiver never deletes on this
   signal, an edited entry doubles instead of correcting (`examples/06-deletions.json` shows the
   real shape: a corrected calorie entry alongside a tombstone for the entry it supersedes, both of
   the same `hkTypeId`).

## Questions

This directory is generated from a private monorepo, so there's no PR to send here. If something
looks wrong or you're stuck integrating, please [open an issue](https://github.com/noebrito/conduit/issues) —
see [CONTRIBUTING.md](../../CONTRIBUTING.md).
