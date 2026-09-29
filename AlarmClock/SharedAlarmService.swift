import Foundation
import AlarmClockShared
import WidgetKit

/// Shared service for alarm operations accessible from both app and widget extension
/// Handles persistence, AlarmKit reconciliation, and widget updates
@MainActor
public struct SharedAlarmService {
    private let appGroupIdentifier: String
    private let persistence: JSONAlarmPersistence
    private let now: () -> Date
    
    public init(
        appGroupIdentifier: String = "group.com.example.alarmclock",
        now: @escaping () -> Date = Date.init
    ) {
        // Use App Group for shared persistence
        let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        let fileURL = appGroupURL?.appendingPathComponent("alarms.json")
        self.persistence = JSONAlarmPersistence(fileURL: fileURL)
        self.appGroupIdentifier = appGroupIdentifier
        self.now = now
    }
    
    /// Load the current alarm snapshot
    public func loadSnapshot() throws -> AlarmStoreSnapshot {
        return try persistence.load()
    }
    
    /// Save the alarm snapshot
    public func saveSnapshot(_ snapshot: AlarmStoreSnapshot) throws {
        try persistence.save(snapshot)
    }
    
    /// Apply +10 minutes adjustment to the next alarm
    public func adjustNextAlarm(alarmID: UUID, minutes: Int) throws -> Bool {
        var snapshot = try loadSnapshot()
        var engine = AlarmEngine(snapshot: snapshot)
        
        // Verify alarm exists and is enabled
        guard let alarm = engine.alarm(id: alarmID), alarm.isEnabled else {
            return false
        }
        
        // Verify this is still the next alarm
        let currentNext = engine.earliestOccurrence(now: now())
        guard currentNext?.alarmID == alarmID else {
            return false // Stale - next alarm changed
        }
        
        try engine.adjustNext(id: alarmID, byMinutes: minutes, now: now())
        try saveSnapshot(engine.snapshot)
        
        // Write updated widget snapshot
        writeNextAlarmSnapshot(engine: engine)
        
        return true
    }
    
    /// Set custom next time for alarm
    public func setNextAlarmTime(alarmID: UUID, date: Date) throws -> Bool {
        var snapshot = try loadSnapshot()
        var engine = AlarmEngine(snapshot: snapshot)
        
        guard let alarm = engine.alarm(id: alarmID), alarm.isEnabled else {
            return false
        }
        
        let currentNext = engine.earliestOccurrence(now: now())
        guard currentNext?.alarmID == alarmID else {
            return false
        }
        
        try engine.setNextTime(id: alarmID, date: date, now: now())
        try saveSnapshot(engine.snapshot)
        writeNextAlarmSnapshot(engine: engine)
        
        return true
    }
    
    /// Reset next alarm to base schedule
    public func resetNextAlarm(alarmID: UUID) throws -> Bool {
        var snapshot = try loadSnapshot()
        var engine = AlarmEngine(snapshot: snapshot)
        
        guard let alarm = engine.alarm(id: alarmID), alarm.isEnabled else {
            return false
        }
        
        let currentNext = engine.earliestOccurrence(now: now())
        guard currentNext?.alarmID == alarmID else {
            return false
        }
        
        try engine.resetNext(id: alarmID, now: now())
        try saveSnapshot(engine.snapshot)
        writeNextAlarmSnapshot(engine: engine)
        
        return true
    }
    
    /// Skip next occurrence
    public func skipNextAlarm(alarmID: UUID) throws -> Bool {
        var snapshot = try loadSnapshot()
        var engine = AlarmEngine(snapshot: snapshot)
        
        guard let alarm = engine.alarm(id: alarmID), alarm.isEnabled else {
            return false
        }
        
        let currentNext = engine.earliestOccurrence(now: now())
        guard currentNext?.alarmID == alarmID else {
            return false
        }
        
        try engine.skipNext(id: alarmID, now: now())
        try saveSnapshot(engine.snapshot)
        writeNextAlarmSnapshot(engine: engine)
        
        return true
    }
    
    /// Undo skip for next occurrence
    public func undoSkipAlarm(alarmID: UUID) throws -> Bool {
        var snapshot = try loadSnapshot()
        var engine = AlarmEngine(snapshot: snapshot)
        
        guard let alarm = engine.alarm(id: alarmID), alarm.isEnabled else {
            return false
        }
        
        let currentNext = engine.earliestOccurrence(now: now())
        guard currentNext?.alarmID == alarmID else {
            return false
        }
        
        try engine.undoSkip(id: alarmID, now: now())
        try saveSnapshot(engine.snapshot)
        writeNextAlarmSnapshot(engine: engine)
        
        return true
    }
    
    /// Write next alarm snapshot to App Group for widget
    private func writeNextAlarmSnapshot(engine: AlarmEngine) {
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return }
        
        let snapshotURL = appGroupURL.appendingPathComponent("nextAlarmSnapshot.json")
        let currentDate = now()
        let earliest = engine.earliestOccurrence(now: currentDate)
        
        var widgetSnapshot: NextAlarmSnapshot?
        if let earliest = earliest, let alarm = engine.alarm(id: earliest.alarmID) {
            widgetSnapshot = NextAlarmSnapshot(alarm: alarm, occurrence: earliest)
        }
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        do {
            let data = try encoder.encode(widgetSnapshot)
            try data.write(to: snapshotURL, options: .atomic)
            
            // Request widget reload
            if let widgetKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockWidgetKind") as? String {
                WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
            }
        } catch {
            print("Failed to write widget snapshot: \(error)")
        }
    }
}

/// Result of an alarm operation
public struct AlarmOperationResult: Codable, Equatable {
    public let success: Bool
    public let error: String?
    public let alarmID: UUID?
    public let newNextOccurrence: Date?
    
    public static func success(alarmID: UUID, newNextOccurrence: Date?) -> AlarmOperationResult {
        AlarmOperationResult(success: true, error: nil, alarmID: alarmID, newNextOccurrence: newNextOccurrence)
    }
    
    public static func failure(error: String, alarmID: UUID?) -> AlarmOperationResult {
        AlarmOperationResult(success: false, error: error, alarmID: alarmID, newNextOccurrence: nil)
    }
}