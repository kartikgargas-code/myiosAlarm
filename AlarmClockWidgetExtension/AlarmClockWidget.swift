import WidgetKit
import UIKit
import SwiftUI
import AppIntents
import ActivityKit
import AlarmClockShared
import os.log
import CoreFoundation
import AlarmKit
import UserNotifications

private func readBatteryLevel() -> Double? {
    UIDevice.current.isBatteryMonitoringEnabled = true
    let level = UIDevice.current.batteryLevel
    return level >= 0 ? Double(level) : nil
}

private func systemMemoryUsedBytes() -> UInt64? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }

    var pageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

    let page = UInt64(pageSize)
    let active = UInt64(stats.active_count) * page
    let inactive = UInt64(stats.inactive_count) * page
    let wired = UInt64(stats.wire_count) * page
    let compressed = UInt64(stats.compressor_page_count) * page
    return active + inactive + wired + compressed
}

private func systemMemoryTotalBytes() -> UInt64 {
    ProcessInfo.processInfo.physicalMemory
}

private func resolvedAppGroupIdentifier() -> String {
    let configured = Bundle.main.object(forInfoDictionaryKey: "AlarmClockAppGroupIdentifier") as? String
        ?? "group.com.example.alarmclock"
    let resigned = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
    return resigned.first { $0 == configured || $0.hasPrefix(configured + ".") } ?? configured
}

private func widgetDefaults() -> UserDefaults {
    UserDefaults(suiteName: resolvedAppGroupIdentifier()) ?? .standard
}

/// The main widget bundle for the Alarm Clock Lock Screen widget and control.
/// Apple's WidgetKit architecture hosts both widgets and controls in a single
/// WidgetBundle inside the widget extension.
@main
struct AlarmClockWidgetBundle: WidgetBundle {
    init() {
        SmartWakeDebugLog.log("WIDGET extension launched", force: true)
        // Register the Live Activity alarm service for the widget extension
        // WidgetKit extension @main entry points already run on the main thread
        MainActor.assumeIsolated {
            WidgetAlarmServiceRegistrar.register()
        }
    }
    
    var body: some Widget {
        NextAlarmWidget()
        BatteryWidget()
        MemoryWidget()
        NextAlarmLiveActivity()
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

/// Lock Screen widget showing how much of the phone's memory is in use. Tapping it opens the app.
struct MemoryWidget: Widget {
    let kind = "com.example.alarmclock.memory-widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MemoryWidgetProvider()) { entry in
            MemoryWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Memory")
        .description("Shows how much of the phone's memory is in use.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct MemoryWidgetEntry: TimelineEntry {
    let date: Date
    let usedFraction: Double?
}

struct MemoryWidgetProvider: TimelineProvider {
    typealias Entry = MemoryWidgetEntry

    func placeholder(in context: Context) -> MemoryWidgetEntry {
        MemoryWidgetEntry(date: Date(), usedFraction: 0.62)
    }

    func getSnapshot(in context: Context, completion: @escaping (MemoryWidgetEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoryWidgetEntry>) -> Void) {
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        let entry = makeEntry()
        SmartWakeDebugLog.log("WIDGET memory timeline used=\(entry.usedFraction.map { String(Int(($0 * 100).rounded())) } ?? "-")", force: true)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func makeEntry() -> MemoryWidgetEntry {
        MemoryWidgetEntry(date: Date(), usedFraction: memoryUsedFraction())
    }
}

func memoryUsedFraction() -> Double? {
    guard let used = systemMemoryUsedBytes() else { return nil }
    let total = systemMemoryTotalBytes()
    guard total > 0 else { return nil }
    return min(1.0, max(0.0, Double(used) / Double(total)))
}

struct MemoryWidgetView: View {
    let entry: MemoryWidgetEntry

    var body: some View {
        let defaults = widgetDefaults()
        let showCircle = defaults.object(forKey: "widgetBatteryShowCircle") as? Bool ?? true
        let showText = defaults.object(forKey: "widgetBatteryShowText") as? Bool ?? true
        let circleScale = defaults.object(forKey: "widgetBatteryCircleScale") as? Double ?? 1.0
        let textScale = defaults.object(forKey: "widgetBatteryTextScale") as? Double ?? 1.0
        let ringWidth = CGFloat(5 * circleScale)

        ZStack {
            AccessoryWidgetBackground()
            ZStack {
                if showCircle {
                    Circle()
                        .inset(by: ringWidth / 2)
                        .stroke(Color.white.opacity(0.25), lineWidth: ringWidth)
                    Circle()
                        .inset(by: ringWidth / 2)
                        .trim(from: 0, to: max(0.001, entry.usedFraction ?? 0))
                        .stroke(usedColour, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if showText {
                    Text(percentText)
                        .font(.system(size: CGFloat(16 * textScale), weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.4)
                        .foregroundStyle(.white)
                }
            }
            .padding(2)
        }
    }

    private var usedColour: Color {
        let used = entry.usedFraction ?? 0
        if used >= 0.85 { return .red }
        if used >= 0.60 { return .orange }
        return .green
    }

    private var percentText: String {
        guard let used = entry.usedFraction else { return "--" }
        return "\(Int((used * 100).rounded()))%"
    }
}

/// Lock Screen widget showing the phone's battery as a coloured ring.
struct BatteryWidget: Widget {
    let kind = "com.example.alarmclock.battery-widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BatteryWidgetProvider()) { entry in
            BatteryWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Battery")
        .description("Shows your phone's battery level.")
        .supportedFamilies([.accessoryCircular, .systemSmall])
    }
}

struct BatteryWidgetEntry: TimelineEntry {
    let date: Date
    let level: Double?
    let showCircle: Bool
    let showText: Bool
    let circleScale: Double
    let textScale: Double
    let showPercentSign: Bool
    let plateOpacity: Double
    let homeShowCircle: Bool
    let homeShowText: Bool
}

struct BatteryWidgetProvider: TimelineProvider {
    typealias Entry = BatteryWidgetEntry

    func placeholder(in context: Context) -> BatteryWidgetEntry {
        BatteryWidgetEntry(date: Date(), level: 0.78, showCircle: true, showText: true, circleScale: 1, textScale: 1, showPercentSign: true, plateOpacity: 1, homeShowCircle: true, homeShowText: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (BatteryWidgetEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryWidgetEntry>) -> Void) {
        // The app pushes a reload whenever the level changes, so the widget itself only needs
        // to ask again now and then - which keeps the phone from waking up too often.
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        let entry = makeEntry()
        SmartWakeDebugLog.log("WIDGET battery timeline level=\(entry.level.map { String(Int(($0 * 100).rounded())) } ?? "-")", force: true)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func makeEntry() -> BatteryWidgetEntry {
        let defaults = widgetDefaults()
        let appLevel = defaults.object(forKey: "appBatteryLevel") as? Double
        let appLevelAt = defaults.object(forKey: "appBatteryLevelAt") as? Double
        let appLevelIsFresh = appLevelAt.map { Date().timeIntervalSince1970 - $0 < 3600 } ?? false
        return BatteryWidgetEntry(
            date: Date(),
            level: (appLevelIsFresh ? appLevel : nil) ?? readBatteryLevel(),
            showCircle: defaults.object(forKey: "widgetBatteryShowCircle") as? Bool ?? true,
            showText: defaults.object(forKey: "widgetBatteryShowText") as? Bool ?? true,
            circleScale: defaults.object(forKey: "widgetBatteryCircleScale") as? Double ?? 1.0,
            textScale: defaults.object(forKey: "widgetBatteryTextScale") as? Double ?? 1.0,
            showPercentSign: defaults.object(forKey: "widgetBatteryShowPercentSign") as? Bool ?? true,
            plateOpacity: defaults.object(forKey: "widgetBatteryPlateOpacity") as? Double ?? 1.0,
            homeShowCircle: defaults.object(forKey: "widgetHomeShowCircle") as? Bool ?? true,
            homeShowText: defaults.object(forKey: "widgetHomeShowText") as? Bool ?? true
        )
    }
}

struct BatteryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BatteryWidgetEntry

    var body: some View {
        ZStack {
            if !isHomeScreen {
                AccessoryWidgetBackground()
                    .opacity(entry.plateOpacity)
            }
            ZStack {
                if showRing {
                    Circle()
                        .inset(by: ringWidth / 2)
                        .stroke(Color.white.opacity(isHomeScreen ? 0.18 : 0.25), lineWidth: ringWidth)
                    Circle()
                        .inset(by: ringWidth / 2)
                        .trim(from: 0, to: max(0.001, min(1.0, entry.level ?? 0)))
                        .stroke(ringColour, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if showNumber {
                    Text(percentText)
                        .font(.system(size: numberSize, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.4)
                        .foregroundStyle(isHomeScreen ? Color.primary : Color.white)
                }
            }
            .padding(isHomeScreen ? 16 : 2)
        }
    }

    private var isHomeScreen: Bool { family == .systemSmall }

    private var showRing: Bool { isHomeScreen ? entry.homeShowCircle : entry.showCircle }

    private var showNumber: Bool { isHomeScreen ? entry.homeShowText : entry.showText }

    private var ringWidth: CGFloat { CGFloat((isHomeScreen ? 14 : 5) * entry.circleScale) }

    private var numberSize: CGFloat { CGFloat((isHomeScreen ? 46 : 16) * entry.textScale) }

    private var ringColour: Color {
        let level = entry.level ?? 0
        if level <= 0.20 { return .red }
        if level <= 0.50 { return .orange }
        return .green
    }

    private var percentText: String {
        guard let level = entry.level else { return "--" }
        let number = "\(Int((level * 100).rounded()))"
        return entry.showPercentSign ? number + "%" : number
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
final class NextAlarmWidgetProvider: TimelineProvider {
    typealias Entry = NextAlarmWidgetEntry
    
    private var appGroupIdentifier: String {
        let configured = Bundle.main.object(
            forInfoDictionaryKey: "AlarmClockAppGroupIdentifier"
        ) as? String ?? "group.com.example.alarmclock"
        let resigned = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        return resigned.first { $0 == configured || $0.hasPrefix(configured + ".") } ?? configured
    }
    private let snapshotFileName = "nextAlarmSnapshot.json"
    
    // Track last successful snapshot to avoid logging unchanged refreshes
    private var lastSnapshotAlarmID: UUID? = nil
    private var lastSnapshotNextOccurrence: Date? = nil
    
    init() {}
    
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
        completion(loadEntry(at: Date()))
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<NextAlarmWidgetEntry>) -> Void) {
        let now = Date()

        var entries: [NextAlarmWidgetEntry] = []
        // One entry per minute for the next hour, each worked out as of that minute, so the
        // widget stays correct - and rolls on to the following alarm once one has passed -
        // without WidgetKit having to reload it.
        for minute in 0..<60 {
            if let when = Calendar.current.date(byAdding: .minute, value: minute, to: now) {
                entries.append(loadEntry(at: when))
            }
        }
        if entries.isEmpty {
            entries = [loadEntry(at: now)]
        }
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 60, to: now) ?? now
        SmartWakeDebugLog.log(
            "WIDGET next-alarm timeline family=\(context.family) entries=\(entries.count) hasAlarm=\(entries.first?.hasAlarm ?? false) next=\(entries.first?.nextTime ?? "-") appGroup=\(appGroupIdentifier)",
            force: true
        )
        completion(Timeline(entries: entries, policy: .after(nextUpdate)))
    }
    
    // Worked out from the alarm list itself, as of `date`, so the widget is correct even when
    // the app has not run for a while and a passed alarm rolls on to the next one.
    private func loadEntry(at date: Date) -> NextAlarmWidgetEntry {
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return loadEntryFromSnapshot()
        }

        let alarmsURL = appGroupURL.appendingPathComponent("alarms.json")
        guard let store = try? JSONAlarmPersistence(fileURL: alarmsURL).load() else {
            return loadEntryFromSnapshot()
        }

        let engine = AlarmEngine(snapshot: store)
        guard let occurrence = engine.earliestOccurrence(now: date),
              let alarm = engine.alarm(id: occurrence.alarmID), alarm.isEnabled else {
            return emptyEntry(at: date)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"

        let calendar = Calendar.current
        let dateIndicator: String
        if calendar.isDate(occurrence.effectiveDate, inSameDayAs: date) {
            dateIndicator = "Today"
        } else if calendar.isDate(occurrence.effectiveDate, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: date) ?? date) {
            dateIndicator = "Tomorrow"
        } else {
            dateIndicator = dateFormatter.string(from: occurrence.effectiveDate)
        }

        let defaults = widgetDefaults()
        return NextAlarmWidgetEntry(
            date: date,
            alarmLabel: alarm.label,
            nextTime: formatter.string(from: occurrence.effectiveDate),
            dateIndicator: dateIndicator,
            hasAlarm: true,
            alarmID: alarm.id,
            batteryLevel: readBatteryLevel(),
            nextDate: occurrence.effectiveDate,
            showBatteryInline: defaults.object(forKey: "widgetInlineShowBattery") as? Bool ?? false,
            showPercentSign: defaults.object(forKey: "widgetBatteryShowPercentSign") as? Bool ?? true,
            plateOpacity: defaults.object(forKey: "widgetBatteryPlateOpacity") as? Double ?? 1.0
        )
    }

    private func emptyEntry(at date: Date) -> NextAlarmWidgetEntry {
        NextAlarmWidgetEntry(
            date: date,
            alarmLabel: "No upcoming alarm",
            nextTime: "--:--",
            dateIndicator: "",
            hasAlarm: false,
            alarmID: nil
        )
    }

    private func loadEntryFromSnapshot() -> NextAlarmWidgetEntry {
        
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            SmartWakeDebugLog.log("WIDGET failed to get App Group container URL appGroup=\(appGroupIdentifier) containerAvailable=false")
            return NextAlarmWidgetEntry(
                date: Date(),
                alarmLabel: "No upcoming alarm",
                nextTime: "--:--",
                dateIndicator: "",
                hasAlarm: false,
                alarmID: nil
            )
        }
        
        let snapshotURL = appGroupURL.appendingPathComponent(snapshotFileName)
        
        let fileExists = FileManager.default.fileExists(atPath: snapshotURL.path)
        
        guard fileExists else {
            SmartWakeDebugLog.log("WIDGET snapshot file does not exist appGroup=\(appGroupIdentifier)")
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
            SmartWakeDebugLog.log("WIDGET failed to read snapshot file data appGroup=\(appGroupIdentifier)")
            return NextAlarmWidgetEntry(
                date: Date(),
                alarmLabel: "No upcoming alarm",
                nextTime: "--:--",
                dateIndicator: "",
                hasAlarm: false,
                alarmID: nil
            )
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard let snapshot = try? decoder.decode(NextAlarmSnapshot.self, from: data) else {
            SmartWakeDebugLog.log("WIDGET failed to decode snapshot JSON appGroup=\(appGroupIdentifier)")
            return NextAlarmWidgetEntry(
                date: Date(),
                alarmLabel: "No upcoming alarm",
                nextTime: "--:--",
                dateIndicator: "",
                hasAlarm: false,
                alarmID: nil
            )
        }
        
        // Check if snapshot changed (alarm ID or next occurrence time)
        let snapshotChanged = (lastSnapshotAlarmID != snapshot.alarmID) || (lastSnapshotNextOccurrence != snapshot.nextOccurrenceDate)
        
        if snapshotChanged {
            lastSnapshotAlarmID = snapshot.alarmID
            lastSnapshotNextOccurrence = snapshot.nextOccurrenceDate
            SmartWakeDebugLog.log("WIDGET snapshot changed appGroup=\(appGroupIdentifier) alarmID=\(snapshot.alarmID.uuidString) nextOccurrence=\(snapshot.nextOccurrenceDate)")
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
        
        let entry = NextAlarmWidgetEntry(
            date: Date(),
            alarmLabel: snapshot.label,
            nextTime: formatter.string(from: snapshot.nextOccurrenceDate),
            dateIndicator: dateIndicator,
            hasAlarm: true,
            alarmID: snapshot.alarmID,
            batteryLevel: readBatteryLevel(),
            nextDate: snapshot.nextOccurrenceDate,
            showBatteryInline: widgetDefaults().object(forKey: "widgetInlineShowBattery") as? Bool ?? false,
            showPercentSign: widgetDefaults().object(forKey: "widgetBatteryShowPercentSign") as? Bool ?? true,
            plateOpacity: widgetDefaults().object(forKey: "widgetBatteryPlateOpacity") as? Double ?? 1.0
        )
        
        return entry
    }
}

/// Timeline entry for the next alarm widget
struct NextAlarmWidgetEntry: TimelineEntry {
    var date: Date
    let alarmLabel: String
    let nextTime: String
    let dateIndicator: String
    let hasAlarm: Bool
    let alarmID: UUID?
    var batteryLevel: Double? = nil
    var nextDate: Date? = nil
    var showBatteryInline: Bool = false
    var showPercentSign: Bool = true
    var plateOpacity: Double = 1.0
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
    @Environment(\.isLuminanceReduced) private var luminanceReduced
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
                .opacity(entry.plateOpacity)
            if entry.hasAlarm {
                (Text(nextTimeShort).font(.system(size: 20, weight: .bold, design: .rounded))
                    + Text(nextTimeSuffix.isEmpty ? "" : " " + nextTimeSuffix)
                        .font(.system(size: 9, weight: .semibold, design: .rounded)))
                    .minimumScaleFactor(0.4)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
            } else {
                Text("No Alarm")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(.white)
            }
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
                    (Text(nextTimeShort).font(.system(size: 18, weight: .bold, design: .rounded))
                        + Text(nextTimeSuffix.isEmpty ? "" : " " + nextTimeSuffix)
                            .font(.system(size: 10, weight: .bold, design: .rounded)))
                        .foregroundStyle(.primary)
                }
                if let countdown = countdownText {
                    Text(countdown)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.secondary)
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
        if let nextDate = entry.nextDate, nextDate > entry.date {
            HStack(spacing: 4) {
                Image(systemName: "alarm.fill")
                if luminanceReduced {
                    Text(dimmedInlineText)
                } else {
                    Text(nextDate, style: .timer)
                }
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: entry.hasAlarm ? "alarm.fill" : "alarm.slash")
                Text(entry.hasAlarm ? entry.nextTime : "No alarm")
            }
        }
    }

    // The one-line widget renders a single string, so while the screen is dimmed the alarm
    // time and the battery are combined into one line.
    // The entry may have been planned up to an hour ago, so prefer the value the app wrote.
    private var freshBatteryLevel: Double? {
        let defaults = widgetDefaults()
        if let appLevel = defaults.object(forKey: "appBatteryLevel") as? Double,
           let appLevelAt = defaults.object(forKey: "appBatteryLevelAt") as? Double,
           Date().timeIntervalSince1970 - appLevelAt < 3600 {
            return appLevel
        }
        return entry.batteryLevel
    }

    private var dimmedInlineText: String {
        guard entry.showBatteryInline, let level = freshBatteryLevel else { return entry.nextTime }
        let number = "\(Int((level * 100).rounded()))"
        return entry.nextTime + " \u{00B7} " + number + "%"
    }

    // Minute granularity, because the timeline only steps once a minute. Clamped at zero,
    // so a passed alarm does not count upwards.
    private var countdownText: String? {
        guard entry.hasAlarm, let nextDate = entry.nextDate else { return nil }
        let remaining = max(0, Int(nextDate.timeIntervalSince(entry.date)))
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(minutes)m"
    }

    private var nextTimeShort: String {
        entry.nextTime.split(separator: " ").first.map(String.init) ?? entry.nextTime
    }

    private var nextTimeSuffix: String {
        let parts = entry.nextTime.split(separator: " ")
        return parts.count > 1 ? String(parts[1]) : ""
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
        SmartWakeDebugLog.log("CONTROL ENTER: skipNext intent ran")
        SmartWakeDebugLog.log("CONTROL: skip next tapped")
        let tok = String(UUID().uuidString.prefix(8))
        SmartWakeDebugLog.log("CC INVOKE action=skipNext tok=\(tok) bundle=\(Bundle.main.bundleIdentifier) pid=\(ProcessInfo.processInfo.processIdentifier)")
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
            
            // Schedule second reload in 2 seconds for self-healing
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let widgetKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockWidgetKind") as? String {
                    WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
                    SmartWakeDebugLog.log("INTENT STEP: reload-scheduled in=2s action=skipNext kind=\(widgetKind)")
                }
                if let controlKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockControlKind") as? String {
                    WidgetCenter.shared.reloadTimelines(ofKind: controlKind)
                    SmartWakeDebugLog.log("INTENT STEP: reload-scheduled in=2s action=skipNext kind=\(controlKind)")
                }
            }
        } catch {
            SmartWakeDebugLog.log("INTENT SNAPSHOT ERROR: \(error.localizedDescription) action=skipNext")
        }
        
        // Post local notification IMMEDIATELY from the extension at press time
        // (if app is backgrounded, this provides instant feedback)
        await postCCFeedbackFromExtension("Next alarm skipped", token: tok)
        SmartWakeDebugLog.log("NOTIFY SOURCE: postedBy=extension id=skipNext")
        
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
        let tok = String(UUID().uuidString.prefix(8))
        SmartWakeDebugLog.log("CC INVOKE action=-10 tok=\(tok) bundle=\(Bundle.main.bundleIdentifier) pid=\(ProcessInfo.processInfo.processIdentifier)")
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
            
            // Schedule second reload in 2 seconds for self-healing
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let widgetKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockWidgetKind") as? String {
                    WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
                    SmartWakeDebugLog.log("INTENT STEP: reload-scheduled in=2s action=adjust-10 kind=\(widgetKind)")
                }
                if let controlKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockControlKind") as? String {
                    WidgetCenter.shared.reloadTimelines(ofKind: controlKind)
                    SmartWakeDebugLog.log("INTENT STEP: reload-scheduled in=2s action=adjust-10 kind=\(controlKind)")
                }
            }
        } catch {
            SmartWakeDebugLog.log("INTENT SNAPSHOT ERROR: \(error.localizedDescription) action=adjust-10")
        }
        
        // Post local notification IMMEDIATELY from the extension at press time
        await postCCFeedbackFromExtension("Alarm moved -10 min", token: tok)
        SmartWakeDebugLog.log("NOTIFY SOURCE: postedBy=extension id=adjust-10")
        
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
        let tok = String(UUID().uuidString.prefix(8))
        SmartWakeDebugLog.log("CC INVOKE action=+10 tok=\(tok) bundle=\(Bundle.main.bundleIdentifier) pid=\(ProcessInfo.processInfo.processIdentifier)")
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
            
            // Schedule second reload in 2 seconds for self-healing
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let widgetKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockWidgetKind") as? String {
                    WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
                    SmartWakeDebugLog.log("INTENT STEP: reload-scheduled in=2s action=adjust+10 kind=\(widgetKind)")
                }
                if let controlKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockControlKind") as? String {
                    WidgetCenter.shared.reloadTimelines(ofKind: controlKind)
                    SmartWakeDebugLog.log("INTENT STEP: reload-scheduled in=2s action=adjust+10 kind=\(controlKind)")
                }
            }
        } catch {
            SmartWakeDebugLog.log("INTENT SNAPSHOT ERROR: \(error.localizedDescription) action=adjust+10")
        }
        
        // Post local notification IMMEDIATELY from the extension at press time
        await postCCFeedbackFromExtension("Alarm moved +10 min", token: tok)
        SmartWakeDebugLog.log("NOTIFY SOURCE: postedBy=extension id=adjust+10")
        
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


/// Darwin notification bridge for widget-to-app communication
private func postDarwinNotification(_ name: String) {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let name = CFNotificationName(name as CFString)
    CFNotificationCenterPostNotification(center, name, nil, nil, true)
}

/// Post local notification from the extension for immediate CC feedback
/// Uses a FIXED identifier so each press replaces the previous notification.
/// Auto-removes after ~6 seconds and sweeps stale notifications.
@MainActor
private func postCCFeedbackFromExtension(_ text: String, token: String) async {
    let content = UNMutableNotificationContent()
    content.title = "myNextAlarm"
    content.body = text
    content.sound = nil
    content.threadIdentifier = "cc-feedback-extension"
    
    let fixedIdentifier = "cc-feedback-extension"
    SmartWakeDebugLog.log("CC POST begin tok=\(token) id=\(fixedIdentifier) t=\(text)")
    let request = UNNotificationRequest(
        identifier: fixedIdentifier,
        content: content,
        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
    )
    
    let center = UNUserNotificationCenter.current()
    do {
        // Remove any existing notification with the same fixed identifier
        center.removeDeliveredNotifications(withIdentifiers: [fixedIdentifier])
        
        try await center.add(request)
        SmartWakeDebugLog.log("CC POST added tok=\(token)")
        let p = await center.pendingNotificationRequests()
        SmartWakeDebugLog.log("NOTIF DUMP pending n=\(p.count) ids=[\(p.map { $0.identifier }.joined(separator: ","))]")
        let d = await center.deliveredNotifications()
        SmartWakeDebugLog.log("NOTIF DUMP delivered n=\(d.count) ids=[\(d.map { $0.request.identifier }.joined(separator: ","))] dates=[\(d.map { String(Int($0.date.timeIntervalSince1970)) }.joined(separator: ","))]")
        SmartWakeDebugLog.log("CC FEEDBACK EXTENSION notification posted: \(text)")
        SmartWakeDebugLog.log("NOTIFY SOURCE: postedBy=extension id=\(fixedIdentifier)")
        
        // Auto-remove after ~6 seconds AND sweep any stale "cc-feedback-extension-*" notifications
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        center.removeDeliveredNotifications(withIdentifiers: [fixedIdentifier])
        
        // Sweep any stale "cc-feedback-extension-*" notifications
        let allDelivered = await center.deliveredNotifications()
        let staleIds = allDelivered
            .filter { $0.request.identifier.hasPrefix("cc-feedback-extension-") }
            .map { $0.request.identifier }
        if !staleIds.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: staleIds)
            SmartWakeDebugLog.log("CC FEEDBACK EXTENSION notification swept stale: \(staleIds.count) items")
        }
        SmartWakeDebugLog.log("CC FEEDBACK EXTENSION notification auto-removed")
    } catch {
        // Extension may not have notification permission - log and don't fail silently
        SmartWakeDebugLog.log("CC FEEDBACK EXTENSION notification FAILED (may lack permission): \(error.localizedDescription)")
    }
}
