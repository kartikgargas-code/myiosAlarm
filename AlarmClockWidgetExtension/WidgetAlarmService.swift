import Foundation
import AlarmClockShared
import WidgetKit

/// Lightweight alarm service for widget extension App Intents
/// Does NOT depend on SoundLibrary, AudioProcessingService, or AlarmKit
/// Only handles persistence, AlarmEngine operations, and widget snapshots
public struct WidgetAlarmService: LiveActivityAlarmService {
    private let appGroupIdentifier: String
    private let persistence: JSONAlarmPersistence
    private let now: () -> Date
    
    public init(
        now: @escaping () -> Date = Date.init
    ) {
        // Resolve App Group at runtime (AltStore resigns with team ID suffix)
        let configured = (Bundle.main.object(forInfoDictionaryKey: "AlarmClockAppGroupIdentifier") as? String)
            ?? "group.com.example.alarmclock"
        let resignedGroups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        let appGroupIdentifier = resignedGroups.first { $0 == configured || $0.hasPrefix(configured + ".") } ?? configured
        
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

    /// Queue a pending action for the app to apply. The widget never rewrites
    /// alarms.json — the app is the sole writer of it and the only party with
    /// working AlarmKit authorization.
    public func writePendingAction(_ action: PendingWidgetAction) throws {
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw CocoaError(.fileNoSuchFile,
                userInfo: [NSLocalizedDescriptionKey: "No App Group container for \(appGroupIdentifier)"])
        }
        let url = appGroupURL.appendingPathComponent(PendingWidgetAction.fileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(action).write(to: url, options: .atomic)
        SmartWakeDebugLog.log("WIDGET ACTION QUEUED: \(action.action) alarm=\(action.alarmID.uuidString.prefix(8)) at \(action.requestedAt)")
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
        
        // Verify this is still the next alarm - but still write snapshot even if stale
        let currentNext = engine.earliestOccurrence(now: now())
        let isCurrentNext = currentNext?.alarmID == alarmID
        
        if isCurrentNext {
            try engine.adjustNext(id: alarmID, byMinutes: minutes, now: now())
        }
        
        try saveSnapshot(engine.snapshot)
        
        // Write updated widget snapshot ALWAYS (not just when isCurrentNext)
        writeNextAlarmSnapshot(engine: engine)
        
        return isCurrentNext
    }
    
    /// Set custom next time for alarm
    public func setNextAlarmTime(alarmID: UUID, date: Date) async throws -> Bool {
        var snapshot = try loadSnapshot()
        var engine = AlarmEngine(snapshot: snapshot)
        
        guard let alarm = engine.alarm(id: alarmID), alarm.isEnabled else {
            return false
        }
        
        let currentNext = engine.earliestOccurrence(now: now())
        let isCurrentNext = currentNext?.alarmID == alarmID
        
        if isCurrentNext {
            try engine.setNextTime(id: alarmID, date: date, now: now())
        }
        
        try saveSnapshot(engine.snapshot)
        
        // Write updated widget snapshot ALWAYS (not just when isCurrentNext)
        writeNextAlarmSnapshot(engine: engine)
        
        return isCurrentNext
    }
    
    /// Reset next alarm to base schedule
    public func resetNextAlarm(alarmID: UUID) async throws -> Bool {
        var snapshot = try loadSnapshot()
        var engine = AlarmEngine(snapshot: snapshot)
        
        guard let alarm = engine.alarm(id: alarmID), alarm.isEnabled else {
            return false
        }
        
        let currentNext = engine.earliestOccurrence(now: now())
        let isCurrentNext = currentNext?.alarmID == alarmID
        
        if isCurrentNext {
            try engine.resetNext(id: alarmID, now: now())
        }
        
        try saveSnapshot(engine.snapshot)
        
        // Write updated widget snapshot ALWAYS (not just when isCurrentNext)
        writeNextAlarmSnapshot(engine: engine)
        
        return isCurrentNext
    }
    
    /// Skip next occurrence
    public func skipNextAlarm(alarmID: UUID) async throws -> Bool {
        var snapshot = try loadSnapshot()
        var engine = AlarmEngine(snapshot: snapshot)
        
        guard let alarm = engine.alarm(id: alarmID), alarm.isEnabled else {
            return false
        }
        
        let currentNext = engine.earliestOccurrence(now: now())
        let isCurrentNext = currentNext?.alarmID == alarmID
        
        if isCurrentNext {
            try engine.skipNext(id: alarmID, now: now())
        }
        
        try saveSnapshot(engine.snapshot)
        
        // Write updated widget snapshot ALWAYS (not just when isCurrentNext)
        writeNextAlarmSnapshot(engine: engine)
        
        return isCurrentNext
    }
    
    /// Undo skip for next occurrence
    public func undoSkipAlarm(alarmID: UUID) async throws -> Bool {
        var snapshot = try loadSnapshot()
        var engine = AlarmEngine(snapshot: snapshot)
        
        guard let alarm = engine.alarm(id: alarmID), alarm.isEnabled else {
            return false
        }
        
        let currentNext = engine.earliestOccurrence(now: now())
        let isCurrentNext = currentNext?.alarmID == alarmID
        
        if isCurrentNext {
            try engine.undoSkip(id: alarmID, now: now())
        }
        
        try saveSnapshot(engine.snapshot)
        
        // Write updated widget snapshot ALWAYS (not just when isCurrentNext)
        writeNextAlarmSnapshot(engine: engine)
        
        return isCurrentNext
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