import Foundation
import GRDB

struct ReviewReadiness {
    var isReady: Bool
    var deliveryAt: Date?
    var importIsActive: Bool = false

    /// A fresh, transactional read on GRDB's queue. Delivery history is a bounded ring;
    /// it is evidence for this visit only, never reconstructed installation tenure.
    static func fetch(_ db: Database, now: Date, hasToken: Bool) throws -> Self {
        let run = try ImportRunState.fetchOne(db, key: ImportProgressDAO.singletonID)
        let importing = run?.status == .running || run?.autoResume == true
        guard !importing, hasToken,
              let config = try WebhookConfig.order(Column("created_at").desc).fetchOne(db),
              let url = URL(string: config.url), url.scheme == "https", url.host != nil,
              config.updatedAt <= now else {
            return Self(isReady: false, importIsActive: importing)
        }
        // EXISTS stops at the first indexed row; no sample payloads or widget counts.
        let hasWork = try OutboxRow.filter([OutboxState.pending.rawValue, OutboxState.inflight.rawValue,
                                           OutboxState.failed.rawValue].contains(Column("state"))).isEmpty(db) == false
        let latest = try DeliveryLogEntry.order(Column("sent_at").desc, Column("id").desc).fetchOne(db)
        let synced = try SyncStateDAO.lastSyncedAt(db)
        guard !hasWork,
              case .synced(let stamp) = HomeViewModel.deriveStatus(lastSynced: synced, latestDelivery: latest),
              stamp <= now, now.timeIntervalSince(stamp) <= ReviewEligibility.day else {
            return Self(isReady: false)
        }
        let delivery = try DeliveryLogEntry
            .filter(Column("http_status") >= 200 && Column("http_status") <= 299)
            .filter(Column("error_message") == nil && Column("sample_count") > 0)
            .filter(Column("sent_at") >= config.updatedAt && Column("sent_at") <= now)
            .filter(Column("sent_at") >= now.addingTimeInterval(-ReviewEligibility.day))
            .order(Column("sent_at").desc, Column("id").desc).fetchOne(db)
        // accepted == 0 (all deduped) and generic 2xx are both successful delivery.
        return Self(isReady: delivery != nil, deliveryAt: delivery?.sentAt)
    }
}
