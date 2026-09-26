import Foundation

/// Product defaults, not StoreKit guarantees or measured optima. No rating outcome is stored.
struct ReviewPreferences: Codable, Equatable {
    var schema = 1
    var firstQualifiedAt: Date?
    var days: [String] = []
    var lastQualifiedAt: Date?
    var lastQualifiedDay: String?
    var lastDeliveryAt: Date?
    var lastAttemptAt: Date?
    var requestedVersions: [String] = []
    var lastRecordedAt: Date?
}

enum ReviewEligibility {
    static let day: TimeInterval = 86_400

    static func dayKey(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func valid(_ state: ReviewPreferences, now: Date) -> Bool {
        let dates = [state.firstQualifiedAt, state.lastQualifiedAt, state.lastDeliveryAt,
                     state.lastAttemptAt, state.lastRecordedAt].compactMap { $0 }
        guard now.timeIntervalSince1970.isFinite, state.schema == 1,
              dates.allSatisfy({ $0.timeIntervalSince1970.isFinite && $0 <= now }),
              state.days.count <= 3, Set(state.days).count == state.days.count,
              state.days.allSatisfy(validDayKey),
              Set(state.requestedVersions).count == state.requestedVersions.count,
              state.requestedVersions.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return false }
        if state.firstQualifiedAt == nil {
            return dates.isEmpty && state.days.isEmpty && state.requestedVersions.isEmpty
                && state.lastQualifiedDay == nil
        }
        guard let first = state.firstQualifiedAt, let qualified = state.lastQualifiedAt,
              let delivery = state.lastDeliveryAt, let recorded = state.lastRecordedAt,
              let key = state.lastQualifiedDay, validDayKey(key),
              first <= qualified, delivery <= qualified, qualified <= recorded,
              state.lastAttemptAt.map({ first <= $0 && $0 <= recorded }) ?? true,
              (state.lastAttemptAt == nil) == state.requestedVersions.isEmpty
        else { return false }
        return true
    }

    private static func validDayKey(_ key: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: key).map { formatter.string(from: $0) == key } ?? false
    }

    static func qualifying(_ state: ReviewPreferences, deliveryAt: Date, now: Date,
                           timeZone: TimeZone) -> ReviewPreferences? {
        guard valid(state, now: now), deliveryAt <= now,
              now.timeIntervalSince(deliveryAt) <= day,
              state.lastDeliveryAt.map({ deliveryAt > $0 }) ?? true,
              state.lastQualifiedAt.map({ now.timeIntervalSince($0) >= 20 * 3600 }) ?? true,
              state.days.count < 3 else { return nil }
        let key = dayKey(now, timeZone: timeZone)
        guard !state.days.contains(key), state.lastQualifiedDay != key else { return nil }
        var next = state
        next.firstQualifiedAt = state.firstQualifiedAt ?? now
        next.days.append(key)
        next.lastQualifiedAt = now
        next.lastQualifiedDay = key
        next.lastDeliveryAt = deliveryAt
        next.lastRecordedAt = now
        return next
    }

    static func canRequest(_ state: ReviewPreferences, now: Date, version: String?) -> Bool {
        guard valid(state, now: now), let first = state.firstQualifiedAt,
              now.timeIntervalSince(first) >= 14 * day, state.days.count == 3,
              let version, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !state.requestedVersions.contains(version) else { return false }
        return state.lastAttemptAt.map { now.timeIntervalSince($0) >= 180 * day } ?? true
    }

    static func reserving(_ state: ReviewPreferences, now: Date, version: String?) -> ReviewPreferences? {
        guard canRequest(state, now: now, version: version), let version else { return nil }
        var next = state
        next.lastAttemptAt = now
        next.lastRecordedAt = now
        next.requestedVersions.append(version)
        next.days = []
        return next
    }
}

/// One local record, intentionally separate from onboarding/config/queue reset storage.
struct ReviewPreferencesStore {
    static let key = "conduit.reviewPreferences.v1"
    let defaults: UserDefaults

    func load() throws -> ReviewPreferences {
        guard let object = defaults.object(forKey: Self.key) else { return ReviewPreferences() }
        guard let data = object as? Data else { throw CocoaError(.coderReadCorrupt) }
        return try JSONDecoder().decode(ReviewPreferences.self, from: data)
    }

    func save(_ preferences: ReviewPreferences) throws {
        defaults.set(try JSONEncoder().encode(preferences), forKey: Self.key)
    }
}
