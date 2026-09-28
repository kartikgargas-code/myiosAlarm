import WidgetKit
import SwiftUI

/// The main widget bundle for the Alarm Clock Lock Screen widget
@main
struct AlarmClockWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextAlarmWidget()
    }
}

/// Lock Screen widget displaying the next scheduled alarm
struct NextAlarmWidget: Widget {
    let kind: String = "com.example.alarmclock.next-alarm-widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextAlarmWidgetProvider()) { entry in
            NextAlarmWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next Alarm")
        .description("Shows the next scheduled alarm time and name.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// Timeline provider for the next alarm widget
struct NextAlarmWidgetProvider: TimelineProvider {
    typealias Entry = NextAlarmWidgetEntry
    
    private let appGroupIdentifier = "group.com.example.alarmclock"
    private let snapshotFileName = "nextAlarmSnapshot.json"
    
    func placeholder(in context: Context) -> NextAlarmWidgetEntry {
        NextAlarmWidgetEntry(
            date: Date(),
            alarmLabel: "Morning Alarm",
            nextTime: "7:00 AM",
            dateIndicator: "Today",
            hasAlarm: true
        )
    }
    
    func getSnapshot(in context: Context, completion: @escaping (NextAlarmWidgetEntry) -> Void) {
        let entry = loadEntry()
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<NextAlarmWidgetEntry>) -> Void) {
        let currentDate = Date()
        let entry = loadEntry()
        
        // Request update in 15 minutes, but also at the next occurrence time if we have one
        var nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: currentDate) ?? currentDate
        
        // If we have a next alarm time, schedule update around that time too
        if entry.hasAlarm {
            let formatter = ISO8601DateFormatter()
            // We could parse the next occurrence time, but for simplicity use 15 min
        }
        
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
    
    private func loadEntry() -> NextAlarmWidgetEntry {
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return NextAlarmWidgetEntry(
                date: Date(),
                alarmLabel: "No upcoming alarm",
                nextTime: "--:--",
                dateIndicator: "",
                hasAlarm: false
            )
        }
        
        let snapshotURL = appGroupURL.appendingPathComponent(snapshotFileName)
        
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(NextAlarmSnapshot.self, from: data) else {
            return NextAlarmWidgetEntry(
                date: Date(),
                alarmLabel: "No upcoming alarm",
                nextTime: "--:--",
                dateIndicator: "",
                hasAlarm: false
            )
        }
        
        // Convert snapshot to widget entry
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"
        
        let calendar = Calendar.current
        let now = Date()
        
        let dateIndicator: String
        if calendar.isDate(snapshot.nextOccurrenceDate, inSameDayAs: now) {
            dateIndicator = "Today"
        } else if calendar.isDate(snapshot.nextOccurrenceDate, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now) {
            dateIndicator = "Tomorrow"
        } else {
            dateIndicator = dateFormatter.string(from: snapshot.nextOccurrenceDate)
        }
        
        return NextAlarmWidgetEntry(
            date: Date(),
            alarmLabel: snapshot.label,
            nextTime: formatter.string(from: snapshot.nextOccurrenceDate),
            dateIndicator: dateIndicator,
            hasAlarm: true
        )
    }
}

/// Timeline entry for the next alarm widget
struct NextAlarmWidgetEntry: TimelineEntry {
    let date: Date
    let alarmLabel: String
    let nextTime: String
    let dateIndicator: String
    let hasAlarm: Bool
}

/// SwiftUI view for the Lock Screen widget
struct NextAlarmWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: NextAlarmWidgetEntry
    
    var body: some View {
        switch family {
        case .accessoryCircular:
            accessoryCircularView
        case .accessoryRectangular:
            accessoryRectangularView
        case .accessoryInline:
            accessoryInlineView
        default:
            Text("Unsupported")
        }
    }
    
    private var accessoryCircularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 2) {
                if entry.hasAlarm {
                    Image(systemName: "alarm.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text(entry.nextTime)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.5)
                } else {
                    Image(systemName: "alarm.slash")
                        .font(.system(size: 16, weight: .bold))
                    Text("No Alarm")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.5)
                }
            }
            .foregroundStyle(.white)
        }
    }
    
    private var accessoryRectangularView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if entry.hasAlarm {
                HStack(spacing: 6) {
                    Image(systemName: "alarm.fill")
                        .font(.system(size: 16, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.alarmLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(entry.dateIndicator)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(entry.nextTime)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "alarm.slash")
                        .font(.system(size: 16, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("No Upcoming Alarm")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
    
    private var accessoryInlineView: some View {
        if entry.hasAlarm {
            HStack(spacing: 4) {
                Image(systemName: "alarm.fill")
                Text("\(entry.alarmLabel) \(entry.nextTime)")
                    .font(.system(size: 14, weight: .semibold))
                Text("(\(entry.dateIndicator))")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "alarm.slash")
                Text("No upcoming alarm")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
    }
}