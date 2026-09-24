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

    /// Reads the container once, so every entry carries the stamp as of this
    /// rebuild: the app's reloads (`ConduitStatusSnapshot.reloadDecision`) are
    /// what bring a new stamp to the Lock Screen. The entries are 5 minutes
    /// apart so the iOS 17 static age advances between rebuilds.
    ///
    /// Hourly baseline refresh (`ConduitStatusSnapshot.timelineRefreshInterval`),
    /// well under the ~40-70/day the system budgets, leaving the rest of the
    /// allowance for the app's background reloads. Kept until the iOS 18+ live
    /// age text is verified to tick on a device: if it does not, this cadence
    /// is what bounds how stale a static render can get.
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
/// reference-date format restricted to hour/minute fields
/// (`ConduitStatusSnapshot.liveAgeFormat`). It is anchored to the stamp this
/// timeline was built with, so it can only advance the age of that stamp; a
/// newer sync arrives with the app's reload. iOS 17 has no such format, so it
/// renders static text against the entry date, which the 5-minute entries
/// advance.
///
/// The live `Text` is its own view, never interpolated into another `Text`:
/// whether an embedded live segment stays live in WidgetKit's archived render
/// is undocumented, and whether this text ticks on a device at all is still
/// to be verified. Any prefix is a separate `Text` on the line above the age:
/// two `Text`s in a row cannot wrap into each other, so a single row squeezed
/// the age into a truncated column of its own ("Synced 44 / minute…"); on
/// the simulator Lock Screen a one-line layout was never chosen even for
/// "now".
private struct LastSyncedAge: View {
    let lastSyncedAt: Date
    let now: Date
    var prefix = ""

    /// The system format already reads "5 minutes ago", so callers must not
    /// append their own "ago".
    var body: some View {
        if #available(iOS 18, *) {
            if prefix.isEmpty {
                liveAge
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(prefix.trimmingCharacters(in: .whitespaces))
                    liveAge
                }
                .lineLimit(1)
            }
        } else {
            Text("\(prefix)\(ConduitStatusSnapshot.coarseAge(from: lastSyncedAt, to: now)) ago")
        }
    }

    @available(iOS 18, *)
    private var liveAge: Text {
        Text(.currentDate, format: ConduitStatusSnapshot.liveAgeFormat(for: lastSyncedAt))
    }
}

/// Primary family: a relative-time line (see `LastSyncedAge`) plus one
/// conditional second line. See `ConduitStatusSnapshot.secondLine`.
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
                            .minimumScaleFactor(0.8)
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
/// The age ("37 minutes ago") wraps to two lines, so it is centered and inset
/// to stay inside the circular mask, which otherwise clips its left edge.
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
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 8)
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
                    if #available(iOS 18, *) {
                        // The inline slot renders only the first `Text` it
                        // finds, so a separate prefix would be all it showed
                        // ("Conduit · Synced", no age). The live age stands
                        // alone, beside the state symbol.
                        LastSyncedAge(lastSyncedAt: lastSyncedAt, now: date)
                    } else {
                        // The inline slot is one short line, so shed the prefix
                        // rather than let the system truncate the age itself.
                        ViewThatFits {
                            LastSyncedAge(lastSyncedAt: lastSyncedAt, now: date, prefix: "Conduit · Synced ")
                            LastSyncedAge(lastSyncedAt: lastSyncedAt, now: date, prefix: "Synced ")
                            LastSyncedAge(lastSyncedAt: lastSyncedAt, now: date)
                        }
                    }
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
