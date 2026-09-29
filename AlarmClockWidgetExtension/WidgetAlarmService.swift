import Foundation
import AlarmClockShared
import WidgetKit

/// Lightweight alarm service for widget extension App Intents
/// Does NOT depend on SoundLibrary, AudioProcessingService, or AlarmKit
/// Only handles persistence, AlarmEngine operations, and widget snapshots
public struct WidgetAlarmService {
    private let appGroupIdentifier: String
    private let persistence: JSONAlarmPersistence
    private let now: () -> Date
    
    public init(
        appGroupIdentifier: String = "group.com.example.alarmclock",
        now: @escaping () -> Date = Date.init
    ) {
        let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
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
    
    /// Apply adjustment to the next alarm using the provided minutes
    public func adjustNextAlarm(alarmID: UUID, minutes: Int) async throws -> Bool {
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
    public func setNextAlarmTime(alarmID: UUID, date: Date) async throws -> Bool {
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
    public func resetNextAlarm(alarmID: UUID) async throws -> Bool {
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
    public func skipNextAlarm(alarmID: UUID) async throws -> Bool {
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
    public func undoSkipAlarm(alarmID: UUID) async throws -> Bool {
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
            if let controlKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockControlKind") as? String {
                WidgetCenter.shared.reloadTimelines(ofKind: controlKind)
            }
        } catch {
            print("Failed to write widget snapshot: \(error)")
        }
    }
}