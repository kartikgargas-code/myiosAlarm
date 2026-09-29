import AlarmKit
import ActivityKit
import Foundation
import Observation
import WidgetKit
import os.log

@MainActor
@Observable
final class AlarmCoordinator {
    private(set) var alarms: [AlarmRecord] = []
    private(set) var nextOccurrence: AlarmOccurrence?
    private(set) var lastError: String?
    private(set) var isSynchronizing = false
    private var commitError: String?
    // Store the engine modified by desiredSystemAlarms to persist random sound selections
    private var desiredSystemAlarmsEngine: AlarmEngine?

    // Playlist diagnostics
    var playlistDiagnostics = PlaylistDiagnostics()

    /// The computed next alarm snapshot for widgets and Lock Screen controls
    private(set) var nextAlarmSnapshot: NextAlarmSnapshot? = nil

    /// Diagnostic: last snapshot write result
    private(set) var lastSnapshotWriteResult: (success: Bool, error: String?, timestamp: Date?) = (true, nil, nil)

    /// Diagnostic: last WidgetCenter reload request timestamp
    private(set) var lastWidgetReloadRequest: Date? = nil

    /// Live Activity for Dynamic Island
    private var liveActivity: Activity<NextAlarmAttributes>?

    private var engine: AlarmEngine
    private let persistence: any AlarmPersisting
    private let scheduler: any AlarmSystemScheduling
    private let now: () -> Date

    init(
        persistence: any AlarmPersisting = JSONAlarmPersistence(),
        scheduler: (any AlarmSystemScheduling)? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.persistence = persistence
        if let scheduler {
            self.scheduler = scheduler
        } else {
            #if DIAGNOSTIC_BUILD
            self.scheduler = DiagnosticAlarmSchedulingService()
            #else
            self.scheduler = AlarmKitSchedulingService()
            #endif
        }
        self.now = now
        do {
            engine = AlarmEngine(snapshot: try persistence.load(), calendar: calendar)
        } catch {
            engine = AlarmEngine(calendar: calendar)
            lastError = "Could not load alarms: \(error.localizedDescription)"
        }
        publish()
    }

    func synchronize() async {
        await commit { _ in }
    }

    func save(_ alarm: AlarmRecord) async {
        await commit { try $0.upsert(alarm, now: now()) }
    }

    func delete(id: UUID) async {
        await commit { $0.delete(id: id) }
    }

    func setEnabled(_ enabled: Bool, id: UUID) async {
        await commit { try $0.setEnabled(enabled, id: id) }
    }

    func adjustNext(id: UUID, minutes: Int) async {
        await commit { try $0.adjustNext(id: id, byMinutes: minutes, now: now()) }
    }

    func setNextTime(id: UUID, date: Date) async {
        await commit { try $0.setNextTime(id: id, date: date, now: now()) }
    }

    func resetNext(id: UUID) async {
        await commit { try $0.resetNext(id: id, now: now()) }
    }

    func skipNext(id: UUID) async {
        await commit { try $0.skipNext(id: id, now: now()) }
    }

    func undoSkip(id: UUID) async {
        await commit { try $0.undoSkip(id: id, now: now()) }
    }

    func occurrence(for alarmID: UUID) -> AlarmOccurrence? {
        engine.nextOccurrence(for: alarmID, now: now())
    }

    private func commit(_ mutation: (inout AlarmEngine) throws -> Void) async {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }

        var candidate = engine
        commitError = nil
        do {
            try mutation(&candidate)
            candidate.pruneExpiredOverrides(now: now())
            let desired = await desiredSystemAlarms(from: candidate)
            if let desiredError = commitError {
                lastError = desiredError
                return
            }
            // Use the engine modified by desiredSystemAlarms to persist random sound selections
            if let modifiedEngine = desiredSystemAlarmsEngine {
                candidate = modifiedEngine
            }
            candidate.snapshot.managedSystemAlarmIDs = try await scheduler.reconcile(
                desired: desired,
                managedIDs: engine.snapshot.managedSystemAlarmIDs
            )
            try persistence.save(candidate.snapshot)
            engine = candidate
            lastError = nil
            publish()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func desiredSystemAlarms(from engine: AlarmEngine) async -> [DesiredSystemAlarm] {
        var mutableEngine = engine
        let occurrences = mutableEngine.desiredOccurrences(now: now())
        var results: [DesiredSystemAlarm] = []
        
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
                        try mutableEngine.upsert(updatedAlarm, now: now())
                    }
                }
                let alarmKitSound = try await alarmKitSound(for: soundToUse, loudness: alarm.loudness)
                results.append(DesiredSystemAlarm(
                    id: SystemScheduleID.make(
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
                commitError = error.localizedDescription
            }
        }
        // Store the modified engine for persistence
        desiredSystemAlarmsEngine = mutableEngine
        return results
    }

    /// Resolve the sound for a specific occurrence, handling random mode
    /// Returns the sound to use and the updated override (if any)
    private func resolveSoundForOccurrence(alarm: AlarmRecord, occurrence: AlarmOccurrence, engine: AlarmEngine) throws -> (AlarmSound, AlarmOccurrenceOverride?) {
        switch alarm.sound {
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

            // For precomposed, we just need the playlist ID
            // The actual song selection happens during precomposition
            let playlist = try SoundLibrary.shared.playlist(for: playlistID)
            let availableSounds = playlist.soundIDs
            
            // Store the playlist ID in the override for this occurrence
            var newOverride = alarm.overrides[occurrence.occurrenceKey] ?? .none
            newOverride.randomSoundID = playlistID  // Store playlist ID for precomposed

            // Return precomposed playlist sound with the alarm's loudness
            let precomposedSound = AlarmSound.precomposedPlaylist(playlistID, alarm.loudness)
            return (precomposedSound, newOverride)

        default:
            return (alarm.sound, nil)
        }
    }

    private func alarmKitSound(for sound: AlarmSound, loudness: AlarmLoudness = .hundred) async throws -> AlertConfiguration.AlertSound {
        switch sound {
        case .systemDefault:
            return .default
        case .builtIn(let name):
            guard let fileName = AlarmSound.builtIn(name).systemFileName else {
                throw SoundLibraryError.builtInSoundMissing(name)
            }
            guard SoundPreviewService.bundledSoundURL(for: fileName) != nil else {
                throw SoundLibraryError.builtInSoundMissing(fileName)
            }
            return .named(fileName)
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
            playlistDiagnostics.addPreparation(preparationEntry)
            playlistDiagnostics.addGeneratedFile(generatedFileEntry)
            
            // Copy to Library/Sounds for AlarmKit access
            let processedFileName = precomposedURL.lastPathComponent
            let soundsDir = SoundLibrary.shared.soundsDirectory!
            let alarmKitURL = soundsDir.appendingPathComponent(processedFileName)
            
            let fileExistedAtScheduling = FileManager.default.fileExists(atPath: alarmKitURL.path)
            
            if !fileExistedAtScheduling {
                try FileManager.default.copyItem(at: precomposedURL, to: alarmKitURL)
            }
            
            // Record scheduling diagnostics
            let schedulingEntry = PlaylistDiagnostics.SchedulingEntry(
                timestamp: Date(),
                alarmID: UUID(), // Will be filled by caller
                occurrenceKey: "", // Will be filled by caller
                scheduledDate: Date(),
                soundConfiguration: "Precomposed playlist (\(precomposedURL.lastPathComponent))",
                usedPrecomposedFile: true,
                fileName: precomposedURL.lastPathComponent,
                fileExistedAtScheduling: fileExistedAtScheduling,
                alarmKitAccepted: false, // Will be updated after scheduling
                error: nil,
                fallbackToSingleSong: false,
                fallbackReason: nil
            )
            
            // Store for later update after scheduling
            // For now, we'll just return the sound
            return .named(processedFileName)
        }
    }

    private func publish() {
        let currentDate = now()
        alarms = engine.alarmsOrderedByNextOccurrence(now: currentDate)
        let earliest = engine.earliestOccurrence(now: currentDate)
        nextOccurrence = earliest
        
        // Compute next alarm snapshot for widgets and Lock Screen controls
        if let earliest = earliest {
            if let alarm = engine.alarm(id: earliest.alarmID) {
                nextAlarmSnapshot = NextAlarmSnapshot(alarm: alarm, occurrence: earliest)
            }
        } else {
            nextAlarmSnapshot = nil
        }
        
        // Write to App Group for widget extension
        writeNextAlarmSnapshotToAppGroup()
        
        // Update Live Activity
        updateLiveActivity()
    }
    
    /// Update or start the Live Activity for Dynamic Island
    private func updateLiveActivity() {
        guard let snapshot = nextAlarmSnapshot else {
            // No upcoming alarm - end any existing activity
            endLiveActivity()
            return
        }
        
        // Use the alarm's configured adjustment step minutes
        let alarmRecord = engine.alarm(id: snapshot.alarmID)
        let adjustmentStepMinutes = alarmRecord?.adjustmentStepMinutes ?? 10
        
        let contentState = NextAlarmAttributes.ContentState(
            alarmID: snapshot.alarmID,
            label: snapshot.label,
            nextOccurrenceDate: snapshot.nextOccurrenceDate,
            adjustmentStepMinutes: adjustmentStepMinutes,
            isAdjusted: snapshot.isAdjusted,
            adjustmentDescription: snapshot.adjustmentDescription,
            isSkipped: snapshot.isSkipped,
            isEnabled: snapshot.isEnabled,
            sound: snapshot.sound,
            loudness: snapshot.loudness,
            repeatRule: snapshot.repeatRule
        )
        
        let attributes = NextAlarmAttributes(alarmID: snapshot.alarmID)
        
        Task {
            do {
                if let activity = liveActivity {
                    // Update existing activity
                    await activity.update(using: contentState)
                } else {
                    // Start new activity
                    let activity = try Activity.request(
                        attributes: attributes,
                        content: .init(state: contentState, staleDate: nil),
                        pushType: nil
                    )
                    await MainActor.run {
                        self.liveActivity = activity
                    }
                }
            } catch {
                print("Failed to update Live Activity: \(error)")
            }
        }
    }
    
    /// End the Live Activity
    private func endLiveActivity() {
        Task {
            for activity in Activity<NextAlarmAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            await MainActor.run {
                self.liveActivity = nil
            }
        }
    }
    
    private func writeNextAlarmSnapshotToAppGroup() {
        let timestamp = Date()
        
        guard let configuredAppGroup = Bundle.main.object(
            forInfoDictionaryKey: "AlarmClockAppGroupIdentifier"
        ) as? String else {
            WidgetDiagnostics.appLogEvent("Missing configured App Group identifier in Info.plist", appGroupIdentifier: nil, containerAvailable: false)
            lastSnapshotWriteResult = (false, "Missing configured App Group identifier", timestamp)
            return
        }
        let resignedAppGroups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        let appGroupIdentifier = resignedAppGroups.first {
            $0 == configuredAppGroup || $0.hasPrefix(configuredAppGroup + ".")
        } ?? configuredAppGroup

        WidgetDiagnostics.appLogEvent("Resolved App Group identifier", appGroupIdentifier: appGroupIdentifier)
        
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            WidgetDiagnostics.appLogEvent("Failed to get App Group container URL", appGroupIdentifier: appGroupIdentifier, containerAvailable: false)
            lastSnapshotWriteResult = (false, "Failed to get App Group container URL", timestamp)
            return
        }
        
        WidgetDiagnostics.appLogEvent("App Group container available", appGroupIdentifier: appGroupIdentifier, containerAvailable: true)
        
        let snapshotURL = appGroupURL.appendingPathComponent("nextAlarmSnapshot.json")
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        do {
            let data = try encoder.encode(nextAlarmSnapshot)
            try data.write(to: snapshotURL, options: .atomic)
            
            // Verify write
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
            let fileSize = (fileAttributes[.size] as? Int) ?? 0
            let fileModDate = (fileAttributes[.modificationDate] as? Date) ?? timestamp
            
            WidgetDiagnostics.appLogEvent("Snapshot written successfully", 
                appGroupIdentifier: appGroupIdentifier, 
                containerAvailable: true,
                fileExists: true,
                fileSize: fileSize,
                fileModificationDate: fileModDate,
                writeSuccess: true,
                snapshotAlarmID: nextAlarmSnapshot?.alarmID,
                snapshotLabel: nextAlarmSnapshot?.label,
                snapshotNextOccurrence: nextAlarmSnapshot?.nextOccurrenceDate,
                snapshotIsEnabled: nextAlarmSnapshot?.isEnabled)
            
            var reloadRequested = false
            if let widgetKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockWidgetKind") as? String {
                WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
                reloadRequested = true
            }
            if let controlKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockControlKind") as? String {
                WidgetCenter.shared.reloadTimelines(ofKind: controlKind)
                reloadRequested = true
            }
            
            lastSnapshotWriteResult = (true, nil, timestamp)
            lastWidgetReloadRequest = timestamp
            
            WidgetDiagnostics.appLogEvent("WidgetCenter reload requested", 
                appGroupIdentifier: appGroupIdentifier,
                widgetReloadRequested: reloadRequested)
            
        } catch {
            WidgetDiagnostics.appLogEvent("Failed to write snapshot", 
                appGroupIdentifier: appGroupIdentifier,
                containerAvailable: true,
                fileExists: false,
                writeSuccess: false,
                writeError: error.localizedDescription)
            
            lastSnapshotWriteResult = (false, error.localizedDescription, timestamp)
        }
    }

    /// Schedule a test alarm using the actual alarm configuration
    /// Uses a separate temporary AlarmKit alarm ID so it doesn't interfere with real alarms
    func scheduleTestAlarm(_ alarm: AlarmRecord, delay: TimeInterval) async {
        #if DIAGNOSTIC_BUILD
        lastError = "Alarm scheduling is disabled in AlarmClock Diagnostic."
        return
        #endif

        let testDate = now().addingTimeInterval(delay)
        let testID = UUID() // Separate temporary ID for test alarm

        // Resolve the sound for the test (handles random mode)
        let soundToUse: AlarmSound
        var displaySound = "Default"
        var displayLoudness = alarm.loudness

        do {
            switch alarm.sound {
            case .systemDefault:
                displaySound = "System Default"
                soundToUse = .systemDefault
            case .builtIn(let name):
                displaySound = name
                soundToUse = .builtIn(name)
            case .imported(let id):
                if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == id }) {
                    displaySound = sound.name
                }
                soundToUse = .imported(id)
            case .random(let playlistID):
                if let playlist = SoundLibrary.shared.playlists.first(where: { $0.id == playlistID }),
                   !playlist.soundIDs.isEmpty {
                    // Use precomposed playlist for test alarm too
                    soundToUse = .precomposedPlaylist(playlistID, alarm.loudness)
                    if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == playlist.soundIDs.first! }) {
                        displaySound = "\(sound.name) (from \(playlist.name) — precomposed)"
                    }
                } else {
                    soundToUse = .systemDefault
                }
            case .precomposedPlaylist:
                soundToUse = alarm.sound
            }

            let alarmKitSound = try await alarmKitSound(for: soundToUse, loudness: alarm.loudness)

            // Create the test alarm configuration
            let alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: "[TEST] \(alarm.label.isEmpty ? "Test Alarm" : alarm.label)"),
                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle.fill")
            )
            let attributes = AlarmAttributes(
                presentation: AlarmPresentation(alert: alert),
                metadata: ScheduledOccurrenceMetadata(
                    alarmID: alarm.id,
                    occurrenceKey: "TEST-\(Int64(testDate.timeIntervalSince1970))",
                    baseDate: testDate
                ),
                tintColor: .orange
            )

            let configuration = AlarmManager.AlarmConfiguration.alarm(
                schedule: .fixed(testDate),
                attributes: attributes,
                sound: alarmKitSound
            )

            _ = try await (scheduler as? AlarmKitSchedulingService)?.manager.schedule(id: testID, configuration: configuration)

        } catch {
            lastError = "Test alarm failed: \(error.localizedDescription)"
        }
    }

    /// Cancel a pending test alarm
    func cancelTestAlarm(testID: UUID) async {
        try? (scheduler as? AlarmKitSchedulingService)?.manager.cancel(id: testID)
    }
}
