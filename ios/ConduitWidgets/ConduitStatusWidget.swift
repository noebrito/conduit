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

    /// Timeline refresh policy on the order of 15 minutes. Relative-time text
    /// does the ticking between reloads at zero refresh cost — see
    /// `RectangularAccessoryView` / `CircularAccessoryView` below — so this
    /// cadence only needs to keep the second line and symbol current, not the
    /// "synced N ago" wording itself.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ConduitStatusEntry>) -> Void) {
        let entry = ConduitStatusEntry(date: Date(), snapshot: ConduitStatusSnapshot.readFromAppGroup())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct ConduitStatusWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ConduitStatusEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularAccessoryView(snapshot: entry.snapshot)
        case .accessoryInline:
            InlineAccessoryView(snapshot: entry.snapshot)
        default:
            RectangularAccessoryView(snapshot: entry.snapshot)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let snapshot {
                Label {
                    if let lastSyncedAt = snapshot.lastSyncedAt {
                        Text("Synced \(Text(lastSyncedAt, style: .relative)) ago")
                    } else {
                        Text("No syncs yet")
                    }
                } icon: {
                    Image(systemName: ConduitStatusSnapshot.symbolName(for: snapshot))
                }
                Text(ConduitStatusSnapshot.secondLine(for: snapshot))
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

    var body: some View {
        VStack(spacing: 2) {
            if let snapshot {
                Image(systemName: ConduitStatusSnapshot.symbolName(for: snapshot))
                    .font(.title3)
                if let lastSyncedAt = snapshot.lastSyncedAt {
                    Text(lastSyncedAt, style: .relative)
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

    var body: some View {
        if let snapshot {
            Label {
                if snapshot.failedCount > 0 {
                    Text("Conduit · \(snapshot.failedCount) failed")
                } else if let lastSyncedAt = snapshot.lastSyncedAt {
                    Text("Conduit · Synced \(Text(lastSyncedAt, style: .relative)) ago")
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
