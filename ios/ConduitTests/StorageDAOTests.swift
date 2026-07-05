import XCTest
import GRDB
@testable import Conduit

/// Coverage for the WebhookConfig and DataTypeConfig DAO methods.
final class StorageDAOTests: XCTestCase {
    private var appDB: AppDatabase!

    override func setUpWithError() throws {
        appDB = try AppDatabase.makeInMemory()
    }

    // MARK: - WebhookConfigDAO

    func testWebhookSaveInsertsAssignsIdAndFinds() throws {
        let dao = WebhookConfigDAO(appDB)
        var config = WebhookConfig.makeDefault(url: "https://a.example/hook", bearerTokenKeychainRef: "ref")
        try dao.save(&config)

        let id = try XCTUnwrap(config.id, "save should assign an autoincrement id")
        XCTAssertEqual(try dao.find(id: id)?.url, "https://a.example/hook")
    }

    func testWebhookSaveUpdatesExistingRow() throws {
        let dao = WebhookConfigDAO(appDB)
        var config = WebhookConfig.makeDefault(url: "https://a.example/hook", bearerTokenKeychainRef: "ref")
        try dao.save(&config)

        config.url = "https://b.example/hook"
        try dao.save(&config)

        XCTAssertEqual(try dao.all().count, 1, "Updating must not create a second row")
        XCTAssertEqual(try dao.find(id: try XCTUnwrap(config.id))?.url, "https://b.example/hook")
    }

    func testWebhookFirstReturnsMostRecentlyCreated() throws {
        let dao = WebhookConfigDAO(appDB)
        var older = WebhookConfig.makeDefault(url: "https://old.example", bearerTokenKeychainRef: "ref", now: Date(timeIntervalSince1970: 1_000))
        var newer = WebhookConfig.makeDefault(url: "https://new.example", bearerTokenKeychainRef: "ref", now: Date(timeIntervalSince1970: 2_000))
        try dao.save(&older)
        try dao.save(&newer)

        XCTAssertEqual(try dao.first()?.url, "https://new.example")
    }

    func testWebhookDeleteRemovesRow() throws {
        let dao = WebhookConfigDAO(appDB)
        var config = WebhookConfig.makeDefault(url: "https://a.example/hook", bearerTokenKeychainRef: "ref")
        try dao.save(&config)
        let id = try XCTUnwrap(config.id)

        XCTAssertTrue(try dao.delete(id: id))
        XCTAssertNil(try dao.find(id: id))
        XCTAssertFalse(try dao.delete(id: id), "Deleting a missing row returns false")
    }

    // MARK: - DataTypeConfigDAO

    func testDataTypeUpsertAndFind() throws {
        let dao = DataTypeConfigDAO(appDB)
        let config = DataTypeConfig(
            hkTypeId: HealthDataType.stepCount.identifier,
            enabled: true,
            minIntervalSeconds: 300,
            anchorBlob: nil,
            lastSyncAt: nil,
            lastAttemptAt: nil
        )
        try dao.upsert(config)

        let fetched = try dao.find(hkTypeId: HealthDataType.stepCount.identifier)
        XCTAssertEqual(fetched?.enabled, true)
        XCTAssertEqual(fetched?.minIntervalSeconds, 300)
    }

    func testDataTypeSetEnabledCreatesThenTogglesPreservingState() throws {
        let dao = DataTypeConfigDAO(appDB)
        let id = HealthDataType.heartRate.identifier

        try dao.setEnabled(true, hkTypeId: id)
        XCTAssertEqual(try dao.find(hkTypeId: id)?.enabled, true)
        XCTAssertEqual(try dao.enabled().count, 1)

        try dao.setEnabled(false, hkTypeId: id)
        XCTAssertEqual(try dao.find(hkTypeId: id)?.enabled, false)
        XCTAssertEqual(try dao.enabled().count, 0)
        XCTAssertEqual(try dao.all().count, 1, "Toggling must not duplicate the row")
    }

    func testDataTypeAnchorBlobAccessor() throws {
        let dao = DataTypeConfigDAO(appDB)
        let id = HealthDataType.heartRate.identifier
        try dao.upsert(DataTypeConfig(
            hkTypeId: id,
            enabled: true,
            minIntervalSeconds: nil,
            anchorBlob: Data([0xAB, 0xCD]),
            lastSyncAt: nil,
            lastAttemptAt: nil
        ))

        XCTAssertEqual(try dao.anchorBlob(hkTypeId: id), Data([0xAB, 0xCD]))
        XCTAssertNil(try dao.anchorBlob(hkTypeId: "unknown"))
    }

    func testSetCaptureStartedAtPersistsFloor() throws {
        let dao = DataTypeConfigDAO(appDB)
        let id = HealthDataType.heartRate.identifier
        try dao.setEnabled(true, hkTypeId: id)

        let floor = Date(timeIntervalSince1970: 1_700_000_000)
        try dao.setCaptureStartedAt(floor, hkTypeId: id)

        XCTAssertEqual(try dao.find(hkTypeId: id)?.captureStartedAt, floor)
    }

    func testCaptureStartedAtSurvivesAnchorAdvance() throws {
        // The forward-only floor is set once on the first read; ongoing ingests
        // (advanceAnchor) must NOT clobber it, so a relaunch reuses the same
        // floor rather than re-seeding to a fresh "now".
        let dao = DataTypeConfigDAO(appDB)
        let id = HealthDataType.heartRate.identifier
        try dao.setEnabled(true, hkTypeId: id)
        let floor = Date(timeIntervalSince1970: 1_700_000_000)
        try dao.setCaptureStartedAt(floor, hkTypeId: id)

        try appDB.dbWriter.write { db in
            try DataTypeConfigDAO.advanceAnchor(db, hkTypeId: id, anchorBlob: Data([0x42]), syncedAt: Date())
        }

        let config = try dao.find(hkTypeId: id)
        XCTAssertEqual(config?.captureStartedAt, floor, "advanceAnchor must preserve the capture floor")
        XCTAssertEqual(config?.anchorBlob, Data([0x42]))
    }

    func testResetAllAnchorsClearsAnchorFloorAndTimestamps() throws {
        let dao = DataTypeConfigDAO(appDB)
        let hr = HealthDataType.heartRate.identifier
        let steps = HealthDataType.stepCount.identifier
        for id in [hr, steps] {
            try dao.setEnabled(true, hkTypeId: id)
            try dao.setCaptureStartedAt(Date(timeIntervalSince1970: 1_000), hkTypeId: id)
            try appDB.dbWriter.write { db in
                try DataTypeConfigDAO.advanceAnchor(db, hkTypeId: id, anchorBlob: Data([0x01]), syncedAt: Date())
            }
        }

        try dao.resetAllAnchors()

        for id in [hr, steps] {
            let config = try XCTUnwrap(dao.find(hkTypeId: id))
            XCTAssertNil(config.anchorBlob, "anchor must be cleared so the next read re-seeds forward")
            XCTAssertNil(config.captureStartedAt, "capture floor must be cleared so re-seed uses a fresh now")
            XCTAssertNil(config.lastSyncAt)
            XCTAssertNil(config.lastAttemptAt)
            XCTAssertTrue(config.enabled, "reset must leave the type enabled")
        }
    }

    func testAdvanceAnchorPreservesEnabledFlag() throws {
        let dao = DataTypeConfigDAO(appDB)
        let id = HealthDataType.heartRate.identifier
        try dao.setEnabled(true, hkTypeId: id)

        try appDB.dbWriter.write { db in
            try DataTypeConfigDAO.advanceAnchor(db, hkTypeId: id, anchorBlob: Data([0x09]), syncedAt: Date())
        }

        let config = try dao.find(hkTypeId: id)
        XCTAssertEqual(config?.enabled, true, "advanceAnchor must not flip the enabled flag")
        XCTAssertEqual(config?.anchorBlob, Data([0x09]))
        XCTAssertNotNil(config?.lastSyncAt)
    }
}
