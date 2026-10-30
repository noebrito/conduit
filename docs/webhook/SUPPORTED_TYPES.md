# Supported HealthKit types

This page lists every HealthKit type the Conduit app sends to your webhook, how each one looks on
the wire, and what is planned or deliberately left out. For the shapes themselves (`quantity`,
`category`, `workout`, `correlation`, `route`, and the planned `electrocardiogram` and
`medicationDose`), see [PAYLOADS.md](./PAYLOADS.md).

## What "supported" means

A type on this page is registered in the app. It is sent when the user has it turned on in the
app's Data Types settings **and** has granted Conduit read access to it in the iOS Health
permissions. Capture is forward-only by default: the app sends new samples from the day it starts
capturing, and older history only when the user runs an import. Quantities are converted to the
fixed unit listed for their type; otherwise values are passed through as HealthKit stores them, and
Conduit adds no interpretation.

A type can be supported and still send nothing. Many types are only written by a particular device
or app (the notes column says which); with no writer on the user's phone, the series stays empty.

## How to read the tables

| Column | Meaning |
|---|---|
| Name | The name shown in the app's Data Types picker. |
| `hkTypeId` | The `SampleBatch.hkTypeId` string your receiver sees. Each appears once on this page. |
| Shape | Which `Sample` value key carries the data. |
| Unit or `valueName` | For `quantity`: the `unit` string, which is fixed per type. For `category`: the possible `valueName`s. |
| Min iOS | The lowest iOS version where HealthKit offers the type. The app itself requires iOS 17, so `17` means "every supported device". On an older iOS the type is skipped. |
| Notes | What has to record it, and anything unusual. |

Every type below except [Cycle Tracking](#cycle-tracking) is on by default when the app first sets
up or when an update adds it. The user can turn any of them off. The tables follow the app's picker order.

## Activity & Fitness

| Name | `hkTypeId` | Shape | Unit or `valueName` | Min iOS | Notes |
|---|---|---|---|---|---|
| Heart Rate | `HKQuantityTypeIdentifierHeartRate` | quantity | `count/min` | 17 | Also the source for the readings behind heart-rate notifications (see [Heart Events](#heart-events)). |
| Resting Heart Rate | `HKQuantityTypeIdentifierRestingHeartRate` | quantity | `count/min` | 17 | |
| Heart Rate Variability (SDNN) | `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` | quantity | `ms` | 17 | |
| Heart Rate Variability (RMSSD) | `HKQuantityTypeIdentifierHeartRateVariabilityRMSSD` | quantity | `ms` | 27 | Separate from SDNN. Needs a writer that records it. |
| Walking Heart Rate Average | `HKQuantityTypeIdentifierWalkingHeartRateAverage` | quantity | `count/min` | 17 | |
| Time in Daylight | `HKQuantityTypeIdentifierTimeInDaylight` | quantity | `min` | 17 | Apple Watch SE, Series 6 or later, or Ultra, with watchOS 10 or later. |
| Steps | `HKQuantityTypeIdentifierStepCount` | quantity | `count` | 17 | |
| Walking + Running Distance | `HKQuantityTypeIdentifierDistanceWalkingRunning` | quantity | `m` | 17 | |
| Cycling Distance | `HKQuantityTypeIdentifierDistanceCycling` | quantity | `m` | 17 | |
| Swimming Distance | `HKQuantityTypeIdentifierDistanceSwimming` | quantity | `m` | 17 | |
| Flights Climbed | `HKQuantityTypeIdentifierFlightsClimbed` | quantity | `count` | 17 | |
| Active Energy Burned | `HKQuantityTypeIdentifierActiveEnergyBurned` | quantity | `kcal` | 17 | |
| Basal Energy Burned | `HKQuantityTypeIdentifierBasalEnergyBurned` | quantity | `kcal` | 17 | |
| Exercise Time | `HKQuantityTypeIdentifierAppleExerciseTime` | quantity | `min` | 17 | |
| Stand Time | `HKQuantityTypeIdentifierAppleStandTime` | quantity | `min` | 17 | Minutes standing. Not the Stand ring; that is Stand Hours. |
| Stand Hours | `HKCategoryTypeIdentifierAppleStandHour` | category | `stood`, `idle` | 17 | `stood` is enum value 0, so it arrives with no `value` key. |
| VO₂ Max | `HKQuantityTypeIdentifierVO2Max` | quantity | `ml/kg*min` | 17 | |
| Running Power | `HKQuantityTypeIdentifierRunningPower` | quantity | `W` | 17 | Running dynamics: Apple Watch SE (2nd generation), Series 6 or later, or Ultra, during outdoor running workouts only. |
| Running Speed | `HKQuantityTypeIdentifierRunningSpeed` | quantity | `m/s` | 17 | Running dynamics, as above. |
| Running Stride Length | `HKQuantityTypeIdentifierRunningStrideLength` | quantity | `m` | 17 | Running dynamics, as above. |
| Running Vertical Oscillation | `HKQuantityTypeIdentifierRunningVerticalOscillation` | quantity | `cm` | 17 | Running dynamics, as above. |
| Running Ground Contact Time | `HKQuantityTypeIdentifierRunningGroundContactTime` | quantity | `ms` | 17 | Running dynamics, as above. |
| Heart Rate Recovery (1 min) | `HKQuantityTypeIdentifierHeartRateRecoveryOneMinute` | quantity | `count/min` | 17 | Recorded by Apple Watch after a workout. |
| Physical Effort | `HKQuantityTypeIdentifierPhysicalEffort` | quantity | `kcal/kg*hr` | 17 | |
| Cycling Power | `HKQuantityTypeIdentifierCyclingPower` | quantity | `W` | 17 | Needs a paired Bluetooth cycling power accessory. |
| Cycling Cadence | `HKQuantityTypeIdentifierCyclingCadence` | quantity | `count/min` | 17 | Needs a paired Bluetooth cadence accessory. |
| Cycling Speed | `HKQuantityTypeIdentifierCyclingSpeed` | quantity | `m/s` | 17 | Needs a paired Bluetooth speed accessory. |
| Cycling Functional Threshold Power (FTP) | `HKQuantityTypeIdentifierCyclingFunctionalThresholdPower` | quantity | `W` | 17 | |
| Swimming Stroke Count | `HKQuantityTypeIdentifierSwimmingStrokeCount` | quantity | `count` | 17 | |
| Workout Effort Score | `HKQuantityTypeIdentifierWorkoutEffortScore` | quantity | `appleEffortScore` | 18 | Sent as its own series, not attached to a workout. |
| Estimated Workout Effort Score | `HKQuantityTypeIdentifierEstimatedWorkoutEffortScore` | quantity | `appleEffortScore` | 18 | As above. |

## Body Measurements

| Name | `hkTypeId` | Shape | Unit or `valueName` | Min iOS | Notes |
|---|---|---|---|---|---|
| Body Mass (Weight) | `HKQuantityTypeIdentifierBodyMass` | quantity | `kg` | 17 | |
| Body Fat Percentage | `HKQuantityTypeIdentifierBodyFatPercentage` | quantity | `%` | 17 | A fraction: 0.2 means 20%. |
| Lean Body Mass | `HKQuantityTypeIdentifierLeanBodyMass` | quantity | `kg` | 17 | |
| Body Mass Index | `HKQuantityTypeIdentifierBodyMassIndex` | quantity | `count` | 17 | |
| Height | `HKQuantityTypeIdentifierHeight` | quantity | `m` | 17 | |
| Waist Circumference | `HKQuantityTypeIdentifierWaistCircumference` | quantity | `m` | 17 | |

## Vitals

| Name | `hkTypeId` | Shape | Unit or `valueName` | Min iOS | Notes |
|---|---|---|---|---|---|
| Respiratory Rate | `HKQuantityTypeIdentifierRespiratoryRate` | quantity | `count/min` | 17 | |
| Blood Oxygen (SpO₂) | `HKQuantityTypeIdentifierOxygenSaturation` | quantity | `%` | 17 | A fraction: 0.97 means 97%. |
| Body Temperature | `HKQuantityTypeIdentifierBodyTemperature` | quantity | `degC` | 17 | |
| Blood Glucose | `HKQuantityTypeIdentifierBloodGlucose` | quantity | `mg/dL` | 17 | |
| Blood Pressure | `HKCorrelationTypeIdentifierBloodPressure` | correlation | two `mmHg` components | 17 | See the `correlation` section of [PAYLOADS.md](./PAYLOADS.md) for telling systolic from diastolic. |

## Sleep & Mindfulness

| Name | `hkTypeId` | Shape | Unit or `valueName` | Min iOS | Notes |
|---|---|---|---|---|---|
| Sleep Analysis | `HKCategoryTypeIdentifierSleepAnalysis` | category | `inBed`, `asleepUnspecified`, `awake`, `asleepCore`, `asleepDeep`, `asleepREM` | 17 | `inBed` is enum value 0, so it arrives with no `value` key. |
| Mindful Session | `HKCategoryTypeIdentifierMindfulSession` | category | `mindfulSession` | 17 | The session is the sample's time window. |
| Sleeping Wrist Temperature | `HKQuantityTypeIdentifierAppleSleepingWristTemperature` | quantity | `degC` | 17 | Apple Watch Series 8 or later, Ultra, or SE 3, with sleep tracking set up. Separate from Body Temperature. |
| Sleeping Breathing Disturbances | `HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances` | quantity | `count` | 18 | Apple Watch Series 9 or later, Ultra 2 or later, or SE 3, with sleep tracking. Raw measurements, not a sleep apnea notification. |

## Heart Events

| Name | `hkTypeId` | Shape | Unit or `valueName` | Min iOS | Notes |
|---|---|---|---|---|---|
| High Heart Rate Event | `HKCategoryTypeIdentifierHighHeartRateEvent` | category | `highHeartRateEvent` | 17 | Apple Watch high heart rate notification. |
| Low Heart Rate Event | `HKCategoryTypeIdentifierLowHeartRateEvent` | category | `lowHeartRateEvent` | 17 | Apple Watch low heart rate notification. |
| Irregular Heart Rhythm Event | `HKCategoryTypeIdentifierIrregularHeartRhythmEvent` | category | `irregularHeartRhythmEvent` | 17 | Apple Watch irregular rhythm notification. |

**These notifications do not carry the measured heart rate.** Each sample is a time window; the
readings behind it are the Heart Rate samples whose start falls inside that window. PAYLOADS.md
shows the join: [Heart-rate notifications](./PAYLOADS.md#heart-rate-notifications). High and low
events carry `heartRateEventThresholdBpm`, the threshold the user set in the Watch app. Irregular
rhythm events have no threshold.

## Workouts

| Name | `hkTypeId` | Shape | Unit or `valueName` | Min iOS | Notes |
|---|---|---|---|---|---|
| Workouts | `HKWorkoutTypeIdentifier` | workout | see PAYLOADS.md | 17 | Summary totals, plus heart-rate statistics and events when HealthKit has them. |
| Workout Routes (GPS) | `HKWorkoutRouteTypeIdentifier` | route | see PAYLOADS.md | 17 | One sample per route, linked to its workout by `workoutUuid`. Can be turned off separately from workouts. |

## Nutrition

Written to Health by a food-logging app. With no such app, these series stay empty.

| Name | `hkTypeId` | Shape | Unit or `valueName` | Min iOS | Notes |
|---|---|---|---|---|---|
| Dietary Energy | `HKQuantityTypeIdentifierDietaryEnergyConsumed` | quantity | `kcal` | 17 | |
| Protein | `HKQuantityTypeIdentifierDietaryProtein` | quantity | `g` | 17 | |
| Carbohydrates | `HKQuantityTypeIdentifierDietaryCarbohydrates` | quantity | `g` | 17 | |
| Total Fat | `HKQuantityTypeIdentifierDietaryFatTotal` | quantity | `g` | 17 | |
| Saturated Fat | `HKQuantityTypeIdentifierDietaryFatSaturated` | quantity | `g` | 17 | |
| Fiber | `HKQuantityTypeIdentifierDietaryFiber` | quantity | `g` | 17 | |
| Sugar | `HKQuantityTypeIdentifierDietarySugar` | quantity | `g` | 17 | |
| Sodium | `HKQuantityTypeIdentifierDietarySodium` | quantity | `mg` | 17 | |
| Cholesterol | `HKQuantityTypeIdentifierDietaryCholesterol` | quantity | `mg` | 17 | |
| Water | `HKQuantityTypeIdentifierDietaryWater` | quantity | `mL` | 17 | Some food loggers do not write water. |

## Cycle Tracking

Reproductive health, so these are off by default, including on upgrade, and iOS asks for permission
only when the user turns one on (see [Sensitive categories](#sensitive-categories)).

| Name | `hkTypeId` | Shape | Unit or `valueName` | Min iOS | Notes |
|---|---|---|---|---|---|
| Menstrual Flow | `HKCategoryTypeIdentifierMenstrualFlow` | category | `unspecified`, `light`, `medium`, `heavy`, `none` | 17 | Carries `menstrualCycleStart` when HealthKit reports it. |
| Spotting | `HKCategoryTypeIdentifierIntermenstrualBleeding` | category | `notApplicable` | 17 | The type itself is the meaning; `notApplicable` is value 0, so there is no `value` key. |
| Infrequent Periods | `HKCategoryTypeIdentifierInfrequentMenstrualCycles` | category | `notApplicable` | 17 | A cycle deviation Health records. |
| Irregular Cycles | `HKCategoryTypeIdentifierIrregularMenstrualCycles` | category | `notApplicable` | 17 | A cycle deviation Health records. |
| Persistent Spotting | `HKCategoryTypeIdentifierPersistentIntermenstrualBleeding` | category | `notApplicable` | 17 | A cycle deviation Health records. |
| Prolonged Periods | `HKCategoryTypeIdentifierProlongedMenstrualPeriods` | category | `notApplicable` | 17 | A cycle deviation Health records. |
| Cervical Mucus Quality | `HKCategoryTypeIdentifierCervicalMucusQuality` | category | `dry`, `sticky`, `creamy`, `watery`, `eggWhite` | 17 | |
| Ovulation Test Result | `HKCategoryTypeIdentifierOvulationTestResult` | category | `negative`, `luteinizingHormoneSurge`, `indeterminate`, `estrogenSurge` | 17 | |
| Basal Body Temperature | `HKQuantityTypeIdentifierBasalBodyTemperature` | quantity | `degC` | 17 | Separate from Body Temperature. |

## `valueName` notes

- A category type the app does not have names for arrives as `value<N>`, where `N` is the raw
  HealthKit integer. Treat it as an unknown state rather than an error.
- Whenever the raw integer is 0, the `value` key is missing from the JSON. Read `valueName`, not
  `value` (see the zero trap in [PAYLOADS.md](./PAYLOADS.md)).

## Metadata carried

HealthKit attaches metadata to samples. Conduit sends only these keys:

| HealthKit key | Where it appears | Status |
|---|---|---|
| `HKMetadataKeyWorkoutBrandName` | `workout.brandName` | Sent today |
| `HKMetadataKeyIndoorWorkout` | `workout.isIndoor` | Sent today |
| `HKMetadataKeyHeartRateEventThreshold` | `category.heartRateEventThresholdBpm` | Sent today, on high and low heart-rate events |
| `HKMetadataKeyMenstrualCycleStart` | `category.menstrualCycleStart` | Sent today, on menstrual flow |
| `HKMetadataKeyAppleECGAlgorithmVersion` | `electrocardiogram.appleEcgAlgorithmVersion` | In the schema, for ECG; the app does not send it yet |

All other sample metadata is left out, including device-specific keys and any keys a writing app
adds of its own.

## Planned

These are not sent today. Each will be listed in the tables above, and in the change log below,
in the app version that starts sending it.

- **ECG.** The classification and average heart rate of Apple Watch ECG recordings, without the
  waveform, as `electrocardiogram` samples under `hkTypeId`
  `HKDataTypeIdentifierElectrocardiogram`. On by default, like the other Heart Events types.
- **Medications.** Dose events (taken, skipped, or an unanswered reminder, and when each was due)
  for the medications the user chooses to share, as `medicationDose` samples under `hkTypeId`
  `HKMedicationDoseEventTypeIdentifierMedicationDoseEvent`. Each medication is identified by its
  name and form only. iOS 26 or later. Off by default: the user turns them on by picking which
  medications to share, in a separate system sheet.

The ECG and medication shapes are in the schema and documented in [PAYLOADS.md](./PAYLOADS.md), so
a receiver can handle them before the app sends them. Two things to build in from the start: filter
dose events on `logStatus`, since unanswered reminder slots are most of the rows, and honour
`deletedUuids`, since HealthKit records a dose status change as a delete plus a new event.

## Not supported, by design

- **ECG waveform.** The voltage samples are large and need a separate HealthKit query per
  recording. The planned ECG support sends the summary only.
- **Clinical health records.** These need a separate Apple entitlement and a different API.
- **Symptoms** (headache, cramps, and similar). HealthKit stores them separately from the types
  above, and they are not part of cycle tracking.
- **State of mind.** Not part of the current or planned scope.
- **Characteristics** (date of birth, biological sex, blood type). These are fixed profile values,
  not samples, so they do not fit the webhook's sample stream.
- **Anything that writes to Health.** Conduit only reads.

## Sensitive categories

Cycle tracking (and any other reproductive health type), medications, and ECG are treated as
sensitive. Cycle tracking is off by default; the planned medications support will be too.

## Requesting a type

Open an issue at <https://github.com/noebrito/conduit/issues> and include:

1. The HealthKit identifier (for example `HKQuantityTypeIdentifierUVExposure`).
2. The iOS version you are on.
3. What writes it to Health on your phone (an Apple Watch model, an app, an accessory).

## Change log

| App version | Change |
|---|---|
| 1.9 | This page first published. Lists everything the app sends as of this version. |
