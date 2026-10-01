import Foundation
import AlarmClockShared
import WidgetKit
import AlarmKit
import ActivityKit

/// Handles Live Activity alarm operations, AlarmKit reconciliation, and widget updates.
public struct SharedAlarmService: LiveActivityAlarmService {
    private let appGroupIdentifier: String
    private let persistence: JSONAlarmPersistence
    private let now: () -> Date
    private let extensionScheduler = ExtensionAlarmSchedulingService()
    
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
        
        // Reconcile with AlarmKit immediately
        let desired = await desiredSystemAlarms(from: engine, now: now())
        let managedIDs = engine.snapshot.managedSystemAlarmIDs
        _ = try await extensionScheduler.reconcile(desired: desired, managedIDs: managedIDs)
        
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
        
        // Reconcile with AlarmKit immediately
        let desired = await desiredSystemAlarms(from: engine, now: now())
        let managedIDs = engine.snapshot.managedSystemAlarmIDs
        _ = try await extensionScheduler.reconcile(desired: desired, managedIDs: managedIDs)
        
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
        
        // Reconcile with AlarmKit immediately
        let desired = await desiredSystemAlarms(from: engine, now: now())
        let managedIDs = engine.snapshot.managedSystemAlarmIDs
        _ = try await extensionScheduler.reconcile(desired: desired, managedIDs: managedIDs)
        
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
        
        // Reconcile with AlarmKit immediately
        let desired = await desiredSystemAlarms(from: engine, now: now())
        let managedIDs = engine.snapshot.managedSystemAlarmIDs
        _ = try await extensionScheduler.reconcile(desired: desired, managedIDs: managedIDs)
        
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
    
    /// Compute desired system alarms for AlarmKit reconciliation
    /// Mirrors AlarmCoordinator.desiredSystemAlarms for extension use
    private func desiredSystemAlarms(from engine: AlarmEngine, now: Date) async -> [ExtensionAlarmSchedulingService.DesiredSystemAlarm] {
        var mutableEngine = engine
        let occurrences = mutableEngine.desiredOccurrences(now: now)
        var results: [ExtensionAlarmSchedulingService.DesiredSystemAlarm] = []
        
        for occurrence in occurrences {
            guard let alarm = mutableEngine.alarm(id: occurrence.alarmID) else { continue }
            let label = alarm.label.isEmpty ? "Alarm" : alarm.label
            do {
                // For random mode, select a song for this occurrence if not already selected
                let (soundToUse, override) = try resolveSoundForOccurrence(alarm: alarm, occurrence: occurrence, engine: mutableEngine)
                // Apply the override if there is one
                if let newOverride = override {
                    if var updatedAlarm = mutableEngine.alarm(id: alarm.id) {
                        updatedAlarm.overrides[occurrence.occurrenceKey] = newOverride
                        try mutableEngine.upsert(updatedAlarm, now: now)
                    }
                }
                let alarmKitSound = try await alarmKitSound(for: soundToUse, loudness: alarm.loudness)
                results.append(ExtensionAlarmSchedulingService.DesiredSystemAlarm(
                    id: ExtensionAlarmSchedulingService.SystemScheduleID.make(
                        for: occurrence,
                        label: label,
                        sound: soundToUse,
                        loudness: alarm.loudness
                    ),
                    occurrence: occurrence,
                    label: label,
                    sound: soundToUse,
                    alarmKitSound: alarmKitSound
                ))
            } catch {
                print("Error resolving sound for occurrence: \(error)")
            }
        }
        return results
    }
    
    /// Resolve sound for occurrence (copied from AlarmCoordinator for extension use)
    private func resolveSoundForOccurrence(alarm: AlarmRecord, occurrence: AlarmOccurrence, engine: AlarmEngine) throws -> (AlarmSound, AlarmOccurrenceOverride?) {
        switch alarm.sound {
        case .systemDefault:
            return (.systemDefault, nil)
        case .builtIn(let name):
            return (.builtIn(name), nil)
        case .imported(let id):
            return (.imported(id), nil)
        case .random(let playlistID):
            // Check if we already have a precomposed playlist for this occurrence
            if let override = alarm.overrides[occurrence.occurrenceKey],
               let selectedSoundID = override.randomSoundID {
                // Verify the sound still exists in the playlist
                if let playlist = try? SoundLibrary.shared.playlist(for: playlistID),
                   playlist.soundIDs.contains(selectedSoundID) {
                    // Check if precomposed playlist exists for this loudness
                    let precomposedSound = AlarmSound.precomposedPlaylist(playlistID, alarm.loudness)
                    return (precomposedSound, nil)
                }
            }

            // Need to select a new random song (but we'll use precomposed playlist)
            // Avoid immediately repeating the previous precomposed playlist if multiple available
            var previousPlaylistID: UUID?
            // Find the previous occurrence's selected playlist
            let earlierOccurrences = engine.desiredOccurrences(now: now().addingTimeInterval(-86400 * 7))
                .filter { $0.alarmID == alarm.id && $0.effectiveDate < occurrence.effectiveDate }
                .sorted { $0.effectiveDate > $1.effectiveDate }
            if let prevOccurrence = earlierOccurrences.first,
               let prevOverride = alarm.overrides[prevOccurrence.occurrenceKey],
               let prevSoundID = prevOverride.randomSoundID {
                // The previousSoundID was a playlist ID for precomposed
                previousPlaylistID = prevSoundID
            }
            
            let precomposedSound = AlarmSound.precomposedPlaylist(playlistID, alarm.loudness)
            let newOverride = AlarmOccurrenceOverride(
                offsetMinutes: nil,
                customDate: nil,
                isSkipped: false,
                randomSoundID: playlistID
            )
            return (precomposedSound, newOverride)
        case .precomposedPlaylist:
            return (alarm.sound, nil)
        }
    }
    
    /// Resolve alarmKit sound (copied from AlarmCoordinator for extension use)
    private func alarmKitSound(for sound: AlarmSound, loudness: AlarmLoudness) async throws -> AlertConfiguration.AlertSound {
        switch sound {
        case .systemDefault:
            return .default
        case .builtIn(let name):
            return .default // Built-in sounds use default
        case .imported(let id):
            let fileName = try SoundLibrary.shared.alarmKitFileName(for: id)
            
            // If loudness is not 100%, use the processed sound file
            if loudness != .hundred {
                // Get the original sound info
                let originalSound = SoundLibrary.shared.importedSounds.first(where: { $0.id == id })
                if let originalSound {
                    // Get or create the processed sound
                    let processedURL = try await AudioProcessingService.shared.getOrCreateProcessedSound(
                        for: originalSound,
                        loudness: loudness
                    )
                    // The processed file is a WAV in Library/ProcessedSounds
                    // Copy it to Library/Sounds for AlarmKit access
                    let processedFileName = processedURL.lastPathComponent
                    let soundsDir = SoundLibrary.shared.soundsDirectory!
                    let alarmKitURL = soundsDir.appendingPathComponent(processedFileName)
                    
                    if !FileManager.default.fileExists(atPath: alarmKitURL.path) {
                        try FileManager.default.copyItem(at: processedURL, to: alarmKitURL)
                    }
                    return .named(processedFileName)
                }
            }
            return .named(fileName)
        case .random:
            // This should never be reached since we resolve random before calling this
            throw SoundLibraryError.importFailed("Random sound not resolved")
        case .precomposedPlaylist(let playlistID, let loudness):
            // Generate or get the precomposed playlist file
            let (precomposedURL, preparationEntry, generatedFileEntry) = try await AudioProcessingService.shared.precomposePlaylist(
                playlistID: playlistID,
                loudness: loudness,
                songCount: 5
            )
            
            // Record diagnostics
            // playlistDiagnostics.addPreparation(preparationEntry)
            // playlistDiagnostics.addGeneratedFile(generatedFileEntry)
            
            // Copy to Library/Sounds for AlarmKit access
            let processedFileName = precomposedURL.lastPathComponent
            let soundsDir = SoundLibrary.shared.soundsDirectory!
            let alarmKitURL = soundsDir.appendingPathComponent(processedFileName)
            
            let fileExistedAtScheduling = FileManager.default.fileExists(atPath: alarmKitURL.path)
            
            if !fileExistedAtScheduling {
                try FileManager.default.copyItem(at: precomposedURL, to: alarmKitURL)
            }
            
            // Record scheduling diagnostics
            // let schedulingEntry = PlaylistDiagnostics.SchedulingEntry(...)
            
            // Store for later update after scheduling
            // For now, we'll just return the sound
            return .named(processedFileName)
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