import AVFoundation
import Observation
import Foundation
import os.log
import AlarmClockShared

/// Background audio session manager for "Smart Wake" feature
/// Keeps a silent/near-silent loop running overnight so the app stays alive
/// and can play the real song at alarm time with Now Playing info
@MainActor
@Observable
final class SmartWakeService {
    static let shared = SmartWakeService()

    private let log = OSLog(subsystem: "com.example.alarmclock", category: "SmartWake")
    private let fileManager = FileManager.default
    private var player: AVAudioPlayer?
    private var isSessionActive = false
    private var isEnabled = false
    private var silentLoopURL: URL?
    private weak var coordinator: AlarmCoordinator?
    
    // Transition arming
    private var transitionCheckTask: Task<Void, Never>?
    private var armedOccurrences: Set<String> = []

    // User preference key
    private let enabledKey = "SmartWakeEnabled"

    var isRunning: Bool {
        isSessionActive && player?.isPlaying == true
    }

    init() {
        loadPreference()
        prepareSilentLoop()
    }

    private func loadPreference() {
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    }

    var isSmartWakeEnabled: Bool {
        get { isEnabled }
        set {
            guard newValue != isEnabled else { return }
            isEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue {
                Task { await startIfAlarmArmedInternal() }
            } else {
                stop()
            }
        }
    }

    /// Prepare the silent loop audio file (generates a 1-second near-silent WAV if needed)
    private func prepareSilentLoop() {
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        silentLoopURL = documentsDir.appendingPathComponent("smartwake_silent_loop.wav")

        if fileManager.fileExists(atPath: silentLoopURL!.path) {
            return
        }

        // Generate a 1-second near-silent WAV file programmatically
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.generateSilentLoop()
        }
    }

    private func generateSilentLoop() async {
        guard let url = silentLoopURL else { return }

        let sampleRate = 44100.0
        let duration = 1.0 // 1 second loop
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            os_log(.error, log: log, "Failed to create silent buffer")
            return
        }
        buffer.frameLength = frameCount

        // Fill with near-silence (very low amplitude to keep audio session alive)
        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        let amplitude: Float = 0.0001 // -80 dB, barely audible but keeps session alive

        for channel in 0..<channels {
            guard let channelData = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<frames {
                // Very low frequency tone at near-zero amplitude
                channelData[frame] = amplitude * sin(2.0 * Float.pi * 20.0 * Float(frame) / Float(sampleRate))
            }
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        do {
            let outputFile = try AVAudioFile(forWriting: url, settings: settings)
            try outputFile.write(from: buffer)
            os_log(.info, log: log, "Generated silent loop at %{public}s", url.path)
        } catch {
            os_log(.error, log: log, "Failed to generate silent loop: %{public}s", error.localizedDescription)
        }
    }

    /// Start the background audio session if an alarm is armed for the near future
    func startIfAlarmArmed(coordinator: AlarmCoordinator) async {
        self.coordinator = coordinator
        await startIfAlarmArmedInternal()
    }

    /// Internal version that uses the stored coordinator reference
    private func startIfAlarmArmedInternal() async {
        guard let coordinator = self.coordinator else {
            os_log(.error, log: log, "No coordinator available for Smart Wake")
            return
        }

        let now = Date()
        let soon = now.addingTimeInterval(8 * 3600) // Within next 8 hours

        // Check if any alarm is armed and due soon
        let hasUpcomingAlarm = coordinator.alarms.contains { alarm in
            guard alarm.isEnabled else { return false }
            if let occurrence = coordinator.occurrence(for: alarm.id) {
                return occurrence.effectiveDate <= soon && occurrence.effectiveDate > now
            }
            return false
        }

        guard hasUpcomingAlarm else {
            os_log(.info, log: log, "No upcoming alarm within 8h; not starting Smart Wake")
            return
        }

        await startBackgroundAudio()
    }

    /// Start the silent background audio loop
    private func startBackgroundAudio() async {
        guard let url = silentLoopURL,
              fileManager.fileExists(atPath: url.path) else {
            os_log(.error, log: log, "Silent loop file not ready")
            return
        }

        do {
            try configureAudioSession()
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.numberOfLoops = -1 // Loop indefinitely
            newPlayer.volume = 0.001 // Near-silent
            newPlayer.prepareToPlay()
            guard newPlayer.play() else {
                os_log(.error, log: log, "Failed to start silent loop playback")
                return
            }
            player = newPlayer
            isSessionActive = true
            os_log(.info, log: log, "Smart Wake silent loop started")

            // Register for interruption notifications
            registerForInterruptions()
            
            // Start transition arming task
            startTransitionArming()
        } catch {
            os_log(.error, log: log, "Failed to start background audio: %{public}s", error.localizedDescription)
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    /// Stop the background audio session
    func stop() {
        player?.stop()
        player = nil
        isSessionActive = false

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            os_log(.error, log: log, "Failed to deactivate audio session: %{public}s", error.localizedDescription)
        }

        unregisterForInterruptions()
        stopTransitionArming()
        os_log(.info, log: log, "Smart Wake stopped")
    }

    /// Stop only the silent player, keeping the audio session active and observers registered
    /// Used when transitioning to real alarm playback
    func stopSilentPlayerOnly() {
        os_log(.info, log: log, "stopSilentPlayerOnly() called - stopping silent loop, keeping session active")
        player?.stop()
        player = nil
        isSessionActive = false
        // Do NOT deactivate audio session
        // Do NOT unregister for interruptions/route changes
    }

    @MainActor private func logInterruptionBegan() {
        os_log(.info, log: log, "Audio interruption began")
    }

    @MainActor private func logInterruptionEnded(options: AVAudioSession.InterruptionOptions) {
        os_log(.info, log: log, "Audio interruption ended, shouldResume: %{public}d", options.contains(.shouldResume) ? 1 : 0)
    }

    @MainActor private func logRouteChange(reason: AVAudioSession.RouteChangeReason) {
        os_log(.info, log: log, "Audio route changed: %{public}d", reason.rawValue)
    }

    @MainActor private func handleInterruptionEnded(shouldResume: Bool) {
        if shouldResume {
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.play()
        }
    }

    @MainActor private func handleRouteChange(oldDeviceUnavailable: Bool) {
        if oldDeviceUnavailable {
            player?.pause()
        }
    }

    private func registerForInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    private func unregisterForInterruptions() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            logInterruptionBegan()
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            logInterruptionEnded(options: options)
            if options.contains(.shouldResume) {
                handleInterruptionEnded(shouldResume: true)
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        logRouteChange(reason: reason)
        if reason == .oldDeviceUnavailable {
            handleRouteChange(oldDeviceUnavailable: true)
        }
    }

    // MARK: - Transition Arming
    
    /// Start the background task that checks for upcoming alarms and arms transition
    private func startTransitionArming() {
        // Cancel any existing task
        transitionCheckTask?.cancel()
        
        transitionCheckTask = Task { @MainActor in
            os_log(.info, log: log, "Starting transition arming task")
            
            while !Task.isCancelled {
                // Check every 30 seconds
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                
                guard !Task.isCancelled else { break }
                
                await checkAndArmUpcomingAlarms()
            }
            
            os_log(.info, log: log, "Transition arming task ended")
        }
    }
    
    /// Stop the transition arming task
    private func stopTransitionArming() {
        transitionCheckTask?.cancel()
        transitionCheckTask = nil
        armedOccurrences.removeAll()
    }
    
    /// Check App Group alarms.json for upcoming occurrences and arm if within 60 seconds
    private func checkAndArmUpcomingAlarms() async {
        guard let coordinator = self.coordinator else {
            os_log(.error, log: log, "No coordinator available for transition arming")
            return
        }
        
        // Read fresh snapshot from App Group
        // AltStore resigns the group (adds team suffix); resolve at runtime.
        guard let appGroupIdentifier = AppGroupResolver.resolve() else {
            os_log(.error, log: log, "App Group container not available")
            return
        }

        guard let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            os_log(.error, log: log, "App Group container not available for %{public}s", appGroupIdentifier)
            return
        }
        
        let alarmsURL = appGroupURL.appendingPathComponent("alarms.json")
        guard FileManager.default.fileExists(atPath: alarmsURL.path) else {
            os_log(.info, log: log, "No alarms.json in App Group")
            return
        }
        
        do {
            let data = try Data(contentsOf: alarmsURL)
            let snapshot = try JSONDecoder.alarmDecoder.decode(AlarmStoreSnapshot.self, from: data)
            
            // Create engine from snapshot to evaluate occurrences
            let engine = AlarmEngine(snapshot: snapshot, calendar: Calendar.current)
            let now = Date()
            let ringWindowEnd = now.addingTimeInterval(8 * 3600) // 8 hours
            
            // Find all unskipped occurrences within the ring window
            let desiredOccurrences = engine.desiredOccurrences(now: now, perAlarmLimit: 5)
            let upcomingOccurrences = desiredOccurrences.filter { occ in
                occ.effectiveDate > now && occ.effectiveDate <= ringWindowEnd
            }
            
            guard !upcomingOccurrences.isEmpty else {
                os_log(.info, log: log, "No upcoming occurrences in ring window")
                return
            }
            
            // Find the earliest unskipped occurrence
            let earliestOccurrence = upcomingOccurrences.min { $0.effectiveDate < $1.effectiveDate }
            guard let earliest = earliestOccurrence else { return }
            
            let timeToFire = earliest.effectiveDate.timeIntervalSince(now)
            let occurrenceKey = earliest.occurrenceKey
            
            os_log(.info, log: log, "Next occurrence: %{public}s in %{public}.1fs (armed: %{public}d)", 
                   occurrenceKey, timeToFire, armedOccurrences.contains(occurrenceKey) ? 1 : 0)
            
            // If within 60 seconds and not yet armed, arm it
            if timeToFire <= 60 && timeToFire > 0 && !armedOccurrences.contains(occurrenceKey) {
                armedOccurrences.insert(occurrenceKey)
                os_log(.info, log: log, "ARMING transition for occurrence %{public}s (fire in %{public}.1fs)", 
                       occurrenceKey, timeToFire)
                
                // Schedule precise wake at fire time
                scheduleTransitionWake(for: earliest, snapshot: snapshot, engine: engine)
            }
            
            // Clean up old armed occurrences (past fire time + tolerance)
            let cleanupThreshold = now.addingTimeInterval(-10) // 10 seconds past
            let keysToRemove = armedOccurrences.filter { key in
                // Find the occurrence for this key and check if it's past
                if let occ = desiredOccurrences.first(where: { $0.occurrenceKey == key }) {
                    return occ.effectiveDate < cleanupThreshold
                }
                return true // Remove if not found
            }
            armedOccurrences.subtract(keysToRemove)
            
        } catch {
            os_log(.error, log: log, "Failed to check upcoming alarms: %{public}s", error.localizedDescription)
        }
    }
    
    /// Schedule a precise wake at the exact fire time
    private func scheduleTransitionWake(
        for occurrence: AlarmOccurrence,
        snapshot: AlarmStoreSnapshot,
        engine: AlarmEngine
    ) {
        let occurrenceKey = occurrence.occurrenceKey
        let fireDate = occurrence.effectiveDate
        let now = Date()
        let timeUntilFire = fireDate.timeIntervalSince(now)
        
        guard timeUntilFire > 0 else { return }
        
        Task { @MainActor in
            // Sleep until the exact fire time
            do {
                try await Task.sleep(nanoseconds: UInt64(timeUntilFire * 1_000_000_000))
            } catch {
                os_log(.error, log: log, "Transition wake sleep cancelled: %{public}s", error.localizedDescription)
                return
            }
            
            // Verify it's still the right time (±5s tolerance)
            let actualNow = Date()
            let tolerance: TimeInterval = 5.0
            if abs(actualNow.timeIntervalSince(fireDate)) > tolerance {
                os_log(.info, log: log, "Missed fire window for %{public}s (diff: %{public}.1fs)", 
                       occurrenceKey, actualNow.timeIntervalSince(fireDate))
                return
            }
            
            os_log(.info, log: log, "TRANSITION WAKE: Firing for occurrence %{public}s at %{public}s", 
                   occurrenceKey, actualNow.formatted(date: .omitted, time: .standard))
            
            // Find the alarm for this occurrence
            guard let alarm = engine.alarm(id: occurrence.alarmID) else {
                os_log(.error, log: log, "Alarm not found for occurrence %{public}s", occurrenceKey)
                return
            }
            
            // Resolve the sound for this occurrence using the same logic as scheduling
            do {
                let (soundToUse, _) = try resolveSoundForOccurrence(alarm: alarm, occurrence: occurrence, engine: engine)
                
                // Determine if it's a playlist (random/precomposedPlaylist) or single imported sound
                if isPlaylistSound(soundToUse) {
                    // Takeover: silence AlarmKit's alarm sound first, then play the
                    // playlist in-app. If AlarmKit refuses to cancel (the alarm keeps
                    // ringing), do NOT start in-app playback — double audio is worse
                    // than the system alarm sound alone.
                    let silenced = await silenceAlarmKitAlarm(for: alarm)
                    guard silenced else {
                        os_log(.info, log: log, "AlarmKit cancel failed; keeping system alarm sound only")
                        return
                    }
                    if case .precomposedPlaylist(let resolvedPlaylistID, _) = soundToUse {
                        os_log(.info, log: log, "TAKEOVER: starting playlist %{public}s after silencing AlarmKit", resolvedPlaylistID.uuidString)
                        AlarmPlaybackService.shared.start(
                            playlistID: resolvedPlaylistID,
                            loudness: alarm.loudness,
                            alarm: alarm,
                            occurrence: occurrence
                        )
                    }
                    stopSilentPlayerOnly()
                } else {
                    os_log(.info, log: log, "Sound type %{public}s - AlarmKit handles playback", String(describing: soundToUse))
                }
                
            } catch {
                os_log(.error, log: log, "Failed to resolve sound for occurrence: %{public}s", error.localizedDescription)
            }
        }
    }

    private func isPlaylistSound(_ sound: AlarmSound) -> Bool {
        switch sound {
        case .precomposedPlaylist: return true
        case .random: return true
        default: return false
        }
    }

    /// Ask AlarmKit to cancel the alerting alarm(s) so the system sound stops.
    /// Managed alarms are scheduled under SystemScheduleID identities (not the
    /// record id), so any alerting alarm at the transition moment is ours.
    /// Waits briefly for the alarm to actually enter .alerting first: if this
    /// wake-up fires a moment before AlarmKit starts ringing, starting playback
    /// immediately would produce double audio once the system sound kicks in.
    /// Returns false when nothing is alerting (no takeover should happen) or
    /// when a cancel call throws.
    private func silenceAlarmKitAlarm(for alarm: AlarmRecord) async -> Bool {
        var alerting: [Alarm] = []
        do {
            // Poll up to ~3s for the alarm to reach .alerting
            for _ in 0..<10 {
                alerting = try AlarmManager.shared.alarms.filter { $0.state == .alerting }
                if !alerting.isEmpty { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        } catch {
            os_log(.error, log: log, "Failed to inspect AlarmKit alarms: %{public}s", error.localizedDescription)
            return false
        }
        guard !alerting.isEmpty else {
            os_log(.info, log: log, "No alerting AlarmKit alarm appeared within 3s; skipping takeover")
            return false
        }
        var allCancelled = true
        for kitAlarm in alerting {
            do {
                // cancel() is the API proven in this codebase (all reconcile
                // paths); on an alerting alarm it removes it and silences the
                // sound. AlarmManager.stop(id:) is documented but unverified
                // here — only switch if cancel fails on device.
                try AlarmManager.shared.cancel(id: kitAlarm.id)
            } catch {
                allCancelled = false
                os_log(.error, log: log, "cancel(id:%{public}s) failed: %{public}s", kitAlarm.id.uuidString, error.localizedDescription)
            }
        }
        os_log(.info, log: log, "Cancel requested for %d alerting AlarmKit alarm(s), allCancelled=%{public}d", alerting.count, allCancelled ? 1 : 0)
        return allCancelled
    }
    
    /// Resolve sound for occurrence (mirrors AlarmCoordinator logic)
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
            var _previousPlaylistID: UUID?
            // Find the previous occurrence's selected playlist
            let earlierOccurrences = engine.desiredOccurrences(now: Date().addingTimeInterval(-86400 * 7))
                .filter { $0.alarmID == alarm.id && $0.effectiveDate < occurrence.effectiveDate }
                .sorted { $0.effectiveDate > $1.effectiveDate }
            if let prevOccurrence = earlierOccurrences.first,
               let prevOverride = alarm.overrides[prevOccurrence.occurrenceKey],
               let prevSoundID = prevOverride.randomSoundID {
                // The previousSoundID was a playlist ID for precomposed
                _previousPlaylistID = prevSoundID
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
}