import Foundation

private enum ReviewClock {
    static let origin = ContinuousClock.now
    static func seconds() -> TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}

/// Sole owner of eligibility and reservations. Only a visible SwiftUI Home supplies the
/// StoreKit action; uploader/background callbacks can invalidate readiness, never present.
@MainActor
final class ReviewPromptCoordinator {
    enum Phase { case active, inactive, background }

    private(set) var preferences: ReviewPreferences?
    private(set) var sessionSuppressed = false
    private var phase: Phase = .inactive
    private var homeVisible = false
    private var hasBackgrounded = false
    private var foregroundAt: TimeInterval?
    private var settledAt: TimeInterval?
    private var quietAt: TimeInterval?
    private var qualifiedThisPause = false
    private var evidence: ReviewReadiness?
    private var generation = 0
    private var reading = false
    private var waitingForChange = false
    private var sensitiveActivities = 0
    private var manualSyncActive = false
    private var timer: Task<Void, Never>?
    private var lastClock: (date: Date, uptime: TimeInterval)?
    private var importRevision: UInt64
    private var request: (() -> Void)?
    private var canPresent: () -> Bool = { false }
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let timeZone: () -> TimeZone
    private let version: () -> String?
    private let save: (ReviewPreferences) throws -> Void
    private let read: () async throws -> ReviewReadiness
    private let importActivity: () -> (running: Bool, revision: UInt64)
    private let automaticallySchedule: Bool

    init(load: () throws -> ReviewPreferences,
         save: @escaping (ReviewPreferences) throws -> Void,
         now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { ReviewClock.seconds() },
         timeZone: @escaping () -> TimeZone = { .current },
         version: @escaping () -> String? = { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String },
         importActivity: @escaping () -> (running: Bool, revision: UInt64),
         read: @escaping () async throws -> ReviewReadiness,
         automaticallySchedule: Bool = true) {
        self.now = now
        self.uptime = uptime
        self.timeZone = timeZone
        self.version = version
        self.save = save
        self.read = read
        self.importActivity = importActivity
        self.automaticallySchedule = automaticallySchedule
        self.importRevision = importActivity().revision
        // Corrupt/unknown records defer; never erase cooldown history to recover.
        self.preferences = try? load()
    }

    func setPresentation(request: @escaping () -> Void, canPresent: @escaping () -> Bool) {
        self.request = request
        self.canPresent = canPresent
    }

    func sceneChanged(_ next: Phase) {
        guard next != phase else { return }
        phase = next
        invalidate()
        foregroundAt = nil
        if next == .background { hasBackgrounded = true }
        if next == .active {
            if hasBackgrounded {
                sessionSuppressed = false
                hasBackgrounded = false
                importRevision = importActivity().revision
            }
            foregroundAt = uptime()
        }
        schedule()
    }

    func setHomeVisible(_ visible: Bool) {
        guard homeVisible != visible else { return }
        homeVisible = visible
        invalidate()
        schedule()
    }

    func beginSensitiveActivity() {
        sensitiveActivities += 1
        suppressSession()
    }

    func endSensitiveActivity() {
        sensitiveActivities = max(0, sensitiveActivities - 1)
        suppressSession()
    }

    func setManualSyncActive(_ active: Bool) {
        manualSyncActive = active
        invalidate()
    }

    func suppressSession() {
        sessionSuppressed = true
        invalidate()
        schedule()
    }

    /// Every status commit (including work beginning), tab change, gesture, or
    /// stale observation cancels both uninterrupted dwell and the quiet pause.
    func invalidate() {
        generation &+= 1
        waitingForChange = false
        evidence = nil
        settledAt = nil
        quietAt = nil
        qualifiedThisPause = false
    }

    private var visible: Bool { phase == .active && homeVisible && !sessionSuppressed }

    private func schedule() {
        timer?.cancel()
        timer = nil
        guard automaticallySchedule, visible else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.visible else { return }
                await self.tick()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func safe() -> Bool {
        let activity = importActivity()
        if sensitiveActivities > 0 || activity.running || activity.revision != importRevision {
            suppressSession()
            return false
        }
        guard visible, !manualSyncActive, canPresent(), request != nil else { return false }
        return true
    }

    private func checkClock() -> Bool {
        let date = now(), monotonic = uptime()
        defer { lastClock = (date, monotonic) }
        if let lastClock {
            let elapsed = monotonic - lastClock.uptime
            // Wall-clock changes during the process cannot age a visit/cooldown.
            guard elapsed >= 0, abs(date.timeIntervalSince(lastClock.date) - elapsed) < 5 else {
                suppressSession()
                return false
            }
        }
        guard let preferences, ReviewEligibility.valid(preferences, now: date) else { return false }
        return true
    }

    private func refresh() async -> Bool {
        let token = generation
        do {
            let result = try await read()
            guard token == generation, !Task.isCancelled, safe(), checkClock() else { return false }
            if result.importIsActive { suppressSession(); return false }
            guard result.isReady, let delivery = result.deliveryAt,
                  delivery <= now(), now().timeIntervalSince(delivery) <= ReviewEligibility.day else {
                invalidate()
                waitingForChange = true
                return false
            }
            evidence = result
            return true
        } catch {
            invalidate()
            waitingForChange = true
            return false
        }
    }

    /// Also the deterministic test driver. No sleeps, HealthKit or StoreKit needed in tests.
    func tick() async {
        guard !reading else { return }
        guard safe(), checkClock() else { invalidate(); return }
        // An unsafe DB result waits for the existing status observation or a
        // new visible visit; the timer never polls delivery/outbox tables.
        guard !waitingForChange else { return }
        reading = true
        defer { reading = false }
        if evidence == nil {
            guard await refresh() else { return }
            settledAt = uptime()
        }
        guard let settledAt, let foregroundAt else { return }
        if !qualifiedThisPause, uptime() - settledAt >= 10 {
            guard await refresh() else { return }
            qualifiedThisPause = true
            if let preferences, let delivery = evidence?.deliveryAt,
               let next = ReviewEligibility.qualifying(preferences, deliveryAt: delivery,
                                                       now: now(), timeZone: timeZone()) {
                guard persist(next) else { return }
            }
        }
        guard qualifiedThisPause, uptime() - foregroundAt >= 30,
              let preferences, ReviewEligibility.canRequest(preferences, now: now(), version: version()) else { return }
        guard let quietAt else { self.quietAt = uptime(); return }
        guard uptime() - quietAt >= 2 else { return }
        guard await refresh(), safe(), checkClock(), let current = self.preferences,
              let reserved = ReviewEligibility.reserving(current, now: now(), version: version()) else { return }
        // Deliberately synchronous on MainActor: reservation must persist BEFORE the
        // action, with no suspension/reentrancy window. A silent StoreKit call counts.
        guard persist(reserved) else { return }
        request?()
        invalidate()
    }

    private func persist(_ next: ReviewPreferences) -> Bool {
        do {
            try save(next)
            preferences = next
            return true
        } catch {
            preferences = nil
            invalidate()
            return false
        }
    }
}
