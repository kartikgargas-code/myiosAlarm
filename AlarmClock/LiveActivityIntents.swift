import AppIntents
import AlarmClockShared

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
    
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: alarmID) else {
            return .result(dialog: "Invalid alarm ID")
        }
        
        let service = SharedAlarmService()
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
    
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: alarmID) else {
            return .result(dialog: "Invalid alarm ID")
        }
        
        let service = SharedAlarmService()
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
    
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: alarmID) else {
            return .result(dialog: "Invalid alarm ID")
        }
        
        let service = SharedAlarmService()
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
    
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: alarmID) else {
            return .result(dialog: "Invalid alarm ID")
        }
        
        let service = SharedAlarmService()
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