# HTTP contract

What Conduit sends, what it expects back, and what each response code does to the user's data.

## Request

```
POST <your url>
Authorization: Bearer <your token>
Content-Type: application/json
User-Agent: Conduit/<app version> (iOS <ios version>)

{ ... an Envelope, as proto3-canonical JSON — see PAYLOADS.md ... }
```

Both the URL and the bearer token are whatever you configured in the app. There is one exception:
the **Test Connection** probe (below) sends `User-Agent: Conduit/<app version> (iOS test)` and a
body with no `batches` key at all.

Conduit does not sign requests (no HMAC) — the bearer token over HTTPS is the only authenticator.
This is a deliberate choice for a bring-your-own-webhook app where the same person controls both
ends of the connection; treat the token as a secret and use a long, random one.

## Response semantics — this table is the whole contract

| You return | The app does to its local copy | Your data |
|---|---|---|
| `2xx` | Deletes the delivered rows from its outbox. Resets the retry backoff. | Delivered — will never be resent. |
| `408`, `429`, `5xx`, or a connection/network error | Marks the rows back to pending and retries with exponential backoff (honoring `Retry-After` on `429`). | Retried later. |
| Any other `4xx` | Marks the rows permanently failed and surfaces this to the user in the app's Activity log. | **Permanently lost** — the app will not retry a `4xx`. |

**The one sentence to remember: answer `5xx`, never `2xx`, when your write actually fails.** A `2xx`
tells the phone it can delete its only copy of that data. Conversely, never answer a `4xx` for a
merely transient problem (a full disk, a dependency timeout) — that permanently drops the batch
instead of getting it retried.

Only answer `2xx` once the batch is durably stored, or accepted for storage in a way you're
confident will complete (e.g. handed off to a queue you trust).

## Retry schedule

On a retryable response, the app backs off per outbox row with roughly ±20% jitter:

```
30s → 2m → 8m → 30m → 2h → 6h → 24h (capped, repeats at 24h)
```

The schedule resets to the start on the next successful batch. If you return a `429` with a
`Retry-After` header (seconds), that value overrides the schedule for that row. Size your expected
downtime tolerance against this: a receiver that's down for under 30 minutes barely delays delivery;
one down for a day or more will see steady 24h-interval retries until it comes back, at which point
everything queued arrives at once.

## Idempotency

Delivery is **at-least-once** — the receiver is responsible for deduping. The app may resend a
sample after a crash, a dropped connection, or any retryable response above, and it may do so under
a **different `batchId`** than the original attempt. `batchId` is a dedupe key for the batch
delivery itself, not for the samples inside it.

**Dedupe on `sample.uuid`.** It's a stable HealthKit identifier that survives retries. A primary key
on `uuid` with `INSERT OR IGNORE`, or an upsert keyed by `uuid`, is enough — you don't need
exactly-once delivery semantics, just an idempotent write. See `examples/receiver.py` for a working
version of this over SQLite.

Sample ordering is not guaranteed, within or across batches.

## Deletions (tombstones)

A `SampleBatch` may carry `deletedUuids`: HealthKit sample UUIDs the OS reported as deleted since
Conduit's last read of that type. This happens more than you'd expect — many logging apps (nutrition
trackers in particular) implement an "edit" as delete-the-old-sample-and-write-a-new-one, not an
in-place update.

**Delete or tombstone every UUID in this list.** If you don't, an edited entry doubles instead of
correcting — the old row lingers forever alongside the new one. Deletes must be idempotent: a
repeated delete for a UUID you no longer have (or never had) is a normal, expected replay, and must
still be treated as success — never fail or retry-signal on it.

See `examples/06-deletions.json` for the shape, and PAYLOADS.md for how `deletedUuids` is scoped
(per `hkTypeId`, alongside `samples` in the same `SampleBatch`).

## The Test Connection probe

The app's in-app "Test Connection" action sends a real request shaped like this — a normal
`Envelope` with a valid `schemaVersion`, `batchId` (prefixed `test-`), and `deviceId`, but **no
`batches` key at all**:

```json
{
  "schemaVersion": "v1",
  "batchId": "test-7f937484-0e92-43d5-c281-902e4d7f8a00",
  "deviceId": "6d2f9b0c-7a41-4e58-b0d3-9c1e4f7a2b66",
  "sentAtUnixMs": "1756661104512"
}
```

**Your receiver must answer this `2xx`.** A receiver that requires a non-empty `batches` array (or
requires the key to be present at all) will 400 this probe, and the user will never be able to
finish onboarding against your endpoint. Default a missing `batches` to an empty list and you get
this for free — there's nothing else special about the request. See `examples/07-test-connection.json`.

## Optional response body

Any `2xx` is a success — you don't have to return anything specific in the body. But if you do
return `{"accepted": N, "deduped": M, "deleted": K}` (all optional; the reference ingester always
returns `accepted`/`deduped` and adds `deleted` only when the request carried tombstones), the app's
Activity screen shows it to the user as e.g. "500 sent · 480 new" — a small, free bit of
observability into whether their receiver is actually doing something with the data. `receiver.py`
returns this shape.

## Sizes and cadence

- Batches are capped at 500 samples by default (user-configurable in the app).
- A single batch's JSON payload is capped at 8 MiB on-device. Accept requests up to at least 16 MiB
  to be safe.
- The app flushes at most every 15 minutes by default, but force-flushes early once 200 samples are
  pending — so expect occasional bursts, not a strict metronome.
