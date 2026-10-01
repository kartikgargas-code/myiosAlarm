import AppIntents
import AlarmClockShared
import os.log

/// Protocol for Live Activity alarm operations - implemented by each target
@MainActor
public protocol LiveActivityAlarmService {
    func adjustNextAlarm(alarmID: UUID, minutes: Int) async throws -> Bool
    func resetNextAlarm(alarmID: UUID) async throws -> Bool
    func skipNextAlarm(alarmID: UUID) async throws -> Bool
    func undoSkipAlarm(alarmID: UUID) async throws -> Bool
}

/// Global service provider - each target sets its implementation
public struct LiveActivityAlarmServiceProvider {
    public static var shared: (any LiveActivityAlarmService)?
}

/// Private logger for Live Activity intents
private let liveActivityLog = OSLog(subsystem: "com.example.alarmclock", category: "LiveActivityIntent")

/// Live Activity Intent to adjust the next alarm by minutes
public struct AdjustNextAlarmLiveIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Adjust Next Alarm"
    public static let description = IntentDescription("Adjust the next alarm time by the configured step")
    
    @Parameter(title: "Alarm ID")
    public var alarmID: String
    
    @Parameter(title: "Minutes")
    public var minutes: Int
    
    public init() {
        self.alarmID = ""
        self.minutes = 0
    }
    
    public init(alarmID: UUID, minutes: Int) {
        self.alarmID = alarmID.uuidString
        self.minutes = minutes
    }
    
    public func perform() async throws -> some IntentResult {
        os_log(.info, log: liveActivityLog, "AdjustNextAlarmLiveIntent.perform() started - alarmID: %{public}s, minutes: %{public}d", alarmID, minutes)
        guard let uuid = UUID(uuidString: alarmID) else {
            os_log(.error, log: liveActivityLog, "AdjustNextAlarmLiveIntent.perform() - invalid alarm ID: %{public}s", alarmID)
            return .result(dialog: "Invalid alarm ID")
        }
        
        guard let service = LiveActivityAlarmServiceProvider.shared else {
            os_log(.error, log: liveActivityLog, "AdjustNextAlarmLiveIntent.perform() - no service provider registered")
            return .result(dialog: "Service not available")
        }
        
        do {
            let success = try await service.adjustNextAlarm(alarmID: uuid, minutes: minutes)
            os_log(.info, log: liveActivityLog, "AdjustNextAlarmLiveIntent.perform() completed - success: %{public}d", success)
            if success {
                return .result(dialog: "Adjusted alarm by \(minutes >= 0 ? "+" : "")\(minutes) minutes")
            } else {
                return .result(dialog: "Could not adjust alarm - alarm may have changed")
            }
        } catch {
            os_log(.error, log: liveActivityLog, "AdjustNextAlarmLiveIntent.perform() error: %{public}s", error.localizedDescription)
            return .result(dialog: "Failed to adjust alarm: \(error.localizedDescription)")
        }
    }
}

/// Live Activity Intent to reset the next alarm to base schedule
public struct ResetNextAlarmLiveIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Reset Next Alarm"
    public static let description = IntentDescription("Reset the next alarm to its base schedule")
    
    @Parameter(title: "Alarm ID")
    public var alarmID: String
    
    public init() {
        self.alarmID = ""
    }
    
    public init(alarmID: UUID) {
        self.alarmID = alarmID.uuidString
    }
    
    public func perform() async throws -> some IntentResult {
        os_log(.info, log: liveActivityLog, "ResetNextAlarmLiveIntent.perform() started - alarmID: %{public}s", alarmID)
        guard let uuid = UUID(uuidString: alarmID) else {
            os_log(.error, log: liveActivityLog, "ResetNextAlarmLiveIntent.perform() - invalid alarm ID: %{public}s", alarmID)
            return .result(dialog: "Invalid alarm ID")
        }
        
        guard let service = LiveActivityAlarmServiceProvider.shared else {
            os_log(.error, log: liveActivityLog, "ResetNextAlarmLiveIntent.perform() - no service provider registered")
            return .result(dialog: "Service not available")
        }
        
        do {
            let success = try await service.resetNextAlarm(alarmID: uuid)
            os_log(.info, log: liveActivityLog, "ResetNextAlarmLiveIntent.perform() completed - success: %{public}d", success)
            if success {
                return .result(dialog: "Reset alarm to base schedule")
            } else {
                return .result(dialog: "Could not reset alarm - alarm may have changed")
            }
        } catch {
            os_log(.error, log: liveActivityLog, "ResetNextAlarmLiveIntent.perform() error: %{public}s", error.localizedDescription)
            return .result(dialog: "Failed to reset alarm: \(error.localizedDescription)")
        }
    }
}

/// Live Activity Intent to skip the next occurrence
public struct SkipNextAlarmLiveIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Skip Next Alarm"
    public static let description = IntentDescription("Skip the next occurrence of the alarm")
    
    @Parameter(title: "Alarm ID")
    public var alarmID: String
    
    public init() {
        self.alarmID = ""
    }
    
    public init(alarmID: UUID) {
        self.alarmID = alarmID.uuidString
    }
    
    public func perform() async throws -> some IntentResult {
        os_log(.info, log: liveActivityLog, "SkipNextAlarmLiveIntent.perform() started - alarmID: %{public}s", alarmID)
        guard let uuid = UUID(uuidString: alarmID) else {
            os_log(.error, log: liveActivityLog, "SkipNextAlarmLiveIntent.perform() - invalid alarm ID: %{public}s", alarmID)
            return .result(dialog: "Invalid alarm ID")
        }
        
        guard let service = LiveActivityAlarmServiceProvider.shared else {
            os_log(.error, log: liveActivityLog, "SkipNextAlarmLiveIntent.perform() - no service provider registered")
            return .result(dialog: "Service not available")
        }
        
        do {
            let success = try await service.skipNextAlarm(alarmID: uuid)
            os_log(.info, log: liveActivityLog, "SkipNextAlarmLiveIntent.perform() completed - success: %{public}d", success)
            if success {
                return .result(dialog: "Skipped next alarm")
            } else {
                return .result(dialog: "Could not skip alarm - alarm may have changed")
            }
        } catch {
            os_log(.error, log: liveActivityLog, "SkipNextAlarmLiveIntent.perform() error: %{public}s", error.localizedDescription)
            return .result(dialog: "Failed to skip alarm: \(error.localizedDescription)")
        }
    }
}

/// Live Activity Intent to undo skip for the next occurrence
public struct UndoSkipAlarmLiveIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Undo Skip Alarm"
    public static let description = IntentDescription("Restore a skipped alarm occurrence")
    
    @Parameter(title: "Alarm ID")
    public var alarmID: String
    
    public init() {
        self.alarmID = ""
    }
    
    public init(alarmID: UUID) {
        self.alarmID = alarmID.uuidString
    }
    
    public func perform() async throws -> some IntentResult {
        os_log(.info, log: liveActivityLog, "UndoSkipAlarmLiveIntent.perform() started - alarmID: %{public}s", alarmID)
        guard let uuid = UUID(uuidString: alarmID) else {
            os_log(.error, log: liveActivityLog, "UndoSkipAlarmLiveIntent.perform() - invalid alarm ID: %{public}s", alarmID)
            return .result(dialog: "Invalid alarm ID")
        }
        
        guard let service = LiveActivityAlarmServiceProvider.shared else {
            os_log(.error, log: liveActivityLog, "UndoSkipAlarmLiveIntent.perform() - no service provider registered")
            return .result(dialog: "Service not available")
        }
        
        do {
            let success = try await service.undoSkipAlarm(alarmID: uuid)
            os_log(.info, log: liveActivityLog, "UndoSkipAlarmLiveIntent.perform() completed - success: %{public}d", success)
            if success {
                return .result(dialog: "Restored skipped alarm")
            } else {
                return .result(dialog: "Could not restore alarm - alarm may have changed")
            }
        } catch {
            os_log(.error, log: liveActivityLog, "UndoSkipAlarmLiveIntent.perform() error: %{public}s", error.localizedDescription)
            return .result(dialog: "Failed to restore alarm: \(error.localizedDescription)")
        }
    }
}