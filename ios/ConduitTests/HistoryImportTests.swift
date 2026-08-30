import XCTest
import HealthKit
@testable import Conduit

/// Tests for the explicit "Import history" opt-in: the range → predicate
/// mapping, and the paged, outbox-cap-bounded importer that keeps a large
/// import from flooding the outbox the way the old unbounded backfill did.
final class HistoryImportTests: XCTestCase {

    /// A sample carrying an explicit `endUnixMs` so tests can assert newest-first
    /// ordering and exercise the date-cursor paging.
    private func makeSample(uuid: String, endMs: Int64) -> Conduit_V1_Sample {
        var sample = Conduit_V1_Sample()
        sample.uuid = uuid
        sample.endUnixMs = endMs
        return sample
    }

    /// Model a synthetic history as newest-first `endDate` timestamps and serve
    /// it through the newest-first date-cursor reader `HistoryImporter` expects:
    /// each call returns up to `pageSize` samples strictly older than `before`.
    private func newestFirstReader(
        endMsNewestFirst: [Int64],
        pageSize: Int
    ) -> (Date?) async throws -> AnchoredReader.Result {
        return { before in
            let upper = before.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? Int64.max
            let page = endMsNewestFirst.filter { $0 < upper }.prefix(pageSize)
            let samples = page.map { self.makeSample(uuid: "e\($0)", endMs: $0) }
            return AnchoredReader.Result(samples: Array(samples), deletedUuids: [], newAnchor: nil)
        }
    }

    // MARK: - Range → predicate

    func testAllTimeRangeHasNoDateFloor() {
        XCTAssertNil(ImportRange.allTime.startDate(now: Date(), customStart: Date()),
                     "All time must map to a nil start (no predicate floor)")
        XCTAssertNil(AnchoredReader.importPredicate(since: nil),
                     "A nil start must produce a nil predicate (reads all history)")
    }

    func testPresetRangesResolveToExpectedStart() {
        let now = Date()
        let thirty = try! XCTUnwrap(ImportRange.last30Days.startDate(now: now, customStart: now))
        let ninety = try! XCTUnwrap(ImportRange.last90Days.startDate(now: now, customStart: now))
        let year = try! XCTUnwrap(ImportRange.lastYear.startDate(now: now, customStart: now))

        // Approximate spans (seconds); tolerate DST/calendar drift.
        XCTAssertEqual(now.timeIntervalSince(thirty), 30 * 86_400, accuracy: 2 * 86_400)
        XCTAssertEqual(now.timeIntervalSince(ninety), 90 * 86_400, accuracy: 3 * 86_400)
        XCTAssertEqual(now.timeIntervalSince(year), 365 * 86_400, accuracy: 3 * 86_400)
    }

    func testCustomRangeUsesUserStart() {
        let custom = Date(timeIntervalSince1970: 1_600_000_000)
        XCTAssertEqual(ImportRange.custom.startDate(now: Date(), customStart: custom), custom)
    }

    func testChosenStartIsHonoredInPredicate() {
        // The chosen start date must actually flow into the read predicate.
        let earlier = Date(timeIntervalSince1970: 1_500_000_000)
        let later = Date(timeIntervalSince1970: 1_700_000_000)

        let pEarlier = AnchoredReader.importPredicate(since: earlier)
        let pLater = AnchoredReader.importPredicate(since: later)

        XCTAssertNotNil(pEarlier)
        XCTAssertNotNil(pLater)
        // Different chosen starts must yield different predicates (proving the
        // chosen date actually flows into the read floor), and both must be a
        // date-CAST bound.
        XCTAssertNotEqual(pEarlier?.predicateFormat, pLater?.predicateFormat)
        XCTAssertTrue(pEarlier?.predicateFormat.contains("CAST") ?? false,
                      "Predicate must be a date bound derived from the chosen start")
        // The CAST value is the chosen start expressed as seconds since the
        // reference date (2001) — assert the earlier start's exact value appears.
        let referenceSeconds = Int(earlier.timeIntervalSinceReferenceDate)
        XCTAssertTrue(pEarlier?.predicateFormat.contains("\(referenceSeconds)") ?? false,
                      "The chosen start date must be the value in the predicate")
    }

    // MARK: - Window predicate (newest-first import)

    func testImportWindowPredicateBounds() {
        // Both nil → no predicate (all history, up to now).
        XCTAssertNil(AnchoredReader.importWindowPredicate(since: nil, before: nil))
        // Any bound present → a non-nil date predicate.
        XCTAssertNotNil(AnchoredReader.importWindowPredicate(since: Date(), before: nil))
        XCTAssertNotNil(AnchoredReader.importWindowPredicate(since: nil, before: Date()))
        // A moving `before` cursor must change the predicate (proves the paging
        // upper bound actually flows into the read).
        let a = AnchoredReader.importWindowPredicate(since: nil, before: Date(timeIntervalSince1970: 1_500_000_000))
        let b = AnchoredReader.importWindowPredicate(since: nil, before: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNotEqual(a?.predicateFormat, b?.predicateFormat)
    }

    // MARK: - Paged importer — newest-first

    func testImporterStagesNewestFirst() async throws {
        // Synthetic history: endDates 1000 (newest) down to 1 (oldest).
        let pageSize = 5
        let allEnd: [Int64] = Array(stride(from: 1000, through: 1, by: -1))
        var stagedOrder: [Int64] = []

        let summary = try await HistoryImporter.run(
            pageSize: pageSize,
            readPage: newestFirstReader(endMsNewestFirst: allEnd, pageSize: pageSize),
            stagePage: { samples in
                stagedOrder.append(contentsOf: samples.map(\.endUnixMs))
                return (inserted: samples.count, hitCap: false)
            }
        )

        XCTAssertEqual(summary.staged, allEnd.count)
        XCTAssertFalse(summary.hitCap)
        XCTAssertFalse(summary.cancelled)
        // The FIRST staged samples must be the most recent, not the oldest —
        // the whole point of newest-first import.
        XCTAssertEqual(Array(stagedOrder.prefix(5)), [1000, 999, 998, 997, 996])
        // And the full staged stream is strictly newest → oldest.
        XCTAssertEqual(stagedOrder, allEnd)
    }

    func testImporterPagesUntilShortPageThenStops() async throws {
        // 12 samples, pageSize 5 → pages of 5, 5, 2 (short → stop).
        let pageSize = 5
        let allEnd: [Int64] = Array(stride(from: 12, through: 1, by: -1))
        var readCalls = 0
        var stagedTotal = 0
        let reader = newestFirstReader(endMsNewestFirst: allEnd, pageSize: pageSize)

        let summary = try await HistoryImporter.run(
            pageSize: pageSize,
            readPage: { before in readCalls += 1; return try await reader(before) },
            stagePage: { samples in
                stagedTotal += samples.count
                return (inserted: samples.count, hitCap: false)
            }
        )

        XCTAssertEqual(readCalls, 3, "Should stop after the short final page")
        XCTAssertEqual(summary.staged, 12)
        XCTAssertEqual(stagedTotal, 12)
        XCTAssertFalse(summary.hitCap)
    }

    // MARK: - Auto-resume across the outbox cap

    func testImporterAutoResumesAcrossCapBoundaryWithoutManualRetap() async throws {
        // 20 samples, pageSize 10. The outbox has room for 10 at a time; when it
        // fills, `waitForCapacity` "drains" it and the import continues on its
        // own until the whole range is done — no re-tap, and never over the cap.
        let pageSize = 10
        let allEnd: [Int64] = Array(stride(from: 20, through: 1, by: -1))
        var capacity = 10
        var maxConcurrent = 0
        var live = 0
        var stagedUUIDs = Set<String>()
        var waitCalls = 0

        let summary = try await HistoryImporter.run(
            pageSize: pageSize,
            readPage: newestFirstReader(endMsNewestFirst: allEnd, pageSize: pageSize),
            stagePage: { samples in
                var inserted = 0
                for s in samples {
                    // UUID dedupe, exactly like OutboxDAO.stageImport.
                    if stagedUUIDs.contains(s.uuid) { continue }
                    if capacity <= 0 { return (inserted: inserted, hitCap: true) }
                    capacity -= 1
                    live += 1
                    maxConcurrent = max(maxConcurrent, live)
                    stagedUUIDs.insert(s.uuid)
                    inserted += 1
                }
                return (inserted: inserted, hitCap: false)
            },
            waitForCapacity: {
                waitCalls += 1
                // The queue drained (delivered rows removed) — room again.
                live = 0
                capacity = 10
                return true
            }
        )

        XCTAssertGreaterThanOrEqual(waitCalls, 1, "The cap must have been hit and drained at least once")
        XCTAssertEqual(summary.staged, 20, "Auto-resume must finish the whole range past the cap")
        XCTAssertFalse(summary.hitCap, "Finishing the range is not a cap stall")
        XCTAssertFalse(summary.cancelled)
        XCTAssertLessThanOrEqual(maxConcurrent, 10, "Must never stage past the cap at once")
    }

    func testImporterReportsHitCapWhenDrainNeverSucceeds() async throws {
        // If the queue can't be drained (waitForCapacity returns false), the
        // import stops and reports hitCap so the caller can tell the user.
        let pageSize = 5
        let allEnd: [Int64] = Array(stride(from: 20, through: 1, by: -1))

        let summary = try await HistoryImporter.run(
            pageSize: pageSize,
            readPage: newestFirstReader(endMsNewestFirst: allEnd, pageSize: pageSize),
            stagePage: { _ in (inserted: 0, hitCap: true) },   // outbox is full, always
            waitForCapacity: { false }                          // and never drains
        )

        XCTAssertTrue(summary.hitCap)
        XCTAssertFalse(summary.cancelled)
    }

    // MARK: - Cancellation

    func testImporterStopsPromptlyWhenCancelled() async throws {
        let pageSize = 5
        let allEnd: [Int64] = Array(stride(from: 1000, through: 1, by: -1))
        var reads = 0
        let reader = newestFirstReader(endMsNewestFirst: allEnd, pageSize: pageSize)

        let summary = try await HistoryImporter.run(
            pageSize: pageSize,
            isCancelled: { reads >= 2 },   // cancel after two pages have been read
            readPage: { before in reads += 1; return try await reader(before) },
            stagePage: { samples in (inserted: samples.count, hitCap: false) }
        )

        XCTAssertTrue(summary.cancelled, "Cancellation must stop the loop")
        XCTAssertEqual(summary.staged, 10, "Only the pages read before cancel are staged")
    }

    // MARK: - Stall guard

    func testImporterStopsWhenAFullPageCannotAdvanceTheCursor() async throws {
        // Pathological: a full page whose samples ALL share one endDate. The
        // cursor can't move, so the loop must stop rather than spin forever.
        let pageSize = 5
        var stagedUUIDs = Set<String>()
        let summary = try await HistoryImporter.run(
            pageSize: pageSize,
            readPage: { _ in
                // The inclusive boundary keeps handing back the same same-endDate
                // page each time the cursor doesn't advance.
                AnchoredReader.Result(
                    samples: (0..<5).map { self.makeSample(uuid: "same\($0)", endMs: 500) },
                    deletedUuids: [],
                    newAnchor: nil
                )
            },
            stagePage: { samples in
                var inserted = 0
                for s in samples where stagedUUIDs.insert(s.uuid).inserted { inserted += 1 }
                return (inserted: inserted, hitCap: false)
            }
        )

        XCTAssertEqual(summary.staged, 5, "Dedupe + stall guard means each sample stages once and the loop stops")
        XCTAssertFalse(summary.hitCap)
        XCTAssertFalse(summary.cancelled)
    }
}
