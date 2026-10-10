import Foundation
import HealthKit

/// One bounded pass; never waits for a background upload's receiver response.
enum ShortcutSync {
    static let pageSize = 200
    static let workoutLimit = 10
    static let timeBudget: TimeInterval = 20

    struct Capture {
        var captured = 0
        var queued = 0
        var deletions = 0
        var limited = false
        var notice: String?
    }

    struct Summary {
        var capture = Capture()
        var submitted = 0
        var notices: [String] = []

        var message: String {
            "Captured \(capture.captured) samples; queued \(capture.queued) new samples; processed \(capture.deletions) deletions. Submitted \(submitted) queued items for background upload (may include earlier data or deletions). Sent/receiver acceptance: not awaited or confirmed by this action. Check Activity Log for delivery results."
                + (capture.limited ? " Capture was bounded; more data may remain for a later sync." : "")
                + (notices.isEmpty ? "" : " " + notices.joined(separator: " "))
                + (capture.captured == 0 ? " HealthKit can return no readable samples when access is denied; an empty read does not prove Health is empty." : "")
        }
    }

    static func failureMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == HKErrorDomain && nsError.code == HKError.Code.errorDatabaseInaccessible.rawValue {
            return "Health data is unavailable while the device is locked. Unlock your iPhone and run again."
        }
        return "Capture or queueing failed for an enabled type. Open Conduit to check Health access and storage, then retry."
    }

    /// The injectable boundary tests partial progress, cancellation and upload
    /// submission independently of HealthKit and a user's real endpoint.
    static func run(
        identifiers: [String],
        shouldStop: () -> Bool,
        capture: (String) async throws -> Capture,
        flush: () async throws -> Int
    ) async -> Summary {
        var summary = Summary()
        for identifier in identifiers {
            guard !shouldStop() else {
                summary.capture.limited = true
                summary.notices.append("Stopped before completing capture (cancelled or time budget reached). Already queued data is retained.")
                break
            }
            do {
                let result = try await capture(identifier)
                summary.capture.captured += result.captured
                summary.capture.queued += result.queued
                summary.capture.deletions += result.deletions
                summary.capture.limited = summary.capture.limited || result.limited
                if let notice = result.notice { summary.notices.append(notice); break }
            } catch {
                summary.notices.append(failureMessage(error))
                // A locked database or staging failure should not trigger more reads.
                break
            }
        }
        if !Task.isCancelled {
            do { summary.submitted = try await flush() }
            catch { summary.notices.append("Could not start upload. Queued data is retained for retry.") }
        }
        return summary
    }
}
