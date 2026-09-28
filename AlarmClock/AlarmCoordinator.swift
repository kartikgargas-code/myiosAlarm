import AlarmKit
import ActivityKit
import Foundation
import Observation

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
        self.scheduler = scheduler ?? AlarmKitSchedulingService()
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
                    id: SystemScheduleID.make(for: occurrence, label: label),
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
            // Check if we already have a random sound selected for this occurrence
            if let override = alarm.overrides[occurrence.occurrenceKey],
               let selectedSoundID = override.randomSoundID {
                // Verify the sound still exists in the playlist
                if let playlist = try? SoundLibrary.shared.playlist(for: playlistID),
                   playlist.soundIDs.contains(selectedSoundID) {
                    return (.imported(selectedSoundID), nil)
                }
            }

            // Need to select a new random song
            let playlist = try SoundLibrary.shared.playlist(for: playlistID)
            let availableSounds = playlist.soundIDs

            // Avoid immediately repeating the previous song if multiple available
            var previousSoundID: UUID?
            // Find the previous occurrence's selected sound
            let earlierOccurrences = engine.desiredOccurrences(now: now().addingTimeInterval(-86400 * 7))
                .filter { $0.alarmID == alarm.id && $0.effectiveDate < occurrence.effectiveDate }
                .sorted { $0.effectiveDate > $1.effectiveDate }
            if let prevOccurrence = earlierOccurrences.first,
               let prevOverride = alarm.overrides[prevOccurrence.occurrenceKey],
               let prevSoundID = prevOverride.randomSoundID {
                previousSoundID = prevSoundID
            }

            var candidates = availableSounds
            if let previousSoundID, candidates.count > 1 {
                candidates.removeAll { $0 == previousSoundID }
            }

            let selectedSoundID = candidates.randomElement() ?? availableSounds.randomElement()!

            // Store the selection in the override for this occurrence
            var newOverride = alarm.overrides[occurrence.occurrenceKey] ?? .none
            newOverride.randomSoundID = selectedSoundID

            return (.imported(selectedSoundID), newOverride)

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
                if let originalSound = SoundLibrary.shared.importedSounds.first(where: { $0.id == id }) {
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
        }
    }

    private func publish() {
        alarms = engine.alarms
        nextOccurrence = engine.earliestOccurrence(now: now())
    }

    /// Schedule a test alarm using the actual alarm configuration
    /// Uses a separate temporary AlarmKit alarm ID so it doesn't interfere with real alarms
    func scheduleTestAlarm(_ alarm: AlarmRecord, delay: TimeInterval) async {
        let testDate = now().addingTimeInterval(delay)
        let testID = UUID() // Separate temporary ID for test alarm

        // Resolve the sound for the test (handles random mode)
        var soundToUse = alarm.sound
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
                    // Pick a random song for the test
                    let selectedSoundID = playlist.soundIDs.randomElement()!
                    if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == selectedSoundID }) {
                        displaySound = "\(sound.name) (from \(playlist.name))"
                    }
                    soundToUse = .imported(selectedSoundID)
                }
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
