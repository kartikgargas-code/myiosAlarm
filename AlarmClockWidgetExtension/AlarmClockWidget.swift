import WidgetKit
import SwiftUI
import AppIntents
import ActivityKit
import AlarmClockShared
import os.log
import CoreFoundation
import AlarmKit

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
        SmartWakeDebugLog.log("INTENT STEP: queued action=skipNext")
        
        // First, queue the pending action for the app to apply AlarmKit scheduling
        try await queuePendingWidgetAction(PendingWidgetAction.skip, reason: "skipNext")
        SmartWakeDebugLog.log("INTENT STEP: snapshot-loaded action=skipNext")
        
        // Also update the widget snapshot locally so the Lock Screen updates immediately
        let service = WidgetAlarmService()
        do {
            let snapshot = try service.loadSnapshot()
            let engine = AlarmEngine(snapshot: snapshot)
            SmartWakeDebugLog.log("INTENT STEP: snapshot-loaded action=skipNext")
            
            guard let occurrence = engine.earliestOccurrence(now: Date()) else {
                SmartWakeDebugLog.log("INTENT SNAPSHOT SKIP: no occurrence action=skipNext")
                return .result()
            }
            SmartWakeDebugLog.log("INTENT STEP: occurrence=\(occurrence.effectiveDate) alarm=\(occurrence.alarmID) action=skipNext")
            
            guard let alarm = engine.alarm(id: occurrence.alarmID), alarm.isEnabled else {
                SmartWakeDebugLog.log("INTENT SNAPSHOT SKIP: alarm not found action=skipNext")
                return .result()
            }
            SmartWakeDebugLog.log("INTENT STEP: mutated action=skipNext")
            
            // Call skipNextAlarm but always write snapshot + reload, even if guard fails
            let success = try await service.skipNextAlarm(alarmID: alarm.id)
            SmartWakeDebugLog.log("INTENT STEP: snapshot-written action=skipNext success=\(success)")
            
            // Force reload for both widget and control kinds
            if let widgetKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockWidgetKind") as? String {
                WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
                SmartWakeDebugLog.log("INTENT STEP: reloaded kind=\(widgetKind) action=skipNext")
            }
            if let controlKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockControlKind") as? String {
                WidgetCenter.shared.reloadTimelines(ofKind: controlKind)
                SmartWakeDebugLog.log("INTENT STEP: reloaded kind=\(controlKind) action=skipNext")
            }
        } catch {
            SmartWakeDebugLog.log("INTENT SNAPSHOT ERROR: \(error.localizedDescription) action=skipNext")
        }
        
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
        SmartWakeDebugLog.log("INTENT STEP: queued action=adjust-10")
        
        // First, queue the pending action for the app to apply AlarmKit scheduling
        try await queuePendingWidgetAction(PendingWidgetAction.adjustEarlier, reason: "adjust-10")
        SmartWakeDebugLog.log("INTENT STEP: snapshot-loaded action=adjust-10")
        
        // Also update the widget snapshot locally so the Lock Screen updates immediately
        let service = WidgetAlarmService()
        do {
            let snapshot = try service.loadSnapshot()
            let engine = AlarmEngine(snapshot: snapshot)
            SmartWakeDebugLog.log("INTENT STEP: snapshot-loaded action=adjust-10")
            
            guard let occurrence = engine.earliestOccurrence(now: Date()) else {
                SmartWakeDebugLog.log("INTENT SNAPSHOT SKIP: no occurrence action=adjust-10")
                return .result()
            }
            SmartWakeDebugLog.log("INTENT STEP: occurrence=\(occurrence.effectiveDate) alarm=\(occurrence.alarmID) action=adjust-10")
            
            guard let alarm = engine.alarm(id: occurrence.alarmID), alarm.isEnabled else {
                SmartWakeDebugLog.log("INTENT SNAPSHOT SKIP: alarm not found action=adjust-10")
                return .result()
            }
            SmartWakeDebugLog.log("INTENT STEP: mutated action=adjust-10")
            
            // Call adjustNextAlarm but always write snapshot + reload, even if guard fails
            let success = try await service.adjustNextAlarm(alarmID: alarm.id, minutes: -10)
            SmartWakeDebugLog.log("INTENT STEP: snapshot-written action=adjust-10 success=\(success)")
            
            // Force reload for both widget and control kinds
            if let widgetKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockWidgetKind") as? String {
                WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
                SmartWakeDebugLog.log("INTENT STEP: reloaded kind=\(widgetKind) action=adjust-10")
            }
            if let controlKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockControlKind") as? String {
                WidgetCenter.shared.reloadTimelines(ofKind: controlKind)
                SmartWakeDebugLog.log("INTENT STEP: reloaded kind=\(controlKind) action=adjust-10")
            }
        } catch {
            SmartWakeDebugLog.log("INTENT SNAPSHOT ERROR: \(error.localizedDescription) action=adjust-10")
        }
        
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
        SmartWakeDebugLog.log("INTENT STEP: queued action=adjust+10")
        
        // First, queue the pending action for the app to apply AlarmKit scheduling
        try await queuePendingWidgetAction(PendingWidgetAction.adjustLater, reason: "adjust+10")
        SmartWakeDebugLog.log("INTENT STEP: snapshot-loaded action=adjust+10")
        
        // Also update the widget snapshot locally so the Lock Screen updates immediately
        let service = WidgetAlarmService()
        do {
            let snapshot = try service.loadSnapshot()
            let engine = AlarmEngine(snapshot: snapshot)
            SmartWakeDebugLog.log("INTENT STEP: snapshot-loaded action=adjust+10")
            
            guard let occurrence = engine.earliestOccurrence(now: Date()) else {
                SmartWakeDebugLog.log("INTENT SNAPSHOT SKIP: no occurrence action=adjust+10")
                return .result()
            }
            SmartWakeDebugLog.log("INTENT STEP: occurrence=\(occurrence.effectiveDate) alarm=\(occurrence.alarmID) action=adjust+10")
            
            guard let alarm = engine.alarm(id: occurrence.alarmID), alarm.isEnabled else {
                SmartWakeDebugLog.log("INTENT SNAPSHOT SKIP: alarm not found action=adjust+10")
                return .result()
            }
            SmartWakeDebugLog.log("INTENT STEP: mutated action=adjust+10")
            
            // Call adjustNextAlarm but always write snapshot + reload, even if guard fails
            let success = try await service.adjustNextAlarm(alarmID: alarm.id, minutes: 10)
            SmartWakeDebugLog.log("INTENT STEP: snapshot-written action=adjust+10 success=\(success)")
            
            // Force reload for both widget and control kinds
            if let widgetKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockWidgetKind") as? String {
                WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
                SmartWakeDebugLog.log("INTENT STEP: reloaded kind=\(widgetKind) action=adjust+10")
            }
            if let controlKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockControlKind") as? String {
                WidgetCenter.shared.reloadTimelines(ofKind: controlKind)
                SmartWakeDebugLog.log("INTENT STEP: reloaded kind=\(controlKind) action=adjust+10")
            }
        } catch {
            SmartWakeDebugLog.log("INTENT SNAPSHOT ERROR: \(error.localizedDescription) action=adjust+10")
        }
        
        return .result()
    }
}

/// Shared Control Center intent flow: resolve the actual NEXT alarm (earliest
/// occurrence, not snapshot order), record the AlarmKit authorization probe,
/// queue a pending action file for the app to apply, and wake the app.
/// The widget never rewrites alarms.json (the app would overwrite it) and no
/// longer touches AlarmKit directly — the app is the only party that can be
/// authorized, so it is the only canceller/scheduler.
@MainActor
private func queuePendingWidgetAction(_ action: String, reason: String) async throws {
    let service = WidgetAlarmService()
    let snapshot = try service.loadSnapshot()
    let engine = AlarmEngine(snapshot: snapshot)

    // Target the alarm the user means: the one with the earliest occurrence.
    guard let occurrence = engine.earliestOccurrence(now: Date()),
          let alarm = engine.alarm(id: occurrence.alarmID), alarm.isEnabled else {
        SmartWakeDebugLog.log("WIDGET ACTION: \(reason) no enabled alarm (count=\(snapshot.alarms.count))")
        return
    }

    var orderSummary = ""
    if let next = snapshot.alarms.first(where: { $0.isEnabled }) {
        orderSummary = " first-enabled-in-order=\(next.label.isEmpty ? "?" : next.label)/id=\(next.id.uuidString.prefix(8))"
    }
    SmartWakeDebugLog.log("WIDGET ACTION TARGET: \(reason) action=\(action) picked label=\"\(alarm.label)\" time=\(alarm.time) id=\(alarm.id.uuidString.prefix(8)) at \(occurrence.effectiveDate) (count=\(snapshot.alarms.count)\(orderSummary))")

    // Authorization probe: the extension historically stayed notDetermined.
    // Log the full state and the request result once per press so we learn
    // whether an extension can ever obtain AlarmKit authorization. The queued
    // action applies through the app regardless of this outcome.
    let authState = AlarmManager.shared.authorizationState
    if authState == .authorized {
        SmartWakeDebugLog.log("WIDGET AUTH: authorized (no request needed) for \(reason)")
    } else if authState == .notDetermined {
        do {
            let returned = try await AlarmManager.shared.requestAuthorization()
            SmartWakeDebugLog.log("WIDGET AUTH REQUEST: returned=\(String(describing: returned)) state-after=\(String(describing: AlarmManager.shared.authorizationState))")
        } catch {
            SmartWakeDebugLog.log("WIDGET AUTH REQUEST FAILED: \(error.localizedDescription) (state=\(String(describing: authState)))")
        }
    } else {
        SmartWakeDebugLog.log("WIDGET AUTH: state=\(String(describing: authState)) (not requesting) for \(reason)")
    }

    try service.writePendingAction(
        PendingWidgetAction(action: action, alarmID: alarm.id, requestedAt: Date())
    )
    SmartWakeDebugLog.log("WIDGET ACTION: \(reason) alarmID=\(alarm.id.uuidString)")

    postDarwinNotification("com.example.alarmclock.widget.changed")
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
