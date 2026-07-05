import Foundation
import GRDB
import os
import UIKit

/// Background `URLSession` upload pipeline (ARCHITECTURE.md §4.4 — Upload step).
///
/// ## Background session
/// The session identifier `dev.noebrito.Conduit.upload` is registered once via
/// `URLSessionConfiguration.background`. iOS resumes uploads even after the app
/// is killed; `AppDelegate` forwards the background completion handler here via
/// `backgroundCompletionHandler`.
///
/// ## Response → outbox state transitions (ARCHITECTURE.md §3.3)
/// | HTTP status      | Action                                          |
/// |------------------|-------------------------------------------------|
/// | 2xx              | Mark rows `sent`. Write `delivery_log` entry.   |
/// | 408/429/5xx/err  | Mark rows `pending`. Apply exponential backoff. |
/// | 4xx (other)      | Mark rows `failed`.                             |
///
/// ## Crash recovery
/// Call `reconcileInflight()` on launch. It fetches active task descriptions,
/// extracts batch IDs, and resets any `inflight` rows whose batch is no longer
/// in-flight back to `pending`.
final class Uploader: NSObject {
    static let shared = Uploader()

    private let sessionIdentifier = BackgroundSession.identifier
    private let logger = Logger(subsystem: "dev.noebrito.Conduit", category: "Uploader")

    /// Injected at wire-up time (see `SyncEngine`).
    var database: AppDatabase?
    var keychainStore: KeychainStore = .shared

    /// Forwarded by `AppDelegate` after iOS relaunches us for background session events.
    var backgroundCompletionHandler: (() -> Void)?

    /// Accumulates each task's response body (the ingester's `{accepted, deduped}`
    /// JSON) keyed by `URLSessionTask.taskIdentifier`, so `didCompleteWithError`
    /// can parse the write outcome. Only touched from the session's serial
    /// delegate queue (`delegateQueue: nil` → a private serial queue), so no
    /// extra locking is required.
    private var responseBodies: [Int: Data] = [:]

    /// The ingester's success body: how many docs were newly written vs deduped.
    private struct IngestResponse: Decodable {
        let accepted: Int?
        let deduped: Int?
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() { super.init() }

    // MARK: - Upload

    /// Enqueue a batch for background upload. The task's `taskDescription` carries
    /// the `batchID` so the delegate can look up the affected rows on completion.
    func upload(batch: Batcher.BatchResult, webhookURL: String, bearerToken: String) {
        guard let url = URL(string: webhookURL) else {
            logger.error("Invalid webhook URL: \(webhookURL, privacy: .public)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let iosVersion = UIDevice.current.systemVersion
        request.setValue("Conduit/\(version) (iOS \(iosVersion))", forHTTPHeaderField: "User-Agent")

        // Write JSON body to a temp file; background URLSession requires file-based uploads.
        let tmpURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("conduit-batch-\(batch.batchID).json")
        do {
            try batch.encodedJSON.write(to: tmpURL)
        } catch {
            logger.error("Failed to write batch file: \(error.localizedDescription, privacy: .public)")
            resetToRetry(batchID: batch.batchID, error: error.localizedDescription, retryAfter: nil, httpStatus: nil)
            return
        }

        let task = session.uploadTask(with: request, fromFile: tmpURL)
        task.taskDescription = batch.batchID
        task.resume()
        logger.info("Enqueued upload task for batch \(batch.batchID, privacy: .public) (\(batch.rowIDs.count) rows)")
    }

    // MARK: - Crash recovery

    /// Reset any `inflight` rows whose batch is not represented in the current
    /// background session's active tasks back to `pending` (ARCHITECTURE.md §4.6).
    ///
    /// Call on every app launch before the sync engine runs.
    func reconcileInflight() {
        session.getAllTasks { [weak self] tasks in
            guard let self, let db = self.database else { return }
            let activeBatchIDs = Set(tasks.compactMap(\.taskDescription))
            do {
                try db.dbWriter.write { grdb in
                    // Find inflight rows whose batch is no longer active.
                    let orphans = try OutboxRow
                        .filter(Column("state") == OutboxState.inflight.rawValue)
                        .fetchAll(grdb)
                        .filter { row in
                            guard let bid = row.batchId else { return true }
                            return !activeBatchIDs.contains(bid)
                        }
                    guard !orphans.isEmpty else { return }
                    let ids = orphans.compactMap(\.id)
                    try OutboxRow
                        .filter(ids.contains(Column("id")))
                        .updateAll(
                            grdb,
                            Column("state").set(to: OutboxState.pending.rawValue),
                            Column("batch_id").set(to: nil as String?)
                        )
                    self.logger.info("reconcileInflight: reset \(ids.count) orphaned inflight rows to pending")
                }
            } catch {
                self.logger.error("reconcileInflight error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - State transitions (internal)

    private func markSent(batchID: String, httpStatus: Int, accepted: Int?, deduped: Int?) {
        guard let db = database else { return }
        do {
            try db.dbWriter.write { grdb in
                try Uploader.commitSent(
                    grdb,
                    batchID: batchID,
                    httpStatus: httpStatus,
                    accepted: accepted,
                    deduped: deduped
                )
            }
            logger.info("Batch \(batchID, privacy: .public): delivered \(httpStatus), accepted=\(accepted ?? -1), deduped=\(deduped ?? -1), rows purged")
            if accepted == 0, (deduped ?? 0) > 0 {
                // Every sample was already indexed. A 200 that wrote nothing used
                // to be indistinguishable from a real write — surface it.
                logger.warning("Batch \(batchID, privacy: .public): 200 but wrote 0 new docs (all \(deduped ?? 0) deduped)")
            }
        } catch {
            logger.error("markSent error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Apply a successful (2xx) delivery inside an existing write transaction:
    /// **DELETE** the delivered outbox rows and record the audit entry in
    /// `delivery_log`.
    ///
    /// Delivered rows are deleted, not marked `sent` and kept, because the outbox
    /// is a backlog queue and `outboxCap` back-pressure counts total rows
    /// (`OutboxRow.fetchCount`, see `OutboxDAO.ingest`/`stageImport`). Keeping
    /// `sent` rows pegs that count at the cap forever after a large drain, which
    /// starves forward capture (`ingest` drops today's samples and won't advance
    /// the anchor) and blocks import resume (`stageImport` hits the cap
    /// immediately) — nothing new can stage once the table is full of
    /// already-delivered rows. Deleting them makes `fetchCount` reflect real
    /// undelivered work, so the cap frees up as uploads succeed. The audit trail
    /// lives in the separate `delivery_log` table (read by the Activity UI), so
    /// nothing that surfaces "sent" history is lost.
    ///
    /// `accepted`/`deduped` come from the ingester's 200 body
    /// (`{accepted, deduped}`) and are persisted so the Activity UI can show a
    /// batch that wrote 0 new docs (all duplicates) distinctly from one that
    /// wrote every sample. `nil` when the body was absent/unparseable.
    ///
    /// Factored out (and `internal`) so the real transition is unit-testable
    /// without a live background `URLSession` (see `UploaderResponseTests`).
    static func commitSent(
        _ grdb: Database,
        batchID: String,
        httpStatus: Int,
        accepted: Int? = nil,
        deduped: Int? = nil
    ) throws {
        let rows = try OutboxRow
            .filter(Column("batch_id") == batchID)
            .fetchAll(grdb)
        let ids = rows.compactMap(\.id)
        try OutboxRow
            .filter(ids.contains(Column("id")))
            .deleteAll(grdb)

        // Write delivery log entry (the durable "sent" audit record), carrying
        // the ingester's write outcome (accepted/deduped) when known.
        try grdb.execute(
            sql: """
                INSERT INTO delivery_log (batch_id, sent_at, http_status, sample_count, accepted, deduped)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [batchID, Date(), httpStatus, rows.count, accepted, deduped]
        )
        // Cap delivery_log at ~500 rows.
        try grdb.execute(
            sql: """
                DELETE FROM delivery_log WHERE id NOT IN (
                    SELECT id FROM delivery_log ORDER BY id DESC LIMIT 500
                )
                """
        )

        // Stamp the shared "last synced" timestamp: a 2xx delivery means the
        // queue actually drained, so this is a successful sync completion for
        // whichever trigger enqueued it (manual, observer, or background). Same
        // transaction as the delivery_log write so they can't diverge.
        try SyncStateDAO.setLastSyncedAt(grdb)
    }

    private func resetToRetry(batchID: String, error: String?, retryAfter: TimeInterval?, httpStatus: Int?) {
        guard let db = database else { return }
        do {
            try db.dbWriter.write { grdb in
                let rows = try OutboxRow
                    .filter(Column("batch_id") == batchID)
                    .fetchAll(grdb)
                for row in rows {
                    let attempt = row.attemptCount + 1
                    let nextAttempt = BackoffPolicy.nextAttemptDate(
                        attemptCount: attempt,
                        retryAfter: retryAfter
                    )
                    try grdb.execute(
                        sql: """
                            UPDATE outbox
                            SET state = 'pending',
                                batch_id = NULL,
                                attempt_count = ?,
                                next_attempt_at = ?,
                                last_error = ?
                            WHERE id = ?
                            """,
                        arguments: [attempt, nextAttempt, error, row.id]
                    )
                }
                if let status = httpStatus {
                    try grdb.execute(
                        sql: """
                            INSERT INTO delivery_log (batch_id, sent_at, http_status, sample_count, error_message)
                            VALUES (?, ?, ?, ?, ?)
                            """,
                        arguments: [batchID, Date(), status, rows.count, error]
                    )
                }
            }
            logger.info("Batch \(batchID, privacy: .public): scheduled retry (retryAfter=\(retryAfter.map { "\($0)" } ?? "nil", privacy: .public))")
        } catch {
            logger.error("resetToRetry error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func markFailed(batchID: String, httpStatus: Int, error: String?) {
        guard let db = database else { return }
        do {
            try db.dbWriter.write { grdb in
                let rows = try OutboxRow
                    .filter(Column("batch_id") == batchID)
                    .fetchAll(grdb)
                let ids = rows.compactMap(\.id)
                try OutboxRow
                    .filter(ids.contains(Column("id")))
                    .updateAll(
                        grdb,
                        Column("state").set(to: OutboxState.failed.rawValue),
                        Column("last_error").set(to: error)
                    )
                try grdb.execute(
                    sql: """
                        INSERT INTO delivery_log (batch_id, sent_at, http_status, sample_count, error_message)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [batchID, Date(), httpStatus, rows.count, error]
                )
            }
            logger.warning("Batch \(batchID, privacy: .public): permanently failed with \(httpStatus)")
        } catch {
            logger.error("markFailed error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - URLSessionDelegate

extension Uploader: URLSessionDelegate {
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}

// MARK: - URLSessionDataDelegate

extension Uploader: URLSessionDataDelegate {
    /// Accumulate the response body so `didCompleteWithError` can read the
    /// ingester's `{accepted, deduped}` outcome. Upload tasks deliver their
    /// response body through the data-task delegate.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
    }
}

// MARK: - URLSessionTaskDelegate

extension Uploader: URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Take (and clear) any accumulated response body for this task.
        let bodyData = responseBodies.removeValue(forKey: task.taskIdentifier)

        guard let batchID = task.taskDescription else { return }

        // Clean up the temp file.
        if task.originalRequest?.url != nil {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("conduit-batch-\(batchID).json")
            try? FileManager.default.removeItem(at: tmpURL)
        }

        if let error = error as NSError? {
            // Network-level error — retryable.
            logger.warning("Batch \(batchID, privacy: .public): network error \(error.localizedDescription, privacy: .public)")
            resetToRetry(batchID: batchID, error: error.localizedDescription, retryAfter: nil, httpStatus: nil)
            return
        }

        guard let httpResponse = task.response as? HTTPURLResponse else {
            resetToRetry(batchID: batchID, error: "No HTTP response", retryAfter: nil, httpStatus: nil)
            return
        }

        let status = httpResponse.statusCode
        logger.info("Batch \(batchID, privacy: .public): HTTP \(status)")

        switch status {
        case 200...299:
            // Parse the ingester's `{accepted, deduped}` body so a batch that
            // wrote 0 new docs (all duplicates) is recorded distinctly from one
            // that wrote every sample. A missing/unparseable body leaves them nil.
            var accepted: Int?
            var deduped: Int?
            if let bodyData, let parsed = try? JSONDecoder().decode(IngestResponse.self, from: bodyData) {
                accepted = parsed.accepted
                deduped = parsed.deduped
            }
            markSent(batchID: batchID, httpStatus: status, accepted: accepted, deduped: deduped)

        case 408, 429, 500...599:
            // Retryable. Parse Retry-After header on 429.
            var retryAfter: TimeInterval? = nil
            if status == 429, let raw = httpResponse.value(forHTTPHeaderField: "Retry-After") {
                retryAfter = TimeInterval(raw)
            }
            let msg = HTTPURLResponse.localizedString(forStatusCode: status)
            resetToRetry(batchID: batchID, error: "HTTP \(status): \(msg)", retryAfter: retryAfter, httpStatus: status)

        default:
            // Permanent 4xx failure.
            let msg = HTTPURLResponse.localizedString(forStatusCode: status)
            markFailed(batchID: batchID, httpStatus: status, error: "HTTP \(status): \(msg)")
        }
    }
}
