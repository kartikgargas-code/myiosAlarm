import WidgetKit
import SwiftUI
import AppIntents
import ActivityKit
import AlarmClockShared
import os.log
import CoreFoundation
import AlarmKit
import ExtensionAlarmSchedulingService

/// The main widget bundle for the Alarm Clock Lock Screen widget and control.
/// Apple's WidgetKit architecture hosts both widgets and controls in a single
/// WidgetBundle inside the widget extension.
@main
struct AlarmClockWidgetBundle: WidgetBundle {
    init() {
        // Register the Live Activity alarm service for the widget extension
        // WidgetKit extension @main entry points already run on the main thread
        MainActor.assumeIsolated {
            WidgetAlarmServiceRegistrar.register()
        }
    }
    
    var body: some Widget {
        NextAlarmWidget()
        NextAlarmControl()
        NextAlarmLiveActivity()
        // Control Center buttons (headless AppIntents)
        SkipNextAlarmControl()
        AlarmMinus10Control()
        AlarmPlus10Control()
    }
}

/// Register the Live Activity alarm service for the widget extension
struct WidgetAlarmServiceRegistrar {
    @MainActor
    static func register() {
        LiveActivityAlarmServiceProvider.shared = WidgetAlarmService()
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
struct OpenNextAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Next Alarm"
    static let openAppWhenRun: Bool = true

    init() {}
    
    func perform() async throws -> some IntentResult {
        return .result()
    }
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


/// Register the Live Activity alarm service for the widget extension
struct NextAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NextAlarmAttributes.self) { context in
            NextAlarmLockScreenView(state: context.state)
        } dynamicIsland: { context in
            NextAlarmDynamicIsland.make(context: context)
        }
    }
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

// MARK: - Control Center AppIntents (headless, static openAppWhenRun = false)

/// Skip the next alarm occurrence
struct SkipNextAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Next Alarm"
    static let description = IntentDescription("Skip the next scheduled alarm occurrence.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let service = WidgetAlarmService()
        let scheduler = ExtensionAlarmSchedulingService()
        // Resolve the next alarm at perform time
        let snapshot = try service.loadSnapshot()
        guard let alarm = snapshot.alarms.first(where: { $0.isEnabled }) else {
            return .result()
        }
        let alarmID = alarm.id
        
        // 1. Mutate engine + persist
        _ = try await service.skipNextAlarm(alarmID: alarmID)
        
        // 2. Reconcile AlarmKit for this alarm
        try await reconcileAlarmKitForAlarm(scheduler: scheduler, alarmID: alarmID, reason: "skip")
        
        // 3. Log to App Group debug log
        SmartWakeDebugLog.log("WIDGET ACTION: skipNext alarmID=\(alarmID.uuidString)")
        
        postDarwinNotification("com.example.alarmclock.widget.changed")
        return .result()
    }
}

/// Adjust next alarm by -10 minutes
struct AlarmMinus10Intent: AppIntent {
    static let title: LocalizedStringResource = "Alarm -10 min"
    static let description = IntentDescription("Move the next alarm 10 minutes earlier.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let service = WidgetAlarmService()
        let scheduler = ExtensionAlarmSchedulingService()
        let snapshot = try service.loadSnapshot()
        guard let alarm = snapshot.alarms.first(where: { $0.isEnabled }) else {
            return .result()
        }
        let alarmID = alarm.id
        
        _ = try await service.adjustNextAlarm(alarmID: alarmID, minutes: -10)
        try await reconcileAlarmKitForAlarm(scheduler: scheduler, alarmID: alarmID, reason: "adjust-10")
        
        SmartWakeDebugLog.log("WIDGET ACTION: adjust-10 alarmID=\(alarmID.uuidString)")
        
        postDarwinNotification("com.example.alarmclock.widget.changed")
        return .result()
    }
}

/// Adjust next alarm by +10 minutes
struct AlarmPlus10Intent: AppIntent {
    static let title: LocalizedStringResource = "Alarm +10 min"
    static let description = IntentDescription("Move the next alarm 10 minutes later.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let service = WidgetAlarmService()
        let scheduler = ExtensionAlarmSchedulingService()
        let snapshot = try service.loadSnapshot()
        guard let alarm = snapshot.alarms.first(where: { $0.isEnabled }) else {
            return .result()
        }
        let alarmID = alarm.id
        
        _ = try await service.adjustNextAlarm(alarmID: alarmID, minutes: 10)
        try await reconcileAlarmKitForAlarm(scheduler: scheduler, alarmID: alarmID, reason: "adjust+10")
        
        SmartWakeDebugLog.log("WIDGET ACTION: adjust+10 alarmID=\(alarmID.uuidString)")
        
        postDarwinNotification("com.example.alarmclock.widget.changed")
        return .result()
    }
}

/// Reconcile AlarmKit for a single alarm after widget intent mutation
/// Builds minimal DesiredSystemAlarm set for the affected occurrence
@MainActor
private func reconcileAlarmKitForAlarm(
    scheduler: ExtensionAlarmSchedulingService,
    alarmID: UUID,
    reason: String
) async throws {
    let service = WidgetAlarmService()
    let snapshot = try service.loadSnapshot()
    guard let alarm = snapshot.alarms.first(where: { $0.id == alarmID }),
          let occurrence = AlarmEngine(snapshot: snapshot).nextOccurrence(for: alarmID, now: Date()) else {
        return
    }
    
    // Use a fixed built-in floor sound for shifted/skipped occurrences
    // The app re-reconciles on next foreground and will restore the real sound
    let floorSoundName = "default"
    let floorSound: AlertConfiguration.AlertSound = .named(floorSoundName)
    let label = alarm.label.isEmpty ? "Alarm" : alarm.label
    
    // Cancel existing AlarmKit alarms for this occurrence by scanning metadata
    let kitAlarms = (try? AlarmManager.shared.alarms) ?? []
    let occurrenceKey = occurrence.occurrenceKey
    for kitAlarm in kitAlarms {
        if let metadata = kitAlarm.attributes.metadata as? ExtensionAlarmSchedulingService.ScheduledOccurrenceMetadata {
            if metadata.alarmID == alarmID && metadata.occurrenceKey.hasPrefix(occurrenceKey) {
                try? AlarmManager.shared.cancel(id: kitAlarm.id)
                SmartWakeDebugLog.log("WIDGET RECONCILE CANCEL: \(kitAlarm.id.uuidString) for \(metadata.occurrenceKey)")
            }
        }
    }
    
    // Schedule new AlarmKit alarm at the new time with floor sound
    let newDesired = ExtensionAlarmSchedulingService.DesiredSystemAlarm(
        id: ExtensionAlarmSchedulingService.SystemScheduleID.make(
            for: occurrence,
            label: label,
            sound: alarm.sound,
            loudness: alarm.loudness
        ),
        occurrence: occurrence,
        label: label,
        sound: alarm.sound,
        alarmKitSound: floorSound,
        snoozeDurationMinutes: alarm.snoozeDurationMinutes
    )
    
    let managedIDs = Set(snapshot.managedSystemAlarmIDs)
    _ = try await scheduler.reconcile(desired: [newDesired], managedIDs: managedIDs, reason: reason)
    
    SmartWakeDebugLog.log("WIDGET RECONCILE SCHEDULE: \(newDesired.id.uuidString) at \(occurrence.effectiveDate) for \(reason)")
}

/// Control Widget Button: Skip next alarm
struct SkipNextAlarmControl: ControlWidget {
    static let kind = "com.example.alarmclock.control.skip-next"
    
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: SkipNextAlarmIntent()) {
                Label("Skip Next Alarm", systemImage: "forward.end")
            }
        }
        .displayName("Skip Next Alarm")
        .description("Skip the next alarm occurrence.")
    }
}

/// Control Widget Button: Alarm -10 min
struct AlarmMinus10Control: ControlWidget {
    static let kind = "com.example.alarmclock.control.minus10"
    
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: AlarmMinus10Intent()) {
                Label("Alarm -10 min", systemImage: "minus.circle")
            }
        }
        .displayName("Alarm -10 min")
        .description("Move the next alarm 10 minutes earlier.")
    }
}

/// Control Widget Button: Alarm +10 min
struct AlarmPlus10Control: ControlWidget {
    static let kind = "com.example.alarmclock.control.plus10"
    
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: AlarmPlus10Intent()) {
                Label("Alarm +10 min", systemImage: "plus.circle")
            }
        }
        .displayName("Alarm +10 min")
        .description("Move the next alarm 10 minutes later.")
    }
}

/// Darwin notification bridge for widget-to-app communication
private func postDarwinNotification(_ name: String) {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let name = CFNotificationName(name as CFString)
    CFNotificationCenterPostNotification(center, name, nil, nil, true)
}
