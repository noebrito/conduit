import WidgetKit
import SwiftUI

/// Lock Screen widget: a reliability surface, not a feature showcase. It shows
/// only sync status — last-synced time, pending/failed counts, import status
/// headline — and never a health value (steps, heart rate, etc.), a permanent
/// constraint per the captain's decision.
struct ConduitStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: ConduitStatusSnapshot?
}

struct ConduitStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> ConduitStatusEntry {
        ConduitStatusEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ConduitStatusEntry) -> Void) {
        completion(ConduitStatusEntry(date: Date(), snapshot: ConduitStatusSnapshot.readFromAppGroup()))
    }

    /// Hourly baseline refresh (`ConduitStatusSnapshot.timelineRefreshInterval`),
    /// deliberately well under the ~40-70/day the system budgets: at ~24/day it
    /// leaves the rest of the allowance for the urgent pushes
    /// `AppState.persistStatusSnapshot` makes when the status changes class.
    /// Neither piece of freshness this widget needs depends on this cadence —
    /// the relative-time first line ticks on its own at zero refresh cost (see
    /// `RectangularAccessoryView` / `CircularAccessoryView`), and a state-class
    /// change arrives as a push rather than waiting for it.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ConduitStatusEntry>) -> Void) {
        let now = Date()
        let snapshot = ConduitStatusSnapshot.readFromAppGroup()
        let entries = ConduitStatusSnapshot
            .timelineEntryDates(from: now)
            .map { ConduitStatusEntry(date: $0, snapshot: snapshot) }
        let next = now.addingTimeInterval(ConduitStatusSnapshot.timelineRefreshInterval)
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

struct ConduitStatusWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ConduitStatusEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularAccessoryView(snapshot: entry.snapshot, date: entry.date)
        case .accessoryInline:
            InlineAccessoryView(snapshot: entry.snapshot, date: entry.date)
        default:
            RectangularAccessoryView(snapshot: entry.snapshot, date: entry.date)
        }
    }
}

/// The "last synced" age, never finer than a minute — a ticking seconds
/// counter on the Lock Screen is distracting. iOS 18+ uses the system's live
/// reference-date format restricted to hour/minute fields, so it still updates
/// itself at zero refresh cost. iOS 17 has no such format, so it renders static
/// text from the timeline entry date, which is as fresh as the (hourly) timeline.
private struct LastSyncedAge: View {
    let lastSyncedAt: Date
    let now: Date
    var prefix = ""

    /// The system format already reads "5 minutes ago", so callers must not
    /// append their own "ago".
    var body: some View {
        if #available(iOS 18, *) {
            Text("\(prefix)\(Text(.currentDate, format: .reference(to: lastSyncedAt, allowedFields: [.hour, .minute])))")
        } else {
            Text("\(prefix)\(ConduitStatusSnapshot.coarseAge(from: lastSyncedAt, to: now)) ago")
        }
    }
}

/// Primary family: a relative-time line (system-ticked, zero refresh cost)
/// plus one conditional second line. See `ConduitStatusSnapshot.secondLine`.
/// A snapshot that has never synced still renders its state symbol and second
/// line — only the relative-time wording falls back to "No syncs yet" — since a
/// fresh install whose very first sync is failing is exactly what this surface
/// exists to make visible.
private struct RectangularAccessoryView: View {
    let snapshot: ConduitStatusSnapshot?
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let snapshot {
                Label {
                    if let lastSyncedAt = snapshot.lastSyncedAt {
                        LastSyncedAge(lastSyncedAt: lastSyncedAt, now: date, prefix: "Synced ")
                    } else {
                        Text("No syncs yet")
                    }
                } icon: {
                    Image(systemName: ConduitStatusSnapshot.symbolName(for: snapshot))
                }
                Text(ConduitStatusSnapshot.secondLine(for: snapshot, now: date))
                    .font(.caption2)
            } else {
                Label("No syncs yet", systemImage: "clock.badge.exclamationmark")
            }
        }
    }
}

/// One symbol plus a short age. The Lock Screen renders in vibrant
/// (desaturated) mode, so the symbol carries the state, never a tint color.
private struct CircularAccessoryView: View {
    let snapshot: ConduitStatusSnapshot?
    let date: Date

    var body: some View {
        VStack(spacing: 2) {
            if let snapshot {
                Image(systemName: ConduitStatusSnapshot.symbolName(for: snapshot))
                    .font(.title3)
                if let lastSyncedAt = snapshot.lastSyncedAt {
                    LastSyncedAge(lastSyncedAt: lastSyncedAt, now: date)
                        .font(.system(size: 11))
                        .minimumScaleFactor(0.6)
                }
            } else {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.title3)
            }
        }
        .widgetAccentable()
    }
}

/// One line above the clock.
private struct InlineAccessoryView: View {
    let snapshot: ConduitStatusSnapshot?
    let date: Date

    var body: some View {
        if let snapshot {
            Label {
                if snapshot.failedCount > 0 {
                    Text("Conduit · \(snapshot.failedCount) failed")
                } else if let lastSyncedAt = snapshot.lastSyncedAt {
                    LastSyncedAge(lastSyncedAt: lastSyncedAt, now: date, prefix: "Conduit · Synced ")
                } else {
                    Text("Conduit · No syncs yet")
                }
            } icon: {
                Image(systemName: ConduitStatusSnapshot.symbolName(for: snapshot))
            }
        } else {
            Label("Conduit · No syncs yet", systemImage: "clock.badge.exclamationmark")
        }
    }
}

struct ConduitStatusWidget: Widget {
    let kind: String = "ConduitStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ConduitStatusProvider()) { entry in
            ConduitStatusWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Sync Status")
        .description("Shows when Conduit last synced and whether anything needs attention.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}
