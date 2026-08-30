import Foundation
import GRDB

/// Durable state for the explicit "Import history" opt-in: the run-level status
/// the UI reports and the per-type paging cursors that make an interrupted
/// import **resumable** instead of a full restart.
///
/// ## Why this is a table and not view state
/// The importer's paging cursor used to live only in a local `var` inside
/// `HistoryImporter.run`, so backgrounding, force-quitting or crashing mid-import
/// threw away the resume point: the next run started again from the newest end
/// and re-read everything. Worse, an import that FAILED reported a
/// success-shaped summary, so the UI showed a green "Imported N samples" over a
/// silently truncated history. Both are fixed by persisting progress and a
/// terminal outcome here, and by reading the status back from this table (never
/// from in-memory view state) when the screen loads.
///
/// This store is completely separate from `data_type_config` — an import never
/// touches a forward-capture anchor (ARCHITECTURE.md §4.4), and nothing here can
/// affect ordinary sync.
struct ImportProgressDAO {
    /// The one and only `import_run` row's primary key.
    static let singletonID: Int64 = 1

    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    // MARK: - Run

    func currentRun() throws -> ImportRunState? {
        try database.dbWriter.read { db in
            try ImportRunState.fetchOne(db, key: ImportProgressDAO.singletonID)
        }
    }

    /// Begin a brand-new run, discarding any earlier run's per-type cursors so a
    /// stale resume point from a different range can never be reused.
    @discardableResult
    func beginRun(
        runId: String,
        rangeId: String,
        rangeStart: Date?,
        typesTotal: Int,
        now: Date = Date()
    ) throws -> ImportRunState {
        let run = ImportRunState(
            id: ImportProgressDAO.singletonID,
            runId: runId,
            rangeId: rangeId,
            rangeStart: rangeStart,
            status: .running,
            stagedCount: 0,
            failureReason: nil,
            typesTotal: typesTotal,
            typesCompleted: 0,
            oldestReachedAt: nil,
            // A run that is actively being driven has nothing to auto-resume yet;
            // the flag is set (or cleared) when it stops, by whatever stopped it.
            autoResume: false,
            stopCause: nil,
            startedAt: now,
            updatedAt: now
        )
        try database.dbWriter.write { db in
            try ImportTypeProgress.deleteAll(db)
            try run.save(db)
        }
        return run
    }

    /// Mark an existing run as running again (resume) without touching its
    /// per-type cursors — that is what makes the resume continue rather than
    /// restart. Clears any previous failure reason.
    func resumeRun(now: Date = Date()) throws {
        try database.dbWriter.write { db in
            guard var run = try ImportRunState.fetchOne(db, key: ImportProgressDAO.singletonID) else { return }
            run.status = .running
            run.failureReason = nil
            // Being driven again supersedes the pause that set the flag; whatever
            // stops this pass records the answer afresh.
            run.autoResume = false
            run.stopCause = nil
            run.updatedAt = now
            try run.update(db)
        }
    }

    /// Re-state how many types the run intends to cover, for a resume whose
    /// enabled set has changed since the run began. Keeps "N/M types finished"
    /// truthful and keeps `floorReached`'s "every type has a row" guard exact.
    func updateTypesTotal(_ typesTotal: Int, now: Date = Date()) throws {
        try database.dbWriter.write { db in
            guard var run = try ImportRunState.fetchOne(db, key: ImportProgressDAO.singletonID) else { return }
            guard run.typesTotal != typesTotal else { return }
            run.typesTotal = typesTotal
            let rows = try ImportTypeProgress.filter(Column("run_id") == run.runId).fetchAll(db)
            run.oldestReachedAt = ImportProgressDAO.floorReached(rows: rows, run: run)
            run.updatedAt = now
            try run.update(db)
        }
    }

    /// Record a terminal (or paused) outcome for the run.
    ///
    /// - Parameter autoResume: whether this stop is one the app may pick back up
    ///   on its own (an iOS-forced pause) rather than one the user chose (cancel),
    ///   one that would loop (failure), or one that needs a decision (a queue
    ///   that never drained).
    /// - Parameter stopCause: why it stopped, so the reason survives a relaunch
    ///   instead of every short run collapsing into "interrupted".
    func finishRun(
        status: ImportRunStatus,
        failureReason: String? = nil,
        autoResume: Bool = false,
        stopCause: ImportStopCause? = nil,
        now: Date = Date()
    ) throws {
        try database.dbWriter.write { db in
            guard var run = try ImportRunState.fetchOne(db, key: ImportProgressDAO.singletonID) else { return }
            run.status = status
            run.failureReason = failureReason
            run.autoResume = autoResume
            run.stopCause = stopCause
            run.updatedAt = now
            try run.update(db)
        }
    }

    /// Reconcile a run that the UI *thinks* is running but no process is driving.
    ///
    /// A `running` row surviving a relaunch means the app died mid-import, so the
    /// honest state is `interrupted` (resumable), not "running" and certainly not
    /// "complete". Call this on load whenever no import task is live.
    /// - Returns: the reconciled run, if any.
    @discardableResult
    func reconcileStaleRun(now: Date = Date()) throws -> ImportRunState? {
        try database.dbWriter.write { db in
            guard var run = try ImportRunState.fetchOne(db, key: ImportProgressDAO.singletonID) else { return nil }
            guard run.status == .running else { return run }
            run.status = .interrupted
            // The app died mid-import (force-quit, jetsam, crash) — the user never
            // asked it to stop, so this is exactly the case that should continue
            // on its own rather than wait for a tap.
            run.autoResume = true
            run.stopCause = .backgrounded
            run.updatedAt = now
            try run.update(db)
            try db.execute(
                sql: "UPDATE import_type_progress SET status = ?, updated_at = ? WHERE status = ?",
                arguments: [ImportRunStatus.interrupted.rawValue, now, ImportRunStatus.running.rawValue]
            )
            return run
        }
    }

    /// Forget the last run entirely (the "Start Over" action).
    func clear() throws {
        try database.dbWriter.write { db in
            try ImportTypeProgress.deleteAll(db)
            try ImportRunState.deleteAll(db)
        }
    }

    // MARK: - Per type

    func typeProgress(hkTypeId: String) throws -> ImportTypeProgress? {
        try database.dbWriter.read { db in
            try ImportTypeProgress.fetchOne(db, key: hkTypeId)
        }
    }

    func allTypeProgress() throws -> [ImportTypeProgress] {
        try database.dbWriter.read { db in try ImportTypeProgress.fetchAll(db) }
    }

    /// Persist a type's paging cursor + running staged total, and roll the run's
    /// aggregate counters forward, in ONE transaction — so a force-quit can never
    /// leave a cursor that claims more progress than was actually staged.
    ///
    /// - Parameters:
    ///   - cursor: the resume point (samples with `endDate <= cursor` are unread).
    ///     Passed through verbatim, including `nil` for "not started".
    ///   - stagedCount: this type's running staged total for the run.
    ///   - status: the type's state after this checkpoint.
    func checkpoint(
        hkTypeId: String,
        runId: String,
        cursor: Date?,
        stagedCount: Int,
        status: ImportRunStatus,
        failureReason: String? = nil,
        now: Date = Date()
    ) throws {
        try database.dbWriter.write { db in
            try ImportTypeProgress(
                hkTypeId: hkTypeId,
                runId: runId,
                cursor: cursor,
                stagedCount: stagedCount,
                status: status,
                failureReason: failureReason,
                updatedAt: now
            ).save(db)

            guard var run = try ImportRunState.fetchOne(db, key: ImportProgressDAO.singletonID) else { return }
            let rows = try ImportTypeProgress.filter(Column("run_id") == runId).fetchAll(db)
            run.stagedCount = rows.reduce(0) { $0 + $1.stagedCount }
            run.typesCompleted = rows.filter { $0.status == .completed }.count
            run.oldestReachedAt = ImportProgressDAO.floorReached(rows: rows, run: run)
            run.updatedAt = now
            try run.update(db)
        }
    }

    /// The **conservative** floor the run has reached: the date every enabled type
    /// is imported back to at least.
    ///
    /// Deliberately NOT the oldest cursor any single type walked to — one type
    /// that raced back to 2019 while the others are still in the current month
    /// would make the whole run read as "reached 2019", which overstates progress
    /// in exactly the way this durable-status work exists to prevent.
    /// Understating is the safe direction, so:
    ///
    /// - a type that hasn't started (no row, or a `nil` cursor) means nothing is
    ///   guaranteed yet ⇒ `nil`;
    /// - a `completed` type has read its whole range and must not drag the floor,
    ///   so it is excluded (its cursor may be `nil` or arbitrarily deep);
    /// - otherwise the floor is the **least-old** cursor among the types still
    ///   working, and once every type is complete the floor is the run's range
    ///   start (the whole window really was covered).
    static func floorReached(rows: [ImportTypeProgress], run: ImportRunState) -> Date? {
        let unfinished = rows.filter { $0.status != .completed }
        guard rows.count >= run.typesTotal else { return nil }
        guard !unfinished.isEmpty else { return run.rangeStart }
        guard !unfinished.contains(where: { $0.cursor == nil }) else { return nil }
        return unfinished.compactMap(\.cursor).max()
    }
}
