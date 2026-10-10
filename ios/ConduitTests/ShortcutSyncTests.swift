import XCTest
import HealthKit
import AppIntents
import GRDB
@testable import Conduit

final class ShortcutSyncTests: XCTestCase {
    func testCaptureThenFlushCountsAndHonestResult() async {
        var events: [String] = []
        let result = await ShortcutSync.run(identifiers: ["enabled-a", "enabled-b"], shouldStop: { false }, capture: { id in
            events.append(id)
            return ShortcutSync.Capture(captured: 5, queued: 3, deletions: 1)
        }, flush: { events.append("flush"); return 4 })
        XCTAssertEqual(events, ["enabled-a", "enabled-b", "flush"])
        XCTAssertEqual(result.capture.captured, 10)
        XCTAssertEqual(result.capture.queued, 6)
        XCTAssertEqual(result.capture.deletions, 2)
        XCTAssertEqual(result.submitted, 4)
        XCTAssertTrue(result.message.contains("not awaited or confirmed"))
        XCTAssertTrue(result.message.contains("may include earlier data"))
    }

    func testLockedReadPreservesEarlierProgressAndFlushesQueue() async {
        let result = await ShortcutSync.run(identifiers: ["first", "locked", "never"], shouldStop: { false }, capture: { id in
            if id == "first" { return ShortcutSync.Capture(captured: 2, queued: 2) }
            XCTAssertEqual(id, "locked")
            throw NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue)
        }, flush: { 2 })
        XCTAssertEqual(result.capture.queued, 2)
        XCTAssertEqual(result.submitted, 2)
        XCTAssertTrue(result.message.contains("device is locked"))
    }

    func testBudgetStopsFurtherReadsAndStillFlushes() async {
        var reads = 0
        let result = await ShortcutSync.run(identifiers: ["a", "b"], shouldStop: { reads == 1 }, capture: { _ in
            reads += 1
            return ShortcutSync.Capture(captured: 200, queued: 0, limited: true)
        }, flush: { 7 })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result.capture.captured, 200)
        XCTAssertEqual(result.submitted, 7)
        XCTAssertTrue(result.message.contains("more data may remain"))
    }

    func testPartialRouteFailureRetainsCountsAndDoesNotReadNextType() async {
        var reads = 0
        let result = await ShortcutSync.run(identifiers: ["route", "next"], shouldStop: { false }, capture: { _ in
            reads += 1
            return ShortcutSync.Capture(captured: 3, queued: 2, notice: "Read failed.")
        }, flush: { 0 })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result.capture.queued, 2)
        XCTAssertTrue(result.message.contains("Read failed."))
    }

    func testFlushFailureDoesNotClaimSubmission() async {
        let result = await ShortcutSync.run(identifiers: ["a"], shouldStop: { false }, capture: { _ in
            ShortcutSync.Capture(captured: 1, queued: 1)
        }, flush: { throw NSError(domain: "test", code: 1) })
        XCTAssertEqual(result.submitted, 0)
        XCTAssertTrue(result.message.contains("Queued data is retained for retry"))
    }

    func testCancelledTaskDoesNotFlush() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ShortcutSync.run(identifiers: ["a"], shouldStop: { Task.isCancelled }, capture: { _ in
                XCTFail("Cancelled action must not read"); return ShortcutSync.Capture()
            }, flush: { XCTFail("Cancelled action must not submit"); return 1 })
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.submitted, 0)
        XCTAssertTrue(result.capture.limited)
    }

    func testNoDestinationDoesNotReadHealth() async throws {
        let database = try AppDatabase.makeInMemory()
        let engine = SyncEngine(database: database)
        let message = await engine.syncFromShortcut()
        XCTAssertTrue(message.contains("configure your destination"))
        XCTAssertEqual(try OutboxDAO(database).totalCount(), 0)
    }

    @MainActor
    func testLockedPreflightNeverOpensConfigurationOrSyncs() async {
        let result = await SyncHealthIntent.execute(protectedDataAvailable: false,
            isConfigured: { XCTFail("Locked preflight must not open the database"); return true },
            sync: { XCTFail("Locked preflight must not capture or upload"); return "" })
        XCTAssertTrue(result.contains("Unlock your iPhone"))
    }

    @MainActor
    func testSetupPreflightAndReadyDispatch() async {
        let setup = await SyncHealthIntent.execute(protectedDataAvailable: true,
            isConfigured: { false }, sync: { XCTFail("Must not sync before setup"); return "" })
        XCTAssertTrue(setup.contains("finish setup"))
        let ready = await SyncHealthIntent.execute(protectedDataAvailable: true,
            isConfigured: { true }, sync: { "bounded result" })
        XCTAssertEqual(ready, "bounded result")
    }

    func testEmptyReadAndRegistrationAreHonest() {
        XCTAssertTrue(ShortcutSync.Summary().message.contains("does not prove Health is empty"))
        XCTAssertEqual(SyncHealthIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        XCTAssertFalse(SyncHealthIntent.openAppWhenRun)
        XCTAssertEqual(ConduitShortcuts.appShortcuts.count, 1)
    }

    private func configure(_ database: AppDatabase, type: HealthDataType, initialized: Bool = true, cap: Int = 50_000) throws -> WebhookConfig {
        var webhook = WebhookConfig.makeDefault(url: "https://old.example/sync", bearerTokenKeychainRef: "test")
        webhook.outboxCap = cap
        try WebhookConfigDAO(database).save(&webhook)
        try enable(database, type: type, initialized: initialized)
        return webhook
    }

    private func enable(_ database: AppDatabase, type: HealthDataType, initialized: Bool = true) throws {
        try DataTypeConfigDAO(database).upsert(DataTypeConfig(hkTypeId: type.identifier, enabled: true,
            minIntervalSeconds: nil, anchorBlob: initialized ? try AnchoredReader.archiveAnchor(HKQueryAnchor(fromValue: 1)) : nil,
            lastSyncAt: nil, lastAttemptAt: nil))
    }

    private func sample(_ uuid: String, end: Date = Date()) -> Conduit_V1_Sample {
        var sample = Conduit_V1_Sample()
        sample.uuid = uuid
        sample.startUnixMs = AnchoredReader.unixMillis(end)
        sample.endUnixMs = sample.startUnixMs
        sample.quantity.value = 1
        sample.quantity.unit = "count"
        return sample
    }

    private func rows(_ database: AppDatabase) throws -> [OutboxRow] {
        try database.dbWriter.read { try OutboxRow.fetchAll($0) }
    }

    private func routeSample(_ uuid: String, workout: HKWorkout) -> Conduit_V1_Sample {
        var result = sample(uuid)
        result.route.workoutUuid = workout.uuid.uuidString
        result.route.activityType = "running"
        return result
    }

    private func deliver(_ batch: Batcher.BatchResult, database: AppDatabase) -> Bool {
        do {
            try database.dbWriter.write {
                try Uploader.commitSent($0, batchID: batch.batchID, httpStatus: 200, accepted: batch.rowIDs.count, deduped: 0)
            }
            return true
        } catch {
            XCTFail("Delivery commit failed: \(error)")
            return false
        }
    }

    @MainActor
    func testDelayedObserverCannotRestoreSampleAfterShortcutDeliversDeletion() async throws {
        let database = try AppDatabase.makeInMemory()
        _ = try configure(database, type: .stepCount)
        let identifier = HealthDataType.stepCount.identifier
        let startingAnchor = try XCTUnwrap(DataTypeConfigDAO(database).anchorBlob(hkTypeId: identifier))
        let gate = ShortcutReadGate()
        let deletedSample = sample("deleted-steps")
        var delivered: [Conduit_V1_Envelope] = []
        let engine = SyncEngine(database: database, readAnchored: { _, anchor, _, limit, _ in
            XCTAssertEqual(try anchor.map(AnchoredReader.archiveAnchor), startingAnchor)
            if limit == HKObjectQueryNoLimit {
                return await gate.pause(AnchoredReader.Result(samples: [deletedSample], deletedUuids: [], newAnchor: HKQueryAnchor(fromValue: 2)))
            }
            XCTAssertEqual(limit, ShortcutSync.pageSize)
            return AnchoredReader.Result(samples: [], deletedUuids: [deletedSample.uuid], newAnchor: HKQueryAnchor(fromValue: 3))
        }, bearerToken: { "test-token" }, submitUpload: { batch, _, _ in
            if let envelope = try? Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON) { delivered.append(envelope) }
            return self.deliver(batch, database: database)
        })
        let observer = Task { await engine.handleObserverWake(typeIdentifier: identifier) }
        await gate.waitUntilStarted()
        let message = await engine.syncFromShortcut()
        XCTAssertTrue(message.contains("processed 1 deletions. Submitted 1"))
        XCTAssertEqual(delivered.flatMap(\.batches).flatMap(\.deletedUuids), [deletedSample.uuid])
        XCTAssertTrue(delivered.flatMap(\.batches).flatMap(\.samples).isEmpty)
        XCTAssertEqual(try OutboxDAO(database).totalCount(), 0)
        let committedConfig = try XCTUnwrap(DataTypeConfigDAO(database).find(hkTypeId: identifier))
        XCTAssertNotEqual(committedConfig.anchorBlob, startingAnchor)
        await gate.resume()
        await observer.value
        XCTAssertEqual(try DataTypeConfigDAO(database).find(hkTypeId: identifier), committedConfig)
        XCTAssertEqual(try OutboxDAO(database).totalCount(), 0)
        XCTAssertEqual(try StagedDailyCountDAO(database).count(), 0)
        XCTAssertEqual(delivered.count, 1)
    }

    @MainActor
    func testDelayedObserverCannotRestoreDeletionAfterCapLimitedShortcutAndInflightDelivery() async throws {
        let database = try AppDatabase.makeInMemory()
        let webhook = try configure(database, type: .stepCount, cap: 1)
        let webhookID = try XCTUnwrap(webhook.id)
        let identifier = HealthDataType.stepCount.identifier
        let typeDAO = DataTypeConfigDAO(database)
        let startingConfig = try XCTUnwrap(typeDAO.find(hkTypeId: identifier))
        let outbox = OutboxDAO(database)
        try outbox.enqueue(sample: sample("already-inflight"), hkTypeId: identifier, webhookId: webhookID)
        let inflightBatch = try XCTUnwrap(Batcher(database: database).buildBatch(webhookID: webhookID, limit: 1, deviceID: "test"))
        let inflightRow = try XCTUnwrap(outbox.find(hkSampleUuid: "already-inflight"))
        XCTAssertEqual(try outbox.count(state: .inflight), webhook.outboxCap)
        let gate = ShortcutReadGate()
        let deletedSample = sample("deleted-steps")
        let blockedSample = sample("blocked-by-cap")
        var delivered: [Conduit_V1_Envelope] = []
        let engine = SyncEngine(database: database, readAnchored: { _, _, _, limit, _ in
            if limit == HKObjectQueryNoLimit {
                return await gate.pause(AnchoredReader.Result(samples: [deletedSample], deletedUuids: [], newAnchor: HKQueryAnchor(fromValue: 2)))
            }
            return AnchoredReader.Result(samples: [blockedSample], deletedUuids: [deletedSample.uuid], newAnchor: HKQueryAnchor(fromValue: 3))
        }, bearerToken: { "test-token" }, submitUpload: { batch, _, _ in
            if let envelope = try? Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON) { delivered.append(envelope) }
            return self.deliver(batch, database: database)
        })
        let observer = Task { await engine.handleObserverWake(typeIdentifier: identifier) }
        await gate.waitUntilStarted()
        let message = await engine.syncFromShortcut()
        XCTAssertTrue(message.contains("Captured 1 samples; queued 0 new samples; processed 1 deletions. Submitted 1"))
        XCTAssertTrue(message.contains("Capture was bounded"))
        XCTAssertEqual(delivered.flatMap(\.batches).flatMap(\.deletedUuids), [deletedSample.uuid])
        XCTAssertTrue(delivered.flatMap(\.batches).flatMap(\.samples).isEmpty)
        XCTAssertNil(try outbox.find(hkSampleUuid: deletedSample.uuid))
        XCTAssertNil(try outbox.find(hkSampleUuid: blockedSample.uuid))
        XCTAssertEqual(try outbox.find(hkSampleUuid: "already-inflight"), inflightRow)
        let committedConfig = try XCTUnwrap(typeDAO.find(hkTypeId: identifier))
        var expectedConfig = startingConfig
        expectedConfig.ingestRevision += 1
        XCTAssertEqual(committedConfig, expectedConfig)
        XCTAssertTrue(deliver(inflightBatch, database: database))
        XCTAssertEqual(try outbox.totalCount(), 0)
        let lastSynced = try SyncStateDAO(database).lastSyncedAt()
        await gate.resume()
        await observer.value
        XCTAssertEqual(try typeDAO.find(hkTypeId: identifier), committedConfig)
        XCTAssertEqual(try SyncStateDAO(database).lastSyncedAt(), lastSynced)
        XCTAssertEqual(try outbox.totalCount(), 0)
        XCTAssertEqual(try StagedDailyCountDAO(database).count(), 1)
        XCTAssertEqual(delivered.count, 1)
        let resumedConfig = try XCTUnwrap(typeDAO.find(hkTypeId: identifier))
        let receipt: [String: Any] = [
            "shortcut_result": message,
            "outbox_limit": webhook.outboxCap,
            "delivered_deletions": delivered.flatMap(\.batches).flatMap(\.deletedUuids),
            "delivered_sample_uuids": delivered.flatMap(\.batches).flatMap(\.samples).map(\.uuid),
            "anchor_unchanged_after_cap": committedConfig.anchorBlob == startingConfig.anchorBlob,
            "anchor_unchanged_after_delayed_observer": resumedConfig.anchorBlob == committedConfig.anchorBlob,
            "ingest_revision_before": startingConfig.ingestRevision,
            "ingest_revision_after_cap": committedConfig.ingestRevision,
            "ingest_revision_after_delayed_observer": resumedConfig.ingestRevision,
            "config_unchanged_after_delayed_observer": resumedConfig == committedConfig,
            "last_synced_unchanged_after_delayed_observer": try SyncStateDAO(database).lastSyncedAt() == lastSynced,
            "deleted_sample_queued_after_delayed_observer": try outbox.find(hkSampleUuid: deletedSample.uuid) != nil,
            "outbox_count_after_delayed_observer": try outbox.totalCount(),
        ]
        try writeArtifact(JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]),
                          named: "shortcut-cap-race-state.json")
        let retryMessage = await engine.syncFromShortcut()
        XCTAssertTrue(retryMessage.contains("queued 1 new samples; processed 1 deletions. Submitted 2"))
        XCTAssertEqual(delivered.flatMap(\.batches).flatMap(\.samples).map(\.uuid), [blockedSample.uuid])
        XCTAssertEqual(try outbox.totalCount(), 0)
        XCTAssertNotEqual(try typeDAO.anchorBlob(hkTypeId: identifier), startingConfig.anchorBlob)
    }

    @MainActor
    func testDelayedShortcutCannotStageOrReportDeletionsAfterObserverAdvances() async throws {
        let database = try AppDatabase.makeInMemory()
        _ = try configure(database, type: .stepCount)
        let identifier = HealthDataType.stepCount.identifier
        let gate = ShortcutReadGate()
        let deletedSample = sample("deleted-steps")
        var delivered: [Conduit_V1_Envelope] = []
        let engine = SyncEngine(database: database, readAnchored: { _, _, _, limit, _ in
            if limit == ShortcutSync.pageSize {
                return await gate.pause(AnchoredReader.Result(samples: [deletedSample], deletedUuids: ["stale-deletion"], newAnchor: HKQueryAnchor(fromValue: 2)))
            }
            return AnchoredReader.Result(samples: [], deletedUuids: [deletedSample.uuid], newAnchor: HKQueryAnchor(fromValue: 3))
        }, bearerToken: { "test-token" }, submitUpload: { batch, _, _ in
            if let envelope = try? Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON) { delivered.append(envelope) }
            return self.deliver(batch, database: database)
        })
        let shortcut = Task { await engine.syncFromShortcut() }
        await gate.waitUntilStarted()
        await engine.handleObserverWake(typeIdentifier: identifier)
        XCTAssertEqual(delivered.flatMap(\.batches).flatMap(\.deletedUuids), [deletedSample.uuid])
        XCTAssertEqual(try OutboxDAO(database).totalCount(), 0)
        let committedConfig = try XCTUnwrap(DataTypeConfigDAO(database).find(hkTypeId: identifier))
        await gate.resume()
        let message = await shortcut.value
        XCTAssertTrue(message.contains("Captured 1 samples; queued 0 new samples; processed 0 deletions. Submitted 0"))
        XCTAssertTrue(message.contains("Capture was bounded"))
        XCTAssertEqual(try DataTypeConfigDAO(database).find(hkTypeId: identifier), committedConfig)
        XCTAssertEqual(try OutboxDAO(database).totalCount(), 0)
        XCTAssertEqual(try StagedDailyCountDAO(database).count(), 0)
        XCTAssertEqual(delivered.count, 1)
    }

    @MainActor
    func testDestinationReplacementDuringReadSubmitsOnlyMatchingCredentials() async throws {
        let database = try AppDatabase.makeInMemory()
        var webhook = try configure(database, type: .stepCount)
        var token: String? = "old-token"
        var submissions: [(String, String)] = []
        let gate = ShortcutReadGate()
        let captured = sample("steps")
        let engine = SyncEngine(database: database,
            readAnchored: { _, _, _, _, _ in
                await gate.pause(AnchoredReader.Result(samples: [captured], deletedUuids: [], newAnchor: HKQueryAnchor(fromValue: 2)))
            }, bearerToken: { token }, submitUpload: { batch, url, credential in
                submissions.append((url, credential))
                return self.deliver(batch, database: database)
            })
        let action = Task { await engine.syncFromShortcut() }
        await gate.waitUntilStarted()
        webhook.url = "https://replacement.example/sync"
        try WebhookConfigDAO(database).save(&webhook)
        token = "replacement-token"
        await gate.resume()
        let message = await action.value
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.0, webhook.url)
        XCTAssertEqual(submissions.first?.1, "replacement-token")
        XCTAssertTrue(message.contains("Submitted 1"))
        XCTAssertEqual(try OutboxDAO(database).totalCount(), 0)
    }

    @MainActor
    func testMissingCredentialKeepsQueuePendingAtSharedFlushBoundary() async throws {
        let database = try AppDatabase.makeInMemory()
        let webhook = try configure(database, type: .stepCount)
        try OutboxDAO(database).enqueue(sample: sample("queued"), hkTypeId: HealthDataType.stepCount.identifier,
            webhookId: try XCTUnwrap(webhook.id))
        let engine = SyncEngine(database: database, bearerToken: { nil }, submitUpload: { _, _, _ in
            XCTFail("A missing credential must not submit a batch")
            return true
        })
        await engine.flushNow()
        XCTAssertEqual(try OutboxDAO(database).count(state: .pending), 1)
        XCTAssertEqual(try OutboxDAO(database).count(state: .inflight), 0)
    }

    @MainActor
    func testFailedBatchFileWriteRetainsUploaderBackoff() async throws {
        let database = try AppDatabase.makeInMemory()
        let webhook = try configure(database, type: .stepCount)
        let outbox = OutboxDAO(database)
        try outbox.enqueue(sample: sample("queued"), hkTypeId: HealthDataType.stepCount.identifier,
            webhookId: try XCTUnwrap(webhook.id))
        let uploader = Uploader.shared
        let previousDatabase = uploader.database
        uploader.database = database
        defer { uploader.database = previousDatabase }
        var submissions = 0
        var uploaderOutcome: OutboxRow?
        let engine = SyncEngine(database: database, bearerToken: { "test-token" }, submitUpload: { batch, url, token in
            submissions += 1
            let blockedFile = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-batch-\(batch.batchID).json")
            do {
                try FileManager.default.createDirectory(at: blockedFile, withIntermediateDirectories: false)
            } catch {
                XCTFail("Could not create the failing-write fixture: \(error)")
                return false
            }
            defer { try? FileManager.default.removeItem(at: blockedFile) }
            let submitted = uploader.upload(batch: batch, webhookURL: url, bearerToken: token)
            XCTAssertFalse(submitted)
            uploaderOutcome = try? outbox.find(hkSampleUuid: "queued")
            return submitted
        })
        await engine.flushNow()
        let outcome = try XCTUnwrap(uploaderOutcome)
        let retained = try XCTUnwrap(outbox.find(hkSampleUuid: "queued"))
        XCTAssertEqual(retained, outcome)
        XCTAssertEqual(retained.state, .pending)
        XCTAssertNil(retained.batchId)
        XCTAssertEqual(retained.attemptCount, 1)
        XCTAssertGreaterThan(try XCTUnwrap(retained.nextAttemptAt), Date())
        XCTAssertFalse(try XCTUnwrap(retained.lastError).isEmpty)
        await engine.flushNow()
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(try outbox.find(hkSampleUuid: "queued"), retained)
    }

    private func queueRetry(_ database: AppDatabase, webhook: WebhookConfig) throws -> OutboxRow {
        let outbox = OutboxDAO(database)
        try outbox.enqueue(sample: sample("retry"), hkTypeId: HealthDataType.stepCount.identifier,
            webhookId: try XCTUnwrap(webhook.id))
        var row = try XCTUnwrap(outbox.find(hkSampleUuid: "retry"))
        row.attemptCount = 2
        row.nextAttemptAt = Date().addingTimeInterval(-60)
        row.lastError = "Earlier upload failed"
        try database.dbWriter.write { try row.update($0) }
        return try XCTUnwrap(outbox.find(hkSampleUuid: "retry"))
    }

    @MainActor
    func testRejectedDestinationSnapshotPreservesQueuedRetryState() async throws {
        let database = try AppDatabase.makeInMemory()
        let webhook = try configure(database, type: .stepCount)
        let before = try queueRetry(database, webhook: webhook)
        let outbox = OutboxDAO(database)
        let engine = SyncEngine(database: database, bearerToken: {
            (try? outbox.count(state: .inflight)) == 1 ? "replacement-token" : "original-token"
        }, submitUpload: { _, _, _ in
            XCTFail("A rejected credential snapshot must not submit")
            return true
        })
        await engine.flushNow()
        let after = try XCTUnwrap(outbox.find(hkSampleUuid: "retry"))
        XCTAssertEqual(after, before)
    }

    @MainActor
    func testShortcutCancelledAfterBatchBuildDoesNotSubmitOrEraseRetryState() async throws {
        let database = try AppDatabase.makeInMemory()
        let webhook = try configure(database, type: .stepCount)
        let before = try queueRetry(database, webhook: webhook)
        let outbox = OutboxDAO(database)
        var cancelledAfterBuild = false
        let engine = SyncEngine(database: database, readAnchored: { _, _, _, _, _ in
            AnchoredReader.Result(samples: [], deletedUuids: [], newAnchor: HKQueryAnchor(fromValue: 2))
        }, bearerToken: {
            if (try? outbox.count(state: .inflight)) == 1 {
                cancelledAfterBuild = true
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return "test-token"
        }, submitUpload: { _, _, _ in
            XCTFail("Cancellation after batch construction must not start an upload")
            return true
        })
        let action = Task { await engine.syncFromShortcut() }
        let message = await action.value
        XCTAssertTrue(cancelledAfterBuild)
        XCTAssertTrue(message.contains("Submitted 0"))
        XCTAssertEqual(try outbox.find(hkSampleUuid: "retry"), before)
    }

    private func enrichedWorkout(_ uuid: String) -> Conduit_V1_Sample {
        var result = sample(uuid)
        result.workout = AnchoredReader.makeWorkoutValue(activityType: "running", durationSeconds: 600,
            totalEnergyKcal: 100, totalDistanceM: 1000, brandName: "Watch", isIndoor: false,
            avgHeartRateBpm: 130, maxHeartRateBpm: 160, minHeartRateBpm: 90, events: [])
        return result
    }

    @MainActor
    func testHeartRateDisabledDuringWorkoutReadIsAbsentFromSubmittedPayload() async throws {
        let database = try AppDatabase.makeInMemory()
        _ = try configure(database, type: .workout)
        try enable(database, type: .heartRate)
        let gate = ShortcutReadGate()
        let captured = enrichedWorkout("workout")
        var uploaded: Conduit_V1_Sample?
        let engine = SyncEngine(database: database, readAnchored: { type, _, _, _, includeHR in
            if type.stream != .workout { return AnchoredReader.Result(samples: [], deletedUuids: [], newAnchor: HKQueryAnchor(fromValue: 2)) }
            XCTAssertTrue(includeHR)
            return await gate.pause(AnchoredReader.Result(samples: [captured], deletedUuids: [], newAnchor: HKQueryAnchor(fromValue: 2)))
        }, bearerToken: { "test-token" }, submitUpload: { batch, _, _ in
            uploaded = try? Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON).batches
                .first { $0.hkTypeID == HealthDataType.workout.identifier }?.samples.first
            return self.deliver(batch, database: database)
        })
        let action = Task { await engine.syncFromShortcut() }
        await gate.waitUntilStarted()
        try DataTypeConfigDAO(database).setEnabled(false, hkTypeId: HealthDataType.heartRate.identifier)
        await gate.resume()
        _ = await action.value
        let value = try XCTUnwrap(uploaded).workout
        XCTAssertFalse(value.hasAvgHeartRateBpm)
        XCTAssertFalse(value.hasMaxHeartRateBpm)
        XCTAssertFalse(value.hasMinHeartRateBpm)
        XCTAssertEqual(value.brandName, "Watch")
        XCTAssertEqual(value.totalDistanceM, 1000)
    }

    func testSharedImportStagingUsesCurrentHeartRatePermission() throws {
        let database = try AppDatabase.makeInMemory()
        let webhook = try configure(database, type: .workout)
        let identifier = HealthDataType.workout.identifier
        let outbox = OutboxDAO(database)
        try DataTypeConfigDAO(database).setEnabled(true, hkTypeId: HealthDataType.heartRate.identifier)
        _ = try outbox.stageImport(samples: [enrichedWorkout("allowed")], hkTypeId: identifier,
            webhookId: try XCTUnwrap(webhook.id))
        try DataTypeConfigDAO(database).setEnabled(false, hkTypeId: HealthDataType.heartRate.identifier)
        _ = try outbox.stageImport(samples: [enrichedWorkout("disabled")], hkTypeId: identifier,
            webhookId: try XCTUnwrap(webhook.id))
        let payloads = try rows(database).map { try Conduit_V1_Sample(jsonUTF8Data: $0.payloadBlob) }
        let allowed = try XCTUnwrap(payloads.first { $0.uuid == "allowed" }).workout
        XCTAssertEqual(allowed.avgHeartRateBpm, 130)
        XCTAssertEqual(allowed.maxHeartRateBpm, 160)
        XCTAssertEqual(allowed.minHeartRateBpm, 90)
        let disabled = try XCTUnwrap(payloads.first { $0.uuid == "disabled" }).workout
        XCTAssertFalse(disabled.hasAvgHeartRateBpm)
        XCTAssertFalse(disabled.hasMaxHeartRateBpm)
        XCTAssertFalse(disabled.hasMinHeartRateBpm)
    }

    @MainActor
    func testShortcutsCannotInitializeThroughBackdatedRecordsBetweenPages() async throws {
        let database = try AppDatabase.makeInMemory()
        _ = try configure(database, type: .stepCount, initialized: false)
        let floor = SyncEngine.forwardCaptureFloor()
        let today = floor.addingTimeInterval(1)
        let records = (0..<ShortcutSync.pageSize).map { sample("today-\($0)", end: today) }
            + [sample("pre-existing-backdated", end: floor.addingTimeInterval(-86_400)), sample("today-last", end: today)]
        var nextOffset = 0
        var limits: [Int] = []
        let engine = SyncEngine(database: database, readAnchored: { _, anchor, since, limit, _ in
            limits.append(limit)
            let start = anchor == nil ? 0 : nextOffset
            let lower = since.map(AnchoredReader.unixMillis) ?? Int64.min
            let eligible = records.enumerated().filter { index, record in
                index >= start && (anchor != nil || record.endUnixMs >= lower)
            }
            let page = Array(eligible.prefix(limit == HKObjectQueryNoLimit ? records.count : limit))
            nextOffset = page.last.map { $0.offset + 1 } ?? records.count
            return AnchoredReader.Result(samples: page.map(\.element), deletedUuids: [], newAnchor: HKQueryAnchor(fromValue: nextOffset))
        }, bearerToken: { "test-token" }, submitUpload: { _, _, _ in false })
        for _ in 0..<2 {
            let message = await engine.syncFromShortcut()
            XCTAssertTrue(message.contains("Steps is not yet initialized"))
            XCTAssertEqual(try OutboxDAO(database).totalCount(), 0)
            let config = try XCTUnwrap(DataTypeConfigDAO(database).find(hkTypeId: HealthDataType.stepCount.identifier))
            XCTAssertNil(config.anchorBlob)
            XCTAssertNil(config.captureStartedAt)
        }
        XCTAssertTrue(limits.isEmpty)
        await engine.handleObserverWake(typeIdentifier: HealthDataType.stepCount.identifier)
        _ = await engine.syncFromShortcut()
        XCTAssertEqual(limits, [HKObjectQueryNoLimit, ShortcutSync.pageSize])
        let staged = try rows(database).map(\.hkSampleUuid)
        XCTAssertEqual(staged.count, ShortcutSync.pageSize + 1)
        XCTAssertFalse(staged.contains("pre-existing-backdated"))
        XCTAssertTrue(staged.contains("today-last"))
    }

    @MainActor
    func testUninitializedTypeDoesNotBlockInitializedTypes() async throws {
        let database = try AppDatabase.makeInMemory()
        _ = try configure(database, type: .heartRate, initialized: false)
        try enable(database, type: .stepCount)
        var reads: [String] = []
        let captured = sample("initialized-steps")
        let engine = SyncEngine(database: database, readAnchored: { type, _, _, _, _ in
            reads.append(type.identifier)
            return AnchoredReader.Result(samples: [captured], deletedUuids: [], newAnchor: HKQueryAnchor(fromValue: 2))
        }, bearerToken: { "test-token" }, submitUpload: { _, _, _ in false })
        let message = await engine.syncFromShortcut()
        XCTAssertEqual(reads, [HealthDataType.stepCount.identifier])
        XCTAssertTrue(message.contains("Heart Rate is not yet initialized"))
        XCTAssertEqual(try OutboxDAO(database).totalCount(), 1)
    }

    @MainActor
    func testUnavailableTypeIsSkippedBeforeInitializationAdvice() async throws {
        let unavailable = HealthDataType.heartRateVariabilityRMSSD
        if #available(iOS 27, *) { throw XCTSkip("RMSSD is available on iOS 27") }
        XCTAssertNil(unavailable.sampleType)
        let database = try AppDatabase.makeInMemory()
        _ = try configure(database, type: unavailable, initialized: false)
        try enable(database, type: .stepCount)
        try enable(database, type: .heartRate, initialized: false)
        let captured = sample("available-steps")
        var reads: [String] = []
        let engine = SyncEngine(database: database, readAnchored: { type, _, _, _, _ in
            reads.append(type.identifier)
            return AnchoredReader.Result(samples: [captured], deletedUuids: [], newAnchor: HKQueryAnchor(fromValue: 2))
        }, bearerToken: { "test-token" }, submitUpload: { batch, _, _ in self.deliver(batch, database: database) })
        let message = await engine.syncFromShortcut()
        XCTAssertEqual(reads, [HealthDataType.stepCount.identifier])
        XCTAssertTrue(message.contains("Heart Rate is not yet initialized"))
        XCTAssertFalse(message.contains(unavailable.displayName))
        XCTAssertTrue(message.contains("queued 1 new samples"))
        XCTAssertTrue(message.contains("Submitted 1"))
        let skipped = try XCTUnwrap(DataTypeConfigDAO(database).find(hkTypeId: unavailable.identifier))
        XCTAssertNil(skipped.anchorBlob)
        XCTAssertNil(skipped.captureStartedAt)
        XCTAssertNil(skipped.lastSyncAt)
        XCTAssertEqual(try OutboxDAO(database).totalCount(), 0)
    }

    @MainActor
    func testDeliveredRoutesAreMemoizedAcrossShortcutsAndObserver() async throws {
        let database = try AppDatabase.makeInMemory()
        _ = try configure(database, type: .workoutRoute)
        try enable(database, type: .workout)
        let workout = HKWorkout(activityType: .running, start: Date().addingTimeInterval(-600), end: Date())
        let route = routeSample("route", workout: workout)
        var reads = 0
        var deliveries = 0
        let engine = SyncEngine(database: database, readAnchored: { _, _, _, _, _ in
            AnchoredReader.Result(samples: [], deletedUuids: [], newAnchor: HKQueryAnchor(fromValue: 2))
        }, scanWorkouts: { _, _, _ in [workout] }, readRoutes: { _ in reads += 1; return [route] },
            bearerToken: { "test-token" }, submitUpload: { batch, _, _ in
                deliveries += 1
                return self.deliver(batch, database: database)
            })
        _ = await engine.syncFromShortcut()
        XCTAssertEqual(try OutboxDAO(database).totalCount(), 0)
        _ = await engine.syncFromShortcut()
        await engine.handleObserverWake(typeIdentifier: HealthDataType.workout.identifier)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(deliveries, 1)
    }

    @MainActor
    func testEmptyAndPartiallyStagedRoutesRemainRetryable() async throws {
        let database = try AppDatabase.makeInMemory()
        _ = try configure(database, type: .workoutRoute, cap: 1)
        let workout = HKWorkout(activityType: .running, start: Date().addingTimeInterval(-600), end: Date())
        let routes = [routeSample("route-a", workout: workout), routeSample("route-b", workout: workout)]
        var reads = 0
        var delivered: [String] = []
        let engine = SyncEngine(database: database, scanWorkouts: { _, _, _ in [workout] }, readRoutes: { _ in
            reads += 1
            return reads == 1 ? [] : routes
        }, bearerToken: { "test-token" }, submitUpload: { batch, _, _ in
            if let envelope = try? Conduit_V1_Envelope(jsonUTF8Data: batch.encodedJSON) {
                delivered += envelope.batches.flatMap(\.samples).map(\.uuid)
            }
            return self.deliver(batch, database: database)
        })
        _ = await engine.syncFromShortcut()
        _ = await engine.syncFromShortcut()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(delivered, ["route-a"])
        var webhook = try XCTUnwrap(WebhookConfigDAO(database).first())
        webhook.outboxCap = 10
        try WebhookConfigDAO(database).save(&webhook)
        _ = await engine.syncFromShortcut()
        _ = await engine.syncFromShortcut()
        XCTAssertEqual(reads, 3)
        XCTAssertTrue(delivered.contains("route-b"))
        XCTAssertEqual(try OutboxDAO(database).totalCount(), 0)
    }
}

private actor ShortcutReadGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var readWaiter: CheckedContinuation<Void, Never>?

    func pause(_ result: AnchoredReader.Result) async -> AnchoredReader.Result {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { readWaiter = $0 }
        return result
    }

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }

    func resume() {
        readWaiter?.resume()
        readWaiter = nil
    }
}
