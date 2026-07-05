import Foundation
import GRDB
import SwiftProtobuf

/// CRUD for `outbox` rows (ARCHITECTURE.md §4.7).
///
/// The outbox is the durable staging area between HealthKit reads and webhook
/// delivery. Its two correctness-critical behaviours both live here:
///
/// 1. **Dedupe** — `enqueue` is `INSERT OR IGNORE` on the UNIQUE
///    `hk_sample_uuid`, so re-observed samples never produce duplicate rows.
/// 2. **Atomic ingest** — `ingest(...)` enqueues a batch of samples *and*
///    advances the type's HealthKit anchor in a single transaction (§4.4).
struct OutboxDAO {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    // MARK: - Enqueue (dedupe)

    /// Enqueue a single sample within an existing transaction.
    ///
    /// Uses `INSERT OR IGNORE` on `hk_sample_uuid`; returns `true` if a new row
    /// was inserted, `false` if it was a duplicate that was ignored.
    ///
    /// When a *new* row is inserted this also bumps the persisted
    /// `staged_daily_count` tally for `createdAt`'s local day, in the SAME
    /// transaction. This is the single choke point through which every staging
    /// path (`ingest`, `stageImport`, the convenience `enqueue`) flows, so the
    /// "Staged today" counter can never drift from what was actually staged, and
    /// — because duplicates return early without incrementing — it never
    /// double-counts a re-observed sample. See `StagedDailyCountDAO`.
    @discardableResult
    static func enqueue(
        _ db: Database,
        sample: Conduit_V1_Sample,
        hkTypeId: String,
        webhookId: Int64,
        createdAt: Date
    ) throws -> Bool {
        let payload = try sample.jsonUTF8Data()
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO outbox
                    (webhook_id, hk_sample_uuid, hk_type_id, payload_blob,
                     created_at, state, attempt_count)
                VALUES (?, ?, ?, ?, ?, ?, 0)
                """,
            arguments: [
                webhookId,
                sample.uuid,
                hkTypeId,
                payload,
                createdAt,
                OutboxState.pending.rawValue,
            ]
        )
        let inserted = db.changesCount > 0
        if inserted {
            try StagedDailyCountDAO.increment(db, enqueuedAt: createdAt, by: 1)
        }
        return inserted
    }

    /// Convenience enqueue that opens its own write transaction.
    @discardableResult
    func enqueue(
        sample: Conduit_V1_Sample,
        hkTypeId: String,
        webhookId: Int64,
        createdAt: Date = Date()
    ) throws -> Bool {
        try database.dbWriter.write { db in
            try OutboxDAO.enqueue(
                db,
                sample: sample,
                hkTypeId: hkTypeId,
                webhookId: webhookId,
                createdAt: createdAt
            )
        }
    }

    // MARK: - Atomic ingest (§4.4 critical invariant)

    /// Persist the result of an `AnchoredReader.read(...)`: enqueue every sample
    /// **and** advance the type's anchor in **one** transaction.
    ///
    /// This is the single most important correctness property of Phase I2.
    /// Persisting the anchor without the samples (or vice versa, across two
    /// transactions) permanently loses data: a crash between the two writes
    /// would advance past samples that were never staged. GRDB's `write` block
    /// is one SQLite transaction, so either everything here commits or nothing
    /// does.
    ///
    /// - Parameters:
    ///   - cap: optional hard limit on total outbox rows. When set and the
    ///     outbox is already at/over `cap`, ingest stops staging further samples
    ///     as back-pressure. Crucially, if the cap forces us to drop any sample
    ///     the anchor is **NOT** advanced (see below) so nothing is lost. `nil`
    ///     disables the guard.
    /// - Returns: the number of *newly* inserted (non-duplicate) rows.
    @discardableResult
    func ingest(
        samples: [Conduit_V1_Sample],
        hkTypeId: String,
        webhookId: Int64,
        anchorBlob: Data?,
        cap: Int? = nil,
        syncedAt: Date = Date()
    ) throws -> Int {
        try database.dbWriter.write { db in
            var insertedCount = 0
            var currentTotal = cap != nil ? try OutboxRow.fetchCount(db) : 0
            var droppedForCap = false
            for sample in samples {
                if let cap, currentTotal >= cap {
                    // Outbox at capacity — stop staging. The anchor is left
                    // un-advanced below so these samples come back next read.
                    droppedForCap = true
                    break
                }
                let inserted = try OutboxDAO.enqueue(
                    db,
                    sample: sample,
                    hkTypeId: hkTypeId,
                    webhookId: webhookId,
                    createdAt: syncedAt
                )
                if inserted {
                    insertedCount += 1
                    currentTotal += 1
                }
            }
            // §4.4 invariant: advancing the anchor only "counts" if the enqueues
            // above also committed — AND only if we staged the ENTIRE batch. If
            // the cap forced us to drop samples, leaving the anchor put means the
            // dropped samples are re-delivered on a later read once the outbox
            // has drained, so back-pressure never loses data.
            if !droppedForCap {
                try DataTypeConfigDAO.advanceAnchor(
                    db,
                    hkTypeId: hkTypeId,
                    anchorBlob: anchorBlob,
                    syncedAt: syncedAt
                )
            }
            return insertedCount
        }
    }

    // MARK: - Import staging (enqueue-only, forward anchor untouched)

    /// Enqueue a page of samples from an **explicit historical import** WITHOUT
    /// advancing any HealthKit anchor (ARCHITECTURE.md §4.4, "Import history"
    /// opt-in). This is the deliberate sibling to `ingest(...)`: the live
    /// forward-capture anchor in `data_type_config` is left completely untouched,
    /// so importing history never rewinds ongoing incremental capture. UUID
    /// dedupe (`INSERT OR IGNORE`) means samples the forward stream already
    /// staged are silently skipped, so the import and the live stream can't
    /// double-stage the same sample.
    ///
    /// `cap` enforces the same outbox back-pressure guard as `ingest`: once the
    /// outbox is at/over `cap`, staging stops and `hitCap` is `true` so the
    /// caller can stop paging. Because no anchor is advanced here, nothing is
    /// lost by stopping — a later import (or the forward stream) re-reads the
    /// remaining samples once the outbox drains.
    ///
    /// - Returns: the number of newly inserted (non-duplicate) rows and whether
    ///   the cap halted staging mid-page.
    @discardableResult
    func stageImport(
        samples: [Conduit_V1_Sample],
        hkTypeId: String,
        webhookId: Int64,
        cap: Int? = nil,
        syncedAt: Date = Date()
    ) throws -> (inserted: Int, hitCap: Bool) {
        try database.dbWriter.write { db in
            var insertedCount = 0
            var currentTotal = cap != nil ? try OutboxRow.fetchCount(db) : 0
            var hitCap = false
            for sample in samples {
                if let cap, currentTotal >= cap {
                    hitCap = true
                    break
                }
                let inserted = try OutboxDAO.enqueue(
                    db,
                    sample: sample,
                    hkTypeId: hkTypeId,
                    webhookId: webhookId,
                    createdAt: syncedAt
                )
                if inserted {
                    insertedCount += 1
                    currentTotal += 1
                }
            }
            // Intentionally NO advanceAnchor: the forward anchor is owned by the
            // observer-wake path and must not move for an import.
            return (insertedCount, hitCap)
        }
    }

    // MARK: - Purge (one-time remediation)

    /// Delete **every** outbox row regardless of state (pending, inflight, sent,
    /// failed). Used by the one-time "Reset sync" remediation to drain a device
    /// that staged its full Health history under the old all-history backfill;
    /// pair it with `DataTypeConfigDAO.resetAllAnchors()` so capture resumes
    /// forward-only. An in-flight background upload that completes afterward is
    /// harmless — its `UPDATE ... WHERE id IN (...)` simply matches no rows.
    ///
    /// - Returns: the number of rows deleted.
    @discardableResult
    func deleteAll() throws -> Int {
        try database.dbWriter.write { db in
            try OutboxRow.deleteAll(db)
        }
    }

    // MARK: - Queries

    /// Rows ready to be flushed: `pending` and whose backoff window has elapsed,
    /// oldest first. Uses the `(state, next_attempt_at)` index.
    func readyToSend(limit: Int, now: Date = Date()) throws -> [OutboxRow] {
        try database.dbWriter.read { db in
            try OutboxRow
                .filter(Column("state") == OutboxState.pending.rawValue)
                .filter(Column("next_attempt_at") == nil || Column("next_attempt_at") <= now)
                .order(Column("created_at").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func count(state: OutboxState) throws -> Int {
        try database.dbWriter.read { db in
            try OutboxRow
                .filter(Column("state") == state.rawValue)
                .fetchCount(db)
        }
    }

    func totalCount() throws -> Int {
        try database.dbWriter.read { db in
            try OutboxRow.fetchCount(db)
        }
    }

    func find(hkSampleUuid: String) throws -> OutboxRow? {
        try database.dbWriter.read { db in
            try OutboxRow
                .filter(Column("hk_sample_uuid") == hkSampleUuid)
                .fetchOne(db)
        }
    }

    /// Update the delivery state of a set of rows (used by the uploader in I3).
    func updateState(
        ids: [Int64],
        to state: OutboxState,
        batchId: String? = nil,
        nextAttemptAt: Date? = nil,
        lastError: String? = nil
    ) throws {
        guard !ids.isEmpty else { return }
        try database.dbWriter.write { db in
            _ = try OutboxRow
                .filter(ids.contains(Column("id")))
                .updateAll(
                    db,
                    Column("state").set(to: state.rawValue),
                    Column("batch_id").set(to: batchId),
                    Column("next_attempt_at").set(to: nextAttemptAt),
                    Column("last_error").set(to: lastError)
                )
        }
    }
}

/// Reads/writes the persisted per-local-day "staged today" tally
/// (`staged_daily_count`, migration `v4-staged-daily-count`).
///
/// Why a dedicated counter rather than counting outbox rows? Since #505 a
/// successful upload DELETES the delivered outbox row, so "count today's rows
/// still in the outbox" collapses to the live Pending count and *shrinks* as the
/// queue drains — it can no longer answer "how many samples were staged today?".
/// This tally is bumped in the same transaction as each enqueue (see
/// `OutboxDAO.enqueue`), so it is exact, monotonic within a day, and independent
/// of upload/delete state. It resets naturally at the local-day boundary because
/// each day gets its own bucket row.
struct StagedDailyCountDAO {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    /// Local start-of-day bucket key for an enqueue instant.
    static func day(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Increment the tally for `enqueuedAt`'s local day by `amount`, within an
    /// existing transaction. Upsert: creates the day's row on first stage, then
    /// accumulates. Must be called from inside the same write that inserted the
    /// outbox row so the count can't diverge from staged rows.
    static func increment(
        _ db: Database,
        enqueuedAt: Date,
        by amount: Int,
        calendar: Calendar = .current
    ) throws {
        guard amount != 0 else { return }
        try db.execute(
            sql: """
                INSERT INTO staged_daily_count (day, count)
                VALUES (?, ?)
                ON CONFLICT(day) DO UPDATE SET count = count + excluded.count
                """,
            arguments: [day(for: enqueuedAt, calendar: calendar), amount]
        )
    }

    /// The tally for the local day containing `date` (default: today). Returns 0
    /// when nothing has been staged that day.
    func count(on date: Date = Date(), calendar: Calendar = .current) throws -> Int {
        try database.dbWriter.read { db in
            try StagedDailyCountDAO.count(db, on: date, calendar: calendar)
        }
    }

    /// The tally for a given local day, readable inside an existing connection
    /// (used by `HomeViewModel`'s `ValueObservation`).
    static func count(
        _ db: Database,
        on date: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT count FROM staged_daily_count WHERE day = ?",
            arguments: [day(for: date, calendar: calendar)]
        ) ?? 0
    }

    /// Wipe every day's tally. Paired with `OutboxDAO.deleteAll()` in the
    /// destructive "Reset Sync & Clear Queue" remediation so the counter starts
    /// fresh alongside the emptied outbox.
    @discardableResult
    func deleteAll() throws -> Int {
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM staged_daily_count")
            return db.changesCount
        }
    }
}
