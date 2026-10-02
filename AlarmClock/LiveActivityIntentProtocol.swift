import AppIntents
import AlarmClockShared
import os.log
import Foundation

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

/// File-based debug logger for in-app debugging (writes to App Group container)
private func appendLiveActivityDebugLog(_ message: String) {
    let fileManager = FileManager.default
    guard let appGroupURL = AppGroupResolver.resolve().flatMap({
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: $0)
    }) else { return }
    
    let logURL = appGroupURL.appendingPathComponent("live_activity_debug.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logLine = "[\(timestamp)] \(message)\n"
    
    do {
        if fileManager.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            handle.seekToEndOfFile()
            if let data = logLine.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            try logLine.write(to: logURL, atomically: true, encoding: .utf8)
        }
    } catch {
        // Silently fail - this is just for debugging
    }
}

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
        appendLiveActivityDebugLog("AdjustNextAlarmLiveIntent.perform() START - alarmID: \(alarmID), minutes: \(minutes)")
        
        guard let uuid = UUID(uuidString: alarmID) else {
            os_log(.error, log: liveActivityLog, "AdjustNextAlarmLiveIntent.perform() - invalid alarm ID: %{public}s", alarmID)
            appendLiveActivityDebugLog("AdjustNextAlarmLiveIntent.perform() END (invalid alarm ID) - alarmID: \(alarmID)")
            return .result(dialog: "Invalid alarm ID")
        }
        
        guard let service = LiveActivityAlarmServiceProvider.shared else {
            os_log(.error, log: liveActivityLog, "AdjustNextAlarmLiveIntent.perform() - no service provider registered")
            appendLiveActivityDebugLog("AdjustNextAlarmLiveIntent.perform() END (no service provider) - alarmID: \(alarmID)")
            return .result(dialog: "Service not available")
        }
        
        do {
            let success = try await service.adjustNextAlarm(alarmID: uuid, minutes: minutes)
            os_log(.info, log: liveActivityLog, "AdjustNextAlarmLiveIntent.perform() completed - success: %{public}d", success)
            appendLiveActivityDebugLog("AdjustNextAlarmLiveIntent.perform() END (success: \(success)) - alarmID: \(alarmID), minutes: \(minutes)")
            if success {
                return .result(dialog: "Adjusted alarm by \(minutes >= 0 ? "+" : "")\(minutes) minutes")
            } else {
                return .result(dialog: "Could not adjust alarm - alarm may have changed")
            }
        } catch {
            os_log(.error, log: liveActivityLog, "AdjustNextAlarmLiveIntent.perform() error: %{public}s", error.localizedDescription)
            appendLiveActivityDebugLog("AdjustNextAlarmLiveIntent.perform() END (error: \(error.localizedDescription)) - alarmID: \(alarmID), minutes: \(minutes)")
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
        appendLiveActivityDebugLog("ResetNextAlarmLiveIntent.perform() START - alarmID: \(alarmID)")
        guard let uuid = UUID(uuidString: alarmID) else {
            os_log(.error, log: liveActivityLog, "ResetNextAlarmLiveIntent.perform() - invalid alarm ID: %{public}s", alarmID)
            appendLiveActivityDebugLog("ResetNextAlarmLiveIntent.perform() END (invalid alarm ID) - alarmID: \(alarmID)")
            return .result(dialog: "Invalid alarm ID")
        }
        
        guard let service = LiveActivityAlarmServiceProvider.shared else {
            os_log(.error, log: liveActivityLog, "ResetNextAlarmLiveIntent.perform() - no service provider registered")
            appendLiveActivityDebugLog("ResetNextAlarmLiveIntent.perform() END (no service provider) - alarmID: \(alarmID)")
            return .result(dialog: "Service not available")
        }
        
        do {
            let success = try await service.resetNextAlarm(alarmID: uuid)
            os_log(.info, log: liveActivityLog, "ResetNextAlarmLiveIntent.perform() completed - success: %{public}d", success)
            appendLiveActivityDebugLog("ResetNextAlarmLiveIntent.perform() END (success: \(success)) - alarmID: \(alarmID)")
            if success {
                return .result(dialog: "Reset alarm to base schedule")
            } else {
                return .result(dialog: "Could not reset alarm - alarm may have changed")
            }
        } catch {
            os_log(.error, log: liveActivityLog, "ResetNextAlarmLiveIntent.perform() error: %{public}s", error.localizedDescription)
            appendLiveActivityDebugLog("ResetNextAlarmLiveIntent.perform() END (error: \(error.localizedDescription)) - alarmID: \(alarmID)")
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
        appendLiveActivityDebugLog("SkipNextAlarmLiveIntent.perform() START - alarmID: \(alarmID)")
        guard let uuid = UUID(uuidString: alarmID) else {
            os_log(.error, log: liveActivityLog, "SkipNextAlarmLiveIntent.perform() - invalid alarm ID: %{public}s", alarmID)
            appendLiveActivityDebugLog("SkipNextAlarmLiveIntent.perform() END (invalid alarm ID) - alarmID: \(alarmID)")
            return .result(dialog: "Invalid alarm ID")
        }
        
        guard let service = LiveActivityAlarmServiceProvider.shared else {
            os_log(.error, log: liveActivityLog, "SkipNextAlarmLiveIntent.perform() - no service provider registered")
            appendLiveActivityDebugLog("SkipNextAlarmLiveIntent.perform() END (no service provider) - alarmID: \(alarmID)")
            return .result(dialog: "Service not available")
        }
        
        do {
            let success = try await service.skipNextAlarm(alarmID: uuid)
            os_log(.info, log: liveActivityLog, "SkipNextAlarmLiveIntent.perform() completed - success: %{public}d", success)
            appendLiveActivityDebugLog("SkipNextAlarmLiveIntent.perform() END (success: \(success)) - alarmID: \(alarmID)")
            if success {
                return .result(dialog: "Skipped next alarm")
            } else {
                return .result(dialog: "Could not skip alarm - alarm may have changed")
            }
        } catch {
            os_log(.error, log: liveActivityLog, "SkipNextAlarmLiveIntent.perform() error: %{public}s", error.localizedDescription)
            appendLiveActivityDebugLog("SkipNextAlarmLiveIntent.perform() END (error: \(error.localizedDescription)) - alarmID: \(alarmID)")
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
        appendLiveActivityDebugLog("UndoSkipAlarmLiveIntent.perform() START - alarmID: \(alarmID)")
        guard let uuid = UUID(uuidString: alarmID) else {
            os_log(.error, log: liveActivityLog, "UndoSkipAlarmLiveIntent.perform() - invalid alarm ID: %{public}s", alarmID)
            appendLiveActivityDebugLog("UndoSkipAlarmLiveIntent.perform() END (invalid alarm ID) - alarmID: \(alarmID)")
            return .result(dialog: "Invalid alarm ID")
        }
        
        guard let service = LiveActivityAlarmServiceProvider.shared else {
            os_log(.error, log: liveActivityLog, "UndoSkipAlarmLiveIntent.perform() - no service provider registered")
            appendLiveActivityDebugLog("UndoSkipAlarmLiveIntent.perform() END (no service provider) - alarmID: \(alarmID)")
            return .result(dialog: "Service not available")
        }
        
        do {
            let success = try await service.undoSkipAlarm(alarmID: uuid)
            os_log(.info, log: liveActivityLog, "UndoSkipAlarmLiveIntent.perform() completed - success: %{public}d", success)
            appendLiveActivityDebugLog("UndoSkipAlarmLiveIntent.perform() END (success: \(success)) - alarmID: \(alarmID)")
            if success {
                return .result(dialog: "Restored skipped alarm")
            } else {
                return .result(dialog: "Could not restore alarm - alarm may have changed")
            }
        } catch {
            os_log(.error, log: liveActivityLog, "UndoSkipAlarmLiveIntent.perform() error: %{public}s", error.localizedDescription)
            appendLiveActivityDebugLog("UndoSkipAlarmLiveIntent.perform() END (error: \(error.localizedDescription)) - alarmID: \(alarmID)")
            return .result(dialog: "Failed to restore alarm: \(error.localizedDescription)")
        }
    }
}