# Payload reference

The schema of record is [`../../proto/conduit/v1/sync.proto`](../../proto/conduit/v1/sync.proto) —
every message and field is commented there. This document is the operational complement: how that
proto actually looks on the wire, worked examples, and the gotchas a proto file alone won't tell
you. For the full machine-readable field list (types, required-ness, formats), see
[`envelope.schema.json`](./envelope.schema.json) — this document links to it rather than
duplicating every row by hand, since the schema is generated and this prose is not.

## The canonical-JSON rules

Conduit encodes the proto as [proto3 canonical JSON](https://protobuf.dev/programming-guides/json/),
not a hand-rolled format. Four rules from that mapping matter for a receiver author; nothing else
about it is unusual.

**1. Field names are `lowerCamelCase`.** The proto declares `hk_type_id`; the wire says `hkTypeId`.

**2. 64-bit integers are JSON strings.** `sent_at_unix_ms` (an `int64`) is serialized as
`"sentAtUnixMs": "1756600000000"`, not a bare number — this is how the format survives JavaScript's
53-bit safe-integer ceiling. Parse these as integers in your own code.

**3. Zero-valued scalars are omitted from the JSON entirely.** Before: a fully-populated
`QuantityValue{value: 0, unit: "count"}`. After, on the wire:

```json
{ "unit": "count" }
```

Note there is no `value` key at all — not `"value": 0`. This is the single nastiest trap in this
whole format, and it bites real, common data. The `AppleStandHour` category (the "stood" ring)
represents "stood this hour" as `value == 0`, so a genuine, common data point looks like
`{"valueName": "stood"}` with no `value` key — see `examples/02-category.json`. Code that reads
`sample["category"]["value"]` directly will crash on it; code that does `.get("value")` and treats
`None` as "no data" will silently drop every stand hour a user has. **Treat a missing scalar as its
zero value, not as absent data.** The same rule applies to `startUnixMs`/`endUnixMs` at epoch 0,
an empty `source`, and the `batches` key being entirely absent on a Test Connection probe (see
HTTP_CONTRACT.md).

**4. A `oneof` serializes only its active variant.** `Sample.value` is a `oneof` of five shapes
(`quantity`/`category`/`workout`/`correlation`/`route`); the wire carries exactly one of those five
keys, never a null placeholder for the other four.

## Envelope anatomy

```
Envelope
├── schemaVersion, batchId, deviceId, sentAtUnixMs
└── batches: SampleBatch[]
    ├── hkTypeId                    (e.g. "HKQuantityTypeIdentifierHeartRate")
    ├── samples: Sample[]
    │   ├── uuid, startUnixMs, endUnixMs, source
    │   └── oneof value: quantity | category | workout | correlation | route
    └── deletedUuids: string[]      (tombstones — see HTTP_CONTRACT.md)
```

`Envelope` and `SampleBatch` fields:

| Field | On | Notes |
|---|---|---|
| `schemaVersion` | `Envelope` | Always `"v1"`. Reject anything else with a `4xx` — it means a schema change you don't understand yet. |
| `batchId` | `Envelope` | Dedupe key for the *delivery*, not for samples. Prefixed `test-` on the Test Connection probe. |
| `deviceId` | `Envelope` | Stable per install; survives reinstalls. Not a secret. |
| `sentAtUnixMs` | `Envelope` | When the client sent this envelope. |
| `batches` | `Envelope` | Absent entirely (not `[]`) on the Test Connection probe. |
| `hkTypeId` | `SampleBatch` | The HealthKit type identifier shared by every sample in this batch, e.g. `"HKQuantityTypeIdentifierHeartRate"`, `"HKWorkoutTypeIdentifier"`. |
| `samples` | `SampleBatch` | The samples themselves. |
| `deletedUuids` | `SampleBatch` | Tombstones scoped to this `hkTypeId` — see HTTP_CONTRACT.md. |

Every `Sample`, regardless of shape, carries `uuid` (the dedupe key), `startUnixMs`/`endUnixMs`, and
an optional `source` (`{name, bundleId, productType}` — the recording app/device; may be empty).

## One section per value shape

### `quantity` — scalar measurements

HealthKit quantity types: heart rate, steps, weight, active energy, nutrition, and most other
numeric metrics.

```json
{
  "uuid": "b3c6a1d2-4e77-4a9f-8c10-5d2e9f0a7b41",
  "startUnixMs": "1756660800000",
  "endUnixMs": "1756660800000",
  "source": { "name": "Noe's Apple Watch", "bundleId": "com.apple.health...", "productType": "Watch7,1" },
  "quantity": { "value": 68, "unit": "count/min" }
}
```

| Field | Notes |
|---|---|
| `value` | The measurement, as a plain JSON number. **Absent (not `0`) when the true value is zero** — see the canonical-JSON rules above. |
| `unit` | A HealthKit unit string, e.g. `"count/min"`, `"kg"`, `"m"`, `"kcal"`. Free text — treat it as an opaque label, not an enum, since HealthKit doesn't constrain it to a fixed set. |

Full example: `examples/01-quantity.json` (two heart-rate samples).

### `category` — enumerated states

HealthKit category types: sleep stages, Stand Hour, mindful sessions, heart-rhythm events.

```json
{ "category": { "value": 5, "valueName": "asleepREM" } }
```

| Field | Notes |
|---|---|
| `value` | The raw HealthKit category enum integer. **Absent (not `0`) when it's zero** — this is the omitted-zero trap's most common real-world trigger (below). |
| `valueName` | The **stable, non-localized** HealthKit enum name, e.g. `"asleepREM"`, `"stood"`. Prefer this over the raw integer: it doesn't change across OS locale or version, unlike the exact set and ordering of the integer values, which has changed in practice. |

**The zero trap, worked:** `HKCategoryTypeIdentifierAppleStandHour` represents "stood this hour" as
enum value `0` (`"stood"`) and "didn't stand" as `1` (`"idle"`). A stood hour's sample therefore
serializes with **no `value` key at all** — `{"valueName": "stood"}` — since `0` is the proto3
default and gets omitted. See `examples/02-category.json` for both a normal non-zero category
(`asleepREM`) and this exact zero case side by side.

### `workout` — a workout summary

```json
{ "workout": { "activityType": "running", "durationSeconds": 1800, "totalEnergyKcal": 310.5, "totalDistanceM": 5023.4 } }
```

| Field | Notes |
|---|---|
| `activityType` | A compact name from a curated set (`"running"`, `"cycling"`, `"swimming"`, `"yoga"`, ...), or `"activityType<N>"` — the raw `HKWorkoutActivityType` integer — for a value not in that curated set. Stable, but not exhaustive: don't assume every workout has a friendly name. |
| `durationSeconds`, `totalEnergyKcal`, `totalDistanceM` | Workout totals. `totalDistanceM` is `0` (and therefore absent on the wire) for a non-distance workout like yoga. |
| `brandName` | `HKMetadataKeyWorkoutBrandName`. **HealthKit has no user-entered workout name** — this is the closest thing it exposes, and only some third-party / gym-class / Fitness+ writers set it. Absent for most Apple Watch workouts: that's the steady state, not missing data. |
| `isIndoor` | `HKMetadataKeyIndoorWorkout`. **Absent and `false` mean different things here**: absent is "the writer never said", `false` is "the writer said outdoor". This one field is genuinely present as `false` on the wire — it's `optional` in the proto, so presence survives the omitted-zero rule. |
| `avgHeartRateBpm`, `maxHeartRateBpm`, `minHeartRateBpm` | Heart-rate statistics **HealthKit itself computed over the samples it associates with this workout** — not a time-window guess. Absent entirely (not `0`) when the workout carries no heart-rate samples. |
| `events` | `HKWorkout.workoutEvents`, oldest to newest. Absent for most workouts; laps, segments and pause/resume activity are what produce entries. Each entry is `{"type", "startUnixMs", "endUnixMs"}`, where `type` is `"pause"`, `"resume"`, `"lap"`, `"marker"`, `"motionPaused"`, `"motionResumed"`, `"segment"`, `"pauseOrResumeRequest"`, or `"eventType<N>"` for a raw type not in that set. **Only `lap` and `segment` span time** — every other type is an instant, where `endUnixMs` equals `startUnixMs`. |

**`brandName` and everything after it is best-effort and usually absent** — build against
`activityType` plus the three totals, and treat the rest as a bonus when the writer supplied it.

The pre-aggregated heart-rate stats are summary numbers, not a series. **For the in-workout heart
rate curve, correlate `HKQuantityTypeIdentifierHeartRate` `quantity` samples** (from the same
device, in the same batch stream) against this sample's `startUnixMs`/`endUnixMs` window — the
per-sample data is there, it's just not attached to the workout for you.

Full example: `examples/03-workout.json` (a 30-minute run).

### `correlation` — grouped readings

v1 supports exactly one correlation type: blood pressure.

```json
{
  "correlation": {
    "components": [
      { "uuid": "...", "startUnixMs": "...", "endUnixMs": "...", "quantity": { "value": 118, "unit": "mmHg" } },
      { "uuid": "...", "startUnixMs": "...", "endUnixMs": "...", "quantity": { "value": 76, "unit": "mmHg" } }
    ]
  }
}
```

| Field | Notes |
|---|---|
| `components` | Exactly two full `Sample`s for blood pressure, each with its own `uuid`/`source`/`quantity`, in `mmHg`. **Ordering is by value, not by role** — the higher reading is systolic, the lower is diastolic, regardless of the order they appear in the array. |

The batch's `hkTypeId` for this shape is `"HKCorrelationTypeIdentifierBloodPressure"`. Full example:
`examples/04-correlation.json`.

### `route` — a workout's GPS path

```json
{
  "route": {
    "workoutUuid": "f4a8d1e6-2b73-4c9f-8e05-1a6c3d8f4b92",
    "activityType": "running",
    "points": [
      { "lat": 34.0967, "lng": -117.7198, "altitudeM": 365.2, "timestampUnixMs": "1756656000000",
        "horizontalAccuracyM": 5.0, "verticalAccuracyM": 3.0, "speedMps": 2.8, "courseDeg": 145.0 }
    ]
  }
}
```

| Field | Notes |
|---|---|
| `workoutUuid` | **Foreign key** to the `uuid` of the `workout` Sample this route belongs to. Look the workout up by this, don't assume ordering. |
| `activityType` | Denormalized from the parent workout, for convenience. |
| `points` | Ordered **oldest → newest**. May be downsampled on-device — a route's point count is not a promise of the raw on-device sample rate. |

Per point: `lat`/`lng` are degrees; `altitudeM` is ellipsoidal metres; `timestampUnixMs` is (like all
64-bit fields) a string. **`verticalAccuracyM`, `speedMps`, and `courseDeg` use a negative value to
mean "invalid"**, not a real reading — this mirrors `CLLocation`'s own convention on iOS. Don't plot
or average a negative value in these three fields; treat it the same as missing.

Full example: `examples/05-route.json`, whose `workoutUuid` points back at `examples/03-workout.json`'s
sample.

## Deletions

See [HTTP_CONTRACT.md](./HTTP_CONTRACT.md#deletions-tombstones) for the full contract.
`deletedUuids` lives on `SampleBatch`, alongside `samples`, scoped to that batch's `hkTypeId` — a
UUID listed here was always delivered under that same `hkTypeId`, never another one.
`examples/06-deletions.json` shows the pair in one batch: the replacement calorie entry, and a
tombstone for the earlier `HKQuantityTypeIdentifierDietaryEnergyConsumed` entry it supersedes.

## Forward compatibility: what to do with a shape you don't recognize

New value shapes are added to the `oneof` with a fresh field number — an existing shape is never
renumbered or reshaped. This means the *set* of possible shapes can grow after you write your
receiver.

**Skip a `Sample` whose value key you don't recognize; never fail the whole envelope over it.** This
is exactly what the reference ingester does (it counts the skip as a metric rather than erroring),
and it's what keeps one sample from an app update you haven't caught up with from stalling every
*other*, perfectly normal sample batched alongside it. `examples/receiver.py`'s
`next((k for k in SHAPES if k in s), None)` / `continue` is the whole pattern.
