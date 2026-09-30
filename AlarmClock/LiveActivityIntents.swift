import AppIntents
import AlarmClockShared
import os.log

private let liveActivityLog = OSLog(subsystem: "com.example.alarmclock", category: "LiveActivityIntent")

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
        os_log(.info, liveActivityLog, "AdjustNextAlarmLiveIntent.perform() started - alarmID: %{public}s, minutes: %{public}d", alarmID, minutes)
        guard let uuid = UUID(uuidString: alarmID) else {
            os_log(.error, liveActivityLog, "AdjustNextAlarmLiveIntent.perform() - invalid alarm ID: %{public}s", alarmID)
            return .result(dialog: "Invalid alarm ID")
        }
        
        let service = SharedAlarmService()
        do {
            let success = try await service.adjustNextAlarm(alarmID: uuid, minutes: minutes)
            os_log(.info, liveActivityLog, "AdjustNextAlarmLiveIntent.perform() completed - success: %{public}d", success)
            if success {
                return .result(dialog: "Adjusted alarm by \(minutes >= 0 ? "+" : "")\(minutes) minutes")
            } else {
                return .result(dialog: "Could not adjust alarm - alarm may have changed")
            }
        } catch {
            os_log(.error, liveActivityLog, "AdjustNextAlarmLiveIntent.perform() error: %{public}s", error.localizedDescription)
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
        os_log(.info, liveActivityLog, "ResetNextAlarmLiveIntent.perform() started - alarmID: %{public}s", alarmID)
        guard let uuid = UUID(uuidString: alarmID) else {
            os_log(.error, liveActivityLog, "ResetNextAlarmLiveIntent.perform() - invalid alarm ID: %{public}s", alarmID)
            return .result(dialog: "Invalid alarm ID")
        }
        
        let service = SharedAlarmService()
        do {
            let success = try await service.resetNextAlarm(alarmID: uuid)
            os_log(.info, liveActivityLog, "ResetNextAlarmLiveIntent.perform() completed - success: %{public}d", success)
            if success {
                return .result(dialog: "Reset alarm to base schedule")
            } else {
                return .result(dialog: "Could not reset alarm - alarm may have changed")
            }
        } catch {
            os_log(.error, liveActivityLog, "ResetNextAlarmLiveIntent.perform() error: %{public}s", error.localizedDescription)
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
        os_log(.info, liveActivityLog, "SkipNextAlarmLiveIntent.perform() started - alarmID: %{public}s", alarmID)
        guard let uuid = UUID(uuidString: alarmID) else {
            os_log(.error, liveActivityLog, "SkipNextAlarmLiveIntent.perform() - invalid alarm ID: %{public}s", alarmID)
            return .result(dialog: "Invalid alarm ID")
        }
        
        let service = SharedAlarmService()
        do {
            let success = try await service.skipNextAlarm(alarmID: uuid)
            os_log(.info, liveActivityLog, "SkipNextAlarmLiveIntent.perform() completed - success: %{public}d", success)
            if success {
                return .result(dialog: "Skipped next alarm")
            } else {
                return .result(dialog: "Could not skip alarm - alarm may have changed")
            }
        } catch {
            os_log(.error, liveActivityLog, "SkipNextAlarmLiveIntent.perform() error: %{public}s", error.localizedDescription)
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
        os_log(.info, liveActivityLog, "UndoSkipAlarmLiveIntent.perform() started - alarmID: %{public}s", alarmID)
        guard let uuid = UUID(uuidString: alarmID) else {
            os_log(.error, liveActivityLog, "UndoSkipAlarmLiveIntent.perform() - invalid alarm ID: %{public}s", alarmID)
            return .result(dialog: "Invalid alarm ID")
        }
        
        let service = SharedAlarmService()
        do {
            let success = try await service.undoSkipAlarm(alarmID: uuid)
            os_log(.info, liveActivityLog, "UndoSkipAlarmLiveIntent.perform() completed - success: %{public}d", success)
            if success {
                return .result(dialog: "Restored skipped alarm")
            } else {
                return .result(dialog: "Could not restore alarm - alarm may have changed")
            }
        } catch {
            os_log(.error, liveActivityLog, "UndoSkipAlarmLiveIntent.perform() error: %{public}s", error.localizedDescription)
            return .result(dialog: "Failed to restore alarm: \(error.localizedDescription)")
        }
    }
}