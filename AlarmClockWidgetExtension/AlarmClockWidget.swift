import WidgetKit
import SwiftUI
import AppIntents
import ActivityKit
import AlarmClockShared
import os.log

/// Live Activity Intent to adjust the next alarm by minutes
struct AdjustNextAlarmLiveIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Adjust Next Alarm"
    static let description = IntentDescription("Adjust the next alarm time by the configured step")
    
    @Parameter(title: "Alarm ID")
    var alarmID: String
    
    @Parameter(title: "Minutes")
    var minutes: Int
    
    init() {
        self.alarmID = ""
        self.minutes = 0
    }
    
    init(alarmID: UUID, minutes: Int) {
        self.alarmID = alarmID.uuidString
        self.minutes = minutes
    }
    
    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: alarmID) else {
            return .result(dialog: "Invalid alarm ID")
        }
        
        let service = WidgetAlarmService()
        do {
            let success = try await service.adjustNextAlarm(alarmID: uuid, minutes: minutes)
            if success {
                return .result(dialog: "Adjusted alarm by \(minutes >= 0 ? "+" : "")\(minutes) minutes")
            } else {
                return .result(dialog: "Could not adjust alarm - alarm may have changed")
            }
        } catch {
            return .result(dialog: "Failed to adjust alarm: \(error.localizedDescription)")
        }
    }
}

/// Live Activity Intent to reset the next alarm to base schedule
struct ResetNextAlarmLiveIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Reset Next Alarm"
    static let description = IntentDescription("Reset the next alarm to its base schedule")
    
    @Parameter(title: "Alarm ID")
    var alarmID: String
    
    init() {
        self.alarmID = ""
    }
    
    init(alarmID: UUID) {
        self.alarmID = alarmID.uuidString
    }
    
    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: alarmID) else {
            return .result(dialog: "Invalid alarm ID")
        }
        
        let service = WidgetAlarmService()
        do {
            let success = try await service.resetNextAlarm(alarmID: uuid)
            if success {
                return .result(dialog: "Reset alarm to base schedule")
            } else {
                return .result(dialog: "Could not reset alarm - alarm may have changed")
            }
        } catch {
            return .result(dialog: "Failed to reset alarm: \(error.localizedDescription)")
        }
    }
}

/// Live Activity Intent to skip the next occurrence
struct SkipNextAlarmLiveIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip Next Alarm"
    static let description = IntentDescription("Skip the next occurrence of the alarm")
    
    @Parameter(title: "Alarm ID")
    var alarmID: String
    
    init() {
        self.alarmID = ""
    }
    
    init(alarmID: UUID) {
        self.alarmID = alarmID.uuidString
    }
    
    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: alarmID) else {
            return .result(dialog: "Invalid alarm ID")
        }
        
        let service = WidgetAlarmService()
        do {
            let success = try await service.skipNextAlarm(alarmID: uuid)
            if success {
                return .result(dialog: "Skipped next alarm")
            } else {
                return .result(dialog: "Could not skip alarm - alarm may have changed")
            }
        } catch {
            return .result(dialog: "Failed to skip alarm: \(error.localizedDescription)")
        }
    }
}

/// Live Activity Intent to undo skip for the next occurrence
struct UndoSkipAlarmLiveIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Undo Skip Alarm"
    static let description = IntentDescription("Restore a skipped alarm occurrence")
    
    @Parameter(title: "Alarm ID")
    var alarmID: String
    
    init() {
        self.alarmID = ""
    }
    
    init(alarmID: UUID) {
        self.alarmID = alarmID.uuidString
    }
    
    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: alarmID) else {
            return .result(dialog: "Invalid alarm ID")
        }
        
        let service = WidgetAlarmService()
        do {
            let success = try await service.undoSkipAlarm(alarmID: uuid)
            if success {
                return .result(dialog: "Restored skipped alarm")
            } else {
                return .result(dialog: "Could not restore alarm - alarm may have changed")
            }
        } catch {
            return .result(dialog: "Failed to restore alarm: \(error.localizedDescription)")
        }
    }
}

/// The main widget bundle for the Alarm Clock Lock Screen widget and control.
/// Apple's WidgetKit architecture hosts both widgets and controls in a single
/// WidgetBundle inside the widget extension.
@main
struct AlarmClockWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextAlarmWidget()
        NextAlarmControl()
        NextAlarmLiveActivity()
    }
}

struct NextAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NextAlarmAttributes.self) { context in
            NextAlarmLockScreenView(state: context.state)
        } dynamicIsland: { context in
            NextAlarmDynamicIsland.make(context: context)
        }
    }
}

/// Lock Screen widget displaying the next scheduled alarm
struct NextAlarmWidget: Widget {
    let kind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockWidgetKind") as? String
        ?? "com.example.alarmclock.next-alarm-widget"

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

/// Lock Screen bottom-area control button for the next alarm.
struct NextAlarmControl: ControlWidget {
    static let kind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockControlKind") as? String
        ?? "com.example.alarmclock.next-alarm-control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenNextAlarmIntent()) {
                Label("Next Alarm", systemImage: "alarm.fill")
            }
        }
        .displayName("Next Alarm")
        .description("Opens the Next Alarm control screen.")
    }
}

/// App Intent to open the Next Alarm control screen
struct OpenNextAlarmIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Next Alarm"

    @Parameter(title: "Destination")
    var target: AlarmDestination

    init() {
        self.target = .nextAlarm
    }

    func perform() async throws -> some IntentResult {
        // The OpenIntent protocol opens the app automatically.
        return .result()
    }
}

/// Enum representing where the control can navigate
enum AlarmDestination: String, AppEnum {
    case nextAlarm

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Alarm Destination")

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .nextAlarm: DisplayRepresentation(
            title: "Next Alarm",
            subtitle: "View and control the next scheduled alarm"
        )
    ]
}

/// Timeline provider for the next alarm widget
struct NextAlarmWidgetProvider: TimelineProvider {
    typealias Entry = NextAlarmWidgetEntry
    
    private var appGroupIdentifier: String {
        let configured = Bundle.main.object(
            forInfoDictionaryKey: "AlarmClockAppGroupIdentifier"
        ) as? String ?? "group.com.example.alarmclock"
        let resigned = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        return resigned.first { $0 == configured || $0.hasPrefix(configured + ".") } ?? configured
    }
    private let snapshotFileName = "nextAlarmSnapshot.json"
    
    func placeholder(in context: Context) -> NextAlarmWidgetEntry {
        NextAlarmWidgetEntry(
            date: Date(),
            alarmLabel: "Morning Alarm",
            nextTime: "7:00 AM",
            dateIndicator: "Today",
            hasAlarm: true,
            alarmID: UUID()
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
        WidgetDiagnostics.widgetLogEvent("Widget loadEntry started", appGroupIdentifier: appGroupIdentifier)
        
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            WidgetDiagnostics.widgetLogEvent("Failed to get App Group container URL", 
                appGroupIdentifier: appGroupIdentifier, 
                containerAvailable: false)
            return NextAlarmWidgetEntry(
                date: Date(),
                alarmLabel: "No upcoming alarm",
                nextTime: "--:--",
                dateIndicator: "",
                hasAlarm: false,
                alarmID: nil
            )
        }
        
        WidgetDiagnostics.widgetLogEvent("App Group container available", 
            appGroupIdentifier: appGroupIdentifier, 
            containerAvailable: true)
        
        let snapshotURL = appGroupURL.appendingPathComponent(snapshotFileName)
        
        let fileExists = FileManager.default.fileExists(atPath: snapshotURL.path)
        WidgetDiagnostics.widgetLogEvent("Checked snapshot file existence", 
            appGroupIdentifier: appGroupIdentifier, 
            containerAvailable: true,
            fileExists: fileExists)
        
        guard fileExists else {
            WidgetDiagnostics.widgetLogEvent("Snapshot file does not exist, returning empty entry", 
                appGroupIdentifier: appGroupIdentifier, 
                containerAvailable: true,
                fileExists: false,
                entryHasAlarm: false)
            return NextAlarmWidgetEntry(
                date: Date(),
                alarmLabel: "No upcoming alarm",
                nextTime: "--:--",
                dateIndicator: "",
                hasAlarm: false,
                alarmID: nil
            )
        }
        
        guard let data = try? Data(contentsOf: snapshotURL) else {
            WidgetDiagnostics.widgetLogEvent("Failed to read snapshot file data", 
                appGroupIdentifier: appGroupIdentifier, 
                containerAvailable: true,
                fileExists: true,
                readSuccess: false,
                readError: "Data(contentsOf:) failed",
                entryHasAlarm: false)
            return NextAlarmWidgetEntry(
                date: Date(),
                alarmLabel: "No upcoming alarm",
                nextTime: "--:--",
                dateIndicator: "",
                hasAlarm: false,
                alarmID: nil
            )
        }
        
        WidgetDiagnostics.widgetLogEvent("Snapshot file read successfully", 
            appGroupIdentifier: appGroupIdentifier, 
            containerAvailable: true,
            fileExists: true,
            readSuccess: true)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard let snapshot = try? decoder.decode(NextAlarmSnapshot.self, from: data) else {
            WidgetDiagnostics.widgetLogEvent("Failed to decode snapshot JSON", 
                appGroupIdentifier: appGroupIdentifier, 
                containerAvailable: true,
                fileExists: true,
                readSuccess: true,
                decodeSuccess: false,
                decodeError: "JSONDecoder.decode failed",
                entryHasAlarm: false)
            return NextAlarmWidgetEntry(
                date: Date(),
                alarmLabel: "No upcoming alarm",
                nextTime: "--:--",
                dateIndicator: "",
                hasAlarm: false,
                alarmID: nil
            )
        }
        
        WidgetDiagnostics.widgetLogEvent("Snapshot decoded successfully", 
            appGroupIdentifier: appGroupIdentifier, 
            containerAvailable: true,
            fileExists: true,
            readSuccess: true,
            decodeSuccess: true,
            snapshotAlarmID: snapshot.alarmID,
            snapshotLabel: snapshot.label,
            snapshotNextOccurrence: snapshot.nextOccurrenceDate,
            snapshotIsEnabled: snapshot.isEnabled)
        
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
        
        let entry = NextAlarmWidgetEntry(
            date: Date(),
            alarmLabel: snapshot.label,
            nextTime: formatter.string(from: snapshot.nextOccurrenceDate),
            dateIndicator: dateIndicator,
            hasAlarm: true,
            alarmID: snapshot.alarmID
        )
        
        WidgetDiagnostics.widgetLogEvent("Widget entry created", 
            appGroupIdentifier: appGroupIdentifier, 
            containerAvailable: true,
            fileExists: true,
            readSuccess: true,
            decodeSuccess: true,
            snapshotAlarmID: snapshot.alarmID,
            snapshotLabel: snapshot.label,
            snapshotNextOccurrence: snapshot.nextOccurrenceDate,
            snapshotIsEnabled: snapshot.isEnabled,
            entryHasAlarm: entry.hasAlarm)
        
        return entry
    }
}

/// Timeline entry for the next alarm widget
struct NextAlarmWidgetEntry: TimelineEntry {
    let date: Date
    let alarmLabel: String
    let nextTime: String
    let dateIndicator: String
    let hasAlarm: Bool
    let alarmID: UUID?
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
    
    @ViewBuilder
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
