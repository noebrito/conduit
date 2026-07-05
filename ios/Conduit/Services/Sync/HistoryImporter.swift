import Foundation
import HealthKit

/// Drives a **bounded, paged, NEWEST-FIRST, auto-resuming** historical import
/// for a single data type (ARCHITECTURE.md §4.4, "Import history" opt-in).
///
/// The whole point of this path is that it CANNOT flood the outbox the way the
/// old unbounded all-history backfill did, while still surfacing the user's most
/// recent data first. It does that with these bounds, all expressed here:
///
/// 1. **Newest-first paging** — it reads one page of at most `pageSize` samples
///    sorted `endDate` DESCENDING (via `AnchoredReader.readImportPage`), then
///    walks the upper-bound cursor (`before`) backward using the previous page's
///    oldest `endDate`. Recent days therefore stage and upload first instead of
///    grinding forward from years ago. Memory never holds more than a page.
/// 2. **Outbox cap** — staging reports `hitCap` when the outbox back-pressure
///    limit is reached.
/// 3. **Auto-resume across the cap** — instead of stopping one-shot on `hitCap`,
///    the loop asks `waitForCapacity()` to drain the queue below the cap, then
///    re-reads the SAME window (UUID dedupe skips what was already staged) and
///    continues — so a range larger than the cap completes on its own with no
///    manual re-tap. It stays cooperative with the cap (never stages past it)
///    and honours `isCancelled()`.
///
/// The paging loop is factored out of `SyncEngine` (which wires it to the real
/// `AnchoredReader` + `OutboxDAO` + drain loop) purely so it is unit-testable
/// without a live `HKHealthStore` or background `URLSession`: the tests pass
/// fake `readPage`/`stagePage`/`waitForCapacity` closures.
enum HistoryImporter {
    struct Summary {
        /// Total newly staged (non-duplicate) rows across all pages.
        let staged: Int
        /// `true` if the import stopped WITHOUT draining the whole range because
        /// the outbox stayed at capacity (drain timed out) — the caller should
        /// surface this so the user can retry later.
        let hitCap: Bool
        /// `true` if the import was cancelled before finishing the range.
        let cancelled: Bool
    }

    /// Page through a newest-first historical read until the range is exhausted,
    /// the import is cancelled, or the outbox cap can no longer be freed.
    ///
    /// - Parameters:
    ///   - pageSize: the `limit:` passed to each read; also the signal for the
    ///     last page (a short page ends the loop).
    ///   - maxPages: a hard safety ceiling so a misbehaving reader that never
    ///     advances its cursor cannot loop forever. Under normal operation the
    ///     short-page / exhausted-range conditions end the loop long before this.
    ///   - isCancelled: polled before each page so a user cancel stops promptly.
    ///   - readPage: reads one page whose samples all have `endDate <= before`
    ///     (or up to now when `before == nil`), newest-first.
    ///   - stagePage: enqueues a page WITHOUT advancing the forward anchor,
    ///     returning how many were newly staged and whether the cap was hit.
    ///   - onProgress: called with the running staged total after each page.
    ///   - waitForCapacity: invoked when a page hits the cap; should drain the
    ///     outbox below the cap and return `true` to resume, or `false` to stop
    ///     (drain timed out or the user cancelled).
    static func run(
        pageSize: Int,
        maxPages: Int = 100_000,
        isCancelled: () -> Bool = { false },
        readPage: (_ before: Date?) async throws -> AnchoredReader.Result,
        stagePage: (_ samples: [Conduit_V1_Sample]) throws -> (inserted: Int, hitCap: Bool),
        onProgress: (_ stagedTotal: Int) -> Void = { _ in },
        waitForCapacity: () async -> Bool = { false }
    ) async throws -> Summary {
        var cursor: Date?
        var total = 0

        for _ in 0..<maxPages {
            if isCancelled() {
                return Summary(staged: total, hitCap: false, cancelled: true)
            }

            let page = try await readPage(cursor)
            // No samples older than the cursor → the range is exhausted.
            if page.samples.isEmpty {
                return Summary(staged: total, hitCap: false, cancelled: false)
            }

            let staged = try stagePage(page.samples)
            total += staged.inserted
            onProgress(total)

            if staged.hitCap {
                // Outbox full mid-page. Do NOT advance the cursor: wait for the
                // queue to drain below the cap, then re-read the SAME window
                // (dedupe skips the rows we already staged) and continue.
                if isCancelled() {
                    return Summary(staged: total, hitCap: true, cancelled: true)
                }
                let resumed = await waitForCapacity()
                if !resumed {
                    return Summary(staged: total, hitCap: true, cancelled: isCancelled())
                }
                continue
            }

            // A short page means we've reached the tail of the range.
            if page.samples.count < pageSize {
                return Summary(staged: total, hitCap: false, cancelled: false)
            }

            // Advance the cursor to the oldest sample's endDate. If it can't move
            // (an entire full page shares the boundary timestamp), stop rather
            // than spin re-reading the same window forever.
            guard let next = page.oldestEndDate, next != cursor else {
                return Summary(staged: total, hitCap: false, cancelled: false)
            }
            cursor = next
        }

        return Summary(staged: total, hitCap: false, cancelled: false)
    }
}
