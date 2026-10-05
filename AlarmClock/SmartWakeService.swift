import AVFoundation
import Observation
import Foundation
import os.log
import AlarmKit
import AlarmClockShared
import UIKit

/// Background audio session manager for "Smart Wake" feature
/// Keeps a silent/near-silent loop running overnight so the app stays alive
/// and can play the real song at alarm time with Now Playing info
@MainActor
@Observable
final class SmartWakeService {
    static let shared = SmartWakeService()
    
    // Configuration: when true, locked/background devices use native AlarmKit alarm first
    // (our floor WAV plays user's songs with native Stop/Snooze). Our process observes
    // AlarmManager.alarmUpdates for .alerting -> .gone (Stop) or .countdown (Snooze).
    // If Stop: wait 300ms, then start in-app playback for that alarm's playlist.
    // If Snooze: log and let AlarmKit handle re-ring.
    static let nativeFirstWhenLocked = false
    
    // Phase 7a: Delayed backup for playlist alarms when Smart Wake is enabled
    // Schedule AlarmKit backup at occurrence.effectiveDate + backupDelaySeconds
    static let backupDelaySeconds = 30
    
    private let log = OSLog(subsystem: "com.example.alarmclock", category: "SmartWake")
    private let fileManager = FileManager.default
    private var player: AVAudioPlayer?
    private var isSessionActive = false
    private var isEnabled = false
    private var silentLoopURL: URL?
    private weak var coordinator: AlarmCoordinator?
    
    // Transition arming
    private var transitionCheckTask: Task<Void, Never>?
    private var armedOccurrences: Set<String> = [] // Composite keys: "alarmID|occurrenceKey"
    /// Track which occurrence keys have already fired transition wake to prevent duplicates
    private var firedTransitionWakes: Set<String> = []

    // User preference key
    private let enabledKey = "SmartWakeEnabled"

    /// Stable per-selection hash so schedule identity changes when the chosen
    /// song set changes — reconcile then reschedules with the fresh precomposed file.
    private func desiredSelectionHash(for sound: AlarmSound) -> String? {
        if case .precomposedPlaylist(let playlistID, _) = sound,
           let playlist = try? SoundLibrary.shared.playlist(for: playlistID) {
            let key = playlist.selectedSoundIDs.map { $0.uuidString }.sorted().joined(separator: "-")
            return SoundSelectionHash.make(from: key)
        }
        return nil
    }

    // Status string for UI - only updates when value changes to prevent render churn
    private var statusText: String = "Waiting for next alarm..."
    var statusTextPublished: String {
        statusText
    }
    
    // Alerting song name for banner visibility during system rings (updated by status tick)
    private var _alertingSongName: String? = nil
    var alertingSongName: String? {
        get { _alertingSongName }
        set {
            if _alertingSongName != newValue {
                _alertingSongName = newValue
            }
        }
    }

    var isRunning: Bool {
        isSessionActive && player?.isPlaying == true
    }

    init() {
        loadPreference()
        prepareSilentLoop()
        startStatusTick()
    }
    
    /// Generate composite arming key from alarm ID and occurrence key (includes fire time for uniqueness)
    /// Key format: "alarmID_prefix|effectiveDate_timestamp"
    private func makeArmingKey(alarmID: UUID, occurrenceKey: String, effectiveDate: Date) -> String {
        let timestamp = Int(effectiveDate.timeIntervalSince1970)
        return "\(alarmID.uuidString.prefix(8))|\(timestamp)"
    }
    
    private var statusTickTask: Task<Void, Never>?
    
    private func startStatusTick() {
        statusTickTask = Task { @MainActor in
            var lastLoopRunning = isRunning
            var lastScenePhase: UIApplication.State = .background
            var lastAlertingCount = 0
            
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                guard !Task.isCancelled else { break }
                
                // Check for any alerting AlarmKit alarm (system ring) - for banner visibility during system rings
                do {
                    let alerting = try AlarmManager.shared.alarms.filter { $0.state == .alerting }
                    let alertingCount = alerting.count
                    if alertingCount != lastAlertingCount {
                        let scenePhase = UIApplication.shared.applicationState
                        SmartWakeDebugLog.log("SCENE -> \(scenePhaseString(scenePhase)) alerting=\(alertingCount)")
                        lastAlertingCount = alertingCount
                    }
                    if !alerting.isEmpty {
                        // Try to get song name from the first alerting alarm via coordinator
                        if let coordinator = AlarmCoordinator.sharedInstance {
                            for kitAlarm in alerting {
                                if let result = coordinator.currentlyRingingAlarm() {
                                    // Update the published property to trigger banner
                                    if _alertingSongName != result.songName {
                                        _alertingSongName = result.songName
                                    }
                                    break
                                }
                            }
                        }
                    } else {
                        // No alerting alarms - clear the song name
                        if _alertingSongName != nil {
                            _alertingSongName = nil
                        }
                    }
                } catch {
                    // Ignore errors
                }
                
                // Check if silent loop died
                if lastLoopRunning && !isRunning {
                    SmartWakeDebugLog.log("SILENT LOOP DIED: wasRunning=true nowRunning=false")
                    lastLoopRunning = false
                } else if !lastLoopRunning && isRunning {
                    lastLoopRunning = true
                }
                
                // Update status text only when it changes to prevent render churn
                let newStatus: String
                if AlarmPlaybackService.shared.isPlaying {
                    newStatus = "Ringing — playing your music"
                } else if isRunning {
                    newStatus = "Active — silent loop running"
                } else {
                    newStatus = "Waiting for next alarm..."
                }
                
                if newStatus != statusText {
                    statusText = newStatus
                }
                
                // Validate the ringing alarm still exists and is enabled
                if AlarmPlaybackService.shared.isPlaying {
                    if !AlarmPlaybackService.shared.validateStillRinging() {
                        // Alarm was disabled/deleted - stop playback
                        AlarmPlaybackService.shared.stop()
                        SmartWakeDebugLog.log("PLAYBACK stopped: alarm disabled/deleted (tick)")
                    }
                }
            }
        }
    }
    
    private func scenePhaseString(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown(\(state.rawValue))"
        }
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
                Task { 
                    // Retry once if coordinator not yet available (can happen on fresh launch toggle)
                    var attempts = 0
                    while coordinator == nil && attempts < 2 {
                        attempts += 1
                        if attempts == 2 {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                        }
                        await startIfAlarmArmedInternal()
                    }
                    if coordinator == nil {
                        SmartWakeDebugLog.log("START attempt: NO coordinator after retry â€” declining")
                    }
                }
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
            SmartWakeDebugLog.log("START attempt: NO coordinator â€” cannot check alarms")
            return
        }

        let now = Date()
        let soon = now.addingTimeInterval(8 * 3600) // Within next 8 hours

        // Check if any alarm is armed and due soon
        let upcoming = coordinator.alarms.filter { alarm in
            guard alarm.isEnabled else { return false }
            if let occurrence = coordinator.occurrence(for: alarm.id) {
                return occurrence.effectiveDate <= soon && occurrence.effectiveDate > now
            }
            return false
        }

        guard !upcoming.isEmpty else {
            os_log(.info, log: log, "No upcoming alarm within 8h; not starting Smart Wake")
            SmartWakeDebugLog.log("START attempt: declined â€” no enabled alarm within 8h (alarms: \(coordinator.alarms.count))")
            return
        }

        let nextFire = upcoming.compactMap { coordinator.occurrence(for: $0.id)?.effectiveDate }.min()?.formatted(date: .omitted, time: .shortened) ?? "?"
        SmartWakeDebugLog.log("START: keeping app alive; next alarm \(nextFire); upcoming count \(upcoming.count)")
        await startBackgroundAudio()
    }

    /// Public foreground-ready entry: same guard as startIfAlarmArmedInternal but
    /// safe to call from foreground at any time (returns immediately if already running).
    /// Called from ContentView when coordinator becomes available or app becomes inactive.
    func startIfReadyForeground() async {
        // Same guard as startIfAlarmArmedInternal, but safe to call from foreground
        guard let coordinator = self.coordinator else {
            SmartWakeDebugLog.log("FOREGROUND START attempt: NO coordinator â€” cannot check alarms")
            return
        }
        
        // Already running?
        if isRunning {
            SmartWakeDebugLog.log("FOREGROUND START: silent loop already running")
            return
        }
        
        let now = Date()
        let soon = now.addingTimeInterval(8 * 3600) // Within next 8 hours
        
        // Check if any alarm is armed and due soon
        let upcoming = coordinator.alarms.filter { alarm in
            guard alarm.isEnabled else { return false }
            if let occurrence = coordinator.occurrence(for: alarm.id) {
                return occurrence.effectiveDate <= soon && occurrence.effectiveDate > now
            }
            return false
        }
        
        guard !upcoming.isEmpty else {
            SmartWakeDebugLog.log("FOREGROUND START attempt: declined â€” no enabled alarm within 8h (alarms: \(coordinator.alarms.count))")
            return
        }
        
        let nextFire = upcoming.compactMap { coordinator.occurrence(for: $0.id)?.effectiveDate }.min()?.formatted(date: .omitted, time: .shortened) ?? "?"
        SmartWakeDebugLog.log("FOREGROUND START: silent loop active before backgrounding; next alarm \(nextFire); upcoming count \(upcoming.count)")
        await startBackgroundAudio()
    }

    /// Start the silent background audio loop
    private func startBackgroundAudio() async {
        guard let url = silentLoopURL else {
            os_log(.error, log: log, "Silent loop URL not set")
            SmartWakeDebugLog.log("START BACKGROUND: silentLoopURL is nil")
            return
        }
        
        // Wait for file if generation is still in progress
        var attempts = 0
        while !fileManager.fileExists(atPath: url.path) && attempts < 10 {
            SmartWakeDebugLog.log("START BACKGROUND: waiting for silent loop file (attempt \(attempts+1)/10)")
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
        
        guard fileManager.fileExists(atPath: url.path) else {
            os_log(.error, log: log, "Silent loop file not ready after waiting")
            SmartWakeDebugLog.log("START BACKGROUND: silent loop file not ready after 5s wait â€” giving up")
            return
        }

        // Early exit if already running (foreground start succeeded, then background transition)
        if isRunning {
            SmartWakeDebugLog.log("FOREGROUND: loop already running, nothing to do")
            return
        }

        do {
            try await configureAudioSession()
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.numberOfLoops = -1 // Loop indefinitely
            newPlayer.volume = 0.001 // Near-silent
            newPlayer.prepareToPlay()
            guard newPlayer.play() else {
                os_log(.error, log: log, "Failed to start silent loop playback")
                SmartWakeDebugLog.log("START BACKGROUND: play() returned false")
                return
            }
            player = newPlayer
            isSessionActive = true
            os_log(.info, log: log, "Smart Wake silent loop started")
            SmartWakeDebugLog.log("SILENT LOOP started (session active)")

            // Register for interruption notifications
            registerForInterruptions()
            
            // Start transition arming task
            startTransitionArming()
        } catch {
            let nsError = error as NSError
            let scenePhase = UIApplication.shared.applicationState
            let sceneDesc: String
            switch scenePhase {
            case .active: sceneDesc = "foregroundActive"
            case .inactive: sceneDesc = "inactive"
            case .background: sceneDesc = "background"
            @unknown default: sceneDesc = "unknown"
            }
            os_log(.error, log: log, "Failed to start background audio: %{public}s (domain=%{public}s code=%{public}d) scene=%{public}s", error.localizedDescription, nsError.domain, nsError.code, sceneDesc)
            SmartWakeDebugLog.log("START BACKGROUND ERROR: \(error.localizedDescription) (domain=\(nsError.domain) code=\(nsError.code)) scene=\(sceneDesc)")
        }
    }

    private func configureAudioSession() async throws {
        try await activateAudioSession()
    }
    
    private func activateAudioSession() async throws {
        let session = AVAudioSession.sharedInstance()
        let scenePhase = UIApplication.shared.applicationState
        let sceneDesc: String
        switch scenePhase {
        case .active: sceneDesc = "foregroundActive"
        case .inactive: sceneDesc = "inactive"
        case .background: sceneDesc = "background"
        @unknown default: sceneDesc = "unknown"
        }
        
        // Set category with .mixWithOthers to allow activation in background
        // This is required for Smart Wake to work when app is backgrounded
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        
        // Retry activation up to 3 times
        var attempt = 0
        var lastError: Error?
        
        while attempt < 3 {
            attempt += 1
            do {
                try session.setActive(true)
                os_log(.info, log: log, "Audio session activated successfully (attempt %{public}d) scene=%{public}s", attempt, sceneDesc)
                SmartWakeDebugLog.log("AUDIO SESSION active (attempt \(attempt)) scene=\(sceneDesc)")
                return // Success
            } catch {
                lastError = error
                let nsError = error as NSError
                SmartWakeDebugLog.log("ACTIVATION attempt \(attempt) failed: \(error.localizedDescription) (domain=\(nsError.domain) code=\(nsError.code)) scene=\(sceneDesc)")
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay before retry
                }
            }
        }
        
        // All attempts failed
        if let error = lastError {
            let nsError = error as NSError
            SmartWakeDebugLog.log("ACTIVATION all attempts failed (domain=\(nsError.domain) code=\(nsError.code)) scene=\(sceneDesc)")
            throw error
        } else {
            throw NSError(domain: "SmartWake", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audio session activation failed after 3 attempts"])
        }
    }

    /// Stop the background audio session
    func stop() {
        statusTickTask?.cancel()
        statusTickTask = nil
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
        SmartWakeDebugLog.log("SILENT LOOP stopped (user toggled OFF)")
    }

    /// Stop only the silent player, keeping the audio session active and observers registered
    /// Used when transitioning to real alarm playback
    func stopSilentPlayerOnly(reason: String = "transition to in-app playback") {
        os_log(.info, log: log, "stopSilentPlayerOnly() called - stopping silent loop, keeping session active (reason: %{public}s)", reason)
        SmartWakeDebugLog.log("SILENT LOOP stopped (\(reason))")
        player?.stop()
        player = nil
        isSessionActive = false
        // Do NOT deactivate audio session
        // Do NOT unregister for interruptions/route changes
    }

    @MainActor private func logInterruptionBegan(reason: UInt? = nil) {
        os_log(.info, log: log, "Audio interruption began")
        
        let reasonString = reason != nil ? "\(reason!)" : "unknown"
        let wasSuspended = !AVAudioSession.sharedInstance().isOtherAudioPlaying
        
        SmartWakeDebugLog.log("INTERRUPTION began reason=\(reasonString) wasSuspended=\(wasSuspended)")
    }
    
    @MainActor private func logInterruptionEnded(options: AVAudioSession.InterruptionOptions) {
        os_log(.info, log: log, "Audio interruption ended, shouldResume: %{public}d", options.contains(.shouldResume) ? 1 : 0)
        SmartWakeDebugLog.log("INTERRUPTION ended options=\(options.rawValue) shouldResume=\(options.contains(.shouldResume))")
    }


    @MainActor private func logRouteChange(reason: AVAudioSession.RouteChangeReason) {
        os_log(.info, log: log, "Audio route changed: %{public}d", reason.rawValue)
    }

    @MainActor private func handleInterruptionEnded(shouldResume: Bool) {
        if shouldResume {
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.play()
        } else {
            // Interruption ended without resume â€” re-arm check in case we need to restart
            if isSmartWakeEnabled {
                Task { 
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await checkAndArmUpcomingAlarms()
                    SmartWakeDebugLog.log("RE-ARM scheduled after interruption (no resume)")
                }
            }
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
            // Get the reason if available
            let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt
            let reasonString = reasonValue != nil ? "\(reasonValue!)" : "unknown"
            let wasSuspended = !AVAudioSession.sharedInstance().isOtherAudioPlaying
            SmartWakeDebugLog.log("INTERRUPTION began reason=\(reasonString) wasSuspended=\(wasSuspended)")
            
            logInterruptionBegan(reason: reasonValue)
            // Log interruption affecting playback if AlarmPlaybackService is playing
            if AlarmPlaybackService.shared.isPlaying {
                SmartWakeDebugLog.log("PLAYBACK: audio session interrupted (reason: began)")
            }
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            logInterruptionEnded(options: options)
            SmartWakeDebugLog.log("INTERRUPTION ended options=\(options.rawValue) shouldResume=\(options.contains(.shouldResume))")
            if options.contains(.shouldResume) {
                handleInterruptionEnded(shouldResume: true)
            } else {
                // Interruption ended without resume - log for playback visibility
                if AlarmPlaybackService.shared.isPlaying {
                    SmartWakeDebugLog.log("PLAYBACK: audio session interrupted (reason: ended without resume)")
                }
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
    func checkAndArmUpcomingAlarms() async {
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
            
            // Find ALL unskipped occurrences within the ring window
            let desiredOccurrences = engine.desiredOccurrences(now: now, perAlarmLimit: 5)
            let upcomingOccurrences = desiredOccurrences.filter { occ in
                occ.effectiveDate > now && occ.effectiveDate <= ringWindowEnd
            }
            
            guard !upcomingOccurrences.isEmpty else {
                os_log(.info, log: log, "No upcoming occurrences in ring window")
                return
            }
            
            // Arm EVERY upcoming occurrence with 0 < timeToFire <= 60 that is not already armed
            for occurrence in upcomingOccurrences {
                let timeToFire = occurrence.effectiveDate.timeIntervalSince(now)
                let occurrenceKey = occurrence.occurrenceKey
                let alarmID = occurrence.alarmID
                let armingKey = makeArmingKey(alarmID: alarmID, occurrenceKey: occurrenceKey, effectiveDate: occurrence.effectiveDate)
                
                guard timeToFire > 0 && timeToFire <= 60 && !armedOccurrences.contains(armingKey) else {
                    continue
                }
                
                armedOccurrences.insert(armingKey)
                os_log(.info, log: log, "ARMING %@ %@ fire in %.1fs", String(alarmID.uuidString.prefix(8)), occurrenceKey, timeToFire)
                SmartWakeDebugLog.log("ARMING \(alarmID.uuidString.prefix(8)) \(occurrenceKey) fire in \(Int(timeToFire))s")
                
                // Schedule precise wake at fire time
                scheduleTransitionWake(for: occurrence, snapshot: snapshot, engine: engine)
            }
            
            // Clean up old armed occurrences (past fire time + tolerance)
            let cleanupThreshold = now.addingTimeInterval(-10) // 10 seconds past
            let keysToRemove = armedOccurrences.filter { key in
                // Parse the composite key: "alarmID_prefix|effectiveDate_timestamp"
                let components = key.split(separator: "|")
                guard components.count == 2 else { return true } // Remove if malformed
                let alarmIDString = String(components[0])
                let timestampString = String(components[1])
                guard let effectiveDateTimestamp = Int(timestampString) else { return true }
                let effectiveDate = Date(timeIntervalSince1970: TimeInterval(effectiveDateTimestamp))
                
                // Find the occurrence for this key and check if it's past
                if let occ = desiredOccurrences.first(where: { 
                    $0.alarmID.uuidString.prefix(8) == alarmIDString && $0.effectiveDate == effectiveDate
                }) {
                    return occ.effectiveDate < cleanupThreshold
                }
                return true // Remove if not found
            }
            armedOccurrences.subtract(keysToRemove)
            
        } catch {
            os_log(.error, log: log, "Failed to check upcoming alarms: %{public}s", error.localizedDescription)
        }
    }
    
    /// Cancel the coordinator-scheduled -BACKUP alarm for this occurrence (computed the
    /// same way AlarmCoordinator builds its SystemScheduleID) plus any AlarmKit alarm
    /// still alerting.
    func cancelScheduledAlarms(forAlarmID alarmID: UUID, backupOccurrence: AlarmOccurrence, label: String, sound: AlarmSound, loudness: AlarmLoudness, selectionHash: String?) {
        let backupSystemID = SystemScheduleID.make(
            for: backupOccurrence,
            label: label,
            sound: sound,
            loudness: loudness,
            selectionHash: selectionHash
        )
        do {
            try AlarmManager.shared.cancel(id: backupSystemID)
            SmartWakeDebugLog.log("BACKUP ALARM cancelled id=\(backupSystemID.uuidString)")
        } catch {
            SmartWakeDebugLog.log("BACKUP ALARM cancel FAILED: \(error.localizedDescription)")
        }
        let kitAlarms = (try? AlarmManager.shared.alarms) ?? []
        for kitAlarm in kitAlarms where kitAlarm.state == .alerting {
            try? AlarmManager.shared.cancel(id: kitAlarm.id)
            SmartWakeDebugLog.log("SILENCE: cancelled alerting alarm \(kitAlarm.id.uuidString)")
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
            
            // Verify it's still the right time (Â±5s tolerance)
            let actualNow = Date()
            let tolerance: TimeInterval = 5.0
            if abs(actualNow.timeIntervalSince(fireDate)) > tolerance {
                os_log(.info, log: log, "Missed fire window for %{public}s (diff: %{public}.1fs)",
                       occurrenceKey, actualNow.timeIntervalSince(fireDate))
                SmartWakeDebugLog.log("TRANSITION WAKE MISSED WINDOW for \(occurrenceKey) (diff \(Int(actualNow.timeIntervalSince(fireDate)))s)")
                return
            }
            
            // WAKE DUPLICATE GUARD: one wake run per alarm+occurrence (two alarms may share a minute)
            // Key format: "alarmID|effectiveDate_timestamp" to uniquely identify each fire time
            let effectiveTimestamp = Int(occurrence.effectiveDate.timeIntervalSince1970)
            let wakeKey = "\(occurrence.alarmID.uuidString)|\(effectiveTimestamp)"
            if firedTransitionWakes.contains(wakeKey) {
                os_log(.info, log: log, "WAKE DUPLICATE ignored for %{public}s", wakeKey)
                SmartWakeDebugLog.log("WAKE DUPLICATE ignored for \(wakeKey)")
                return
            }
            firedTransitionWakes.insert(wakeKey)
            
            os_log(.info, log: log, "TRANSITION WAKE: Firing for occurrence %{public}s at %{public}s", 
                   occurrenceKey, actualNow.formatted(date: .omitted, time: .standard))
            SmartWakeDebugLog.log("TRANSITION WAKE fired for \(occurrenceKey)")
            SmartWakeDebugLog.log("WAKE STATE: loopRunning=\(isRunning) silentPlayerPlaying=\(player?.isPlaying == true)")
            
            // Find the alarm for this occurrence
            guard let alarm = engine.alarm(id: occurrence.alarmID) else {
                os_log(.error, log: log, "Alarm not found for occurrence %{public}s", occurrenceKey)
                SmartWakeDebugLog.log("TAKEOVER ABORT: alarm record not found for \(occurrenceKey)")
                return
            }
            
            // Resolve the sound for this occurrence using the same logic as scheduling
            do {
                let (soundToUse, _) = try resolveSoundForOccurrence(alarm: alarm, occurrence: occurrence, engine: engine)
                
                // Determine if it's a playlist (random/precomposedPlaylist) or single imported sound
                if isPlaylistSound(soundToUse) {
                    // PHASE 7: Playlist-first with delayed backup alarm
                    // Start playlist immediately (silent loop already running)
                    // The backup alarm is scheduled by AlarmCoordinator as a -BACKUP occurrence
                    SmartWakeDebugLog.log("PLAYLIST-FIRST: starting playlist for \(occurrenceKey)")

                    // Build the -BACKUP occurrence for cancel (same shape as AlarmCoordinator)
                    let backupOccurrenceForCancel = AlarmOccurrence(
                        alarmID: alarm.id,
                        occurrenceKey: "\(occurrenceKey)-BACKUP",
                        baseDate: occurrence.baseDate,
                        effectiveDate: occurrence.effectiveDate.addingTimeInterval(30),
                        isAdjusted: false
                    )

                    if AlarmPlaybackService.shared.isPlaying {
                        // TAKEOVER SHARED: another same-minute alarm already owns playback.
                        // Keep its playlist running; drop ONLY our own backup alarms.
                        SmartWakeDebugLog.log("TAKEOVER SHARED: playback owner active; cancelling backups for \(occurrenceKey)")
                        cancelScheduledAlarms(
                            forAlarmID: alarm.id,
                            backupOccurrence: backupOccurrenceForCancel,
                            label: alarm.label.isEmpty ? "Alarm" : alarm.label,
                            sound: soundToUse,
                            loudness: alarm.loudness,
                            selectionHash: desiredSelectionHash(for: soundToUse)
                        )
                        return
                    }

                    if case .precomposedPlaylist(let resolvedPlaylistID, _) = soundToUse {
                        os_log(.info, log: log, "PLAYLIST-FIRST: starting playlist %{public}s", resolvedPlaylistID.uuidString)
                        SmartWakeDebugLog.log("PLAYLIST-FIRST: starting in-app playlist playback (\(resolvedPlaylistID.uuidString))")
                        AlarmPlaybackService.shared.start(
                            playlistID: resolvedPlaylistID,
                            loudness: alarm.loudness,
                            alarm: alarm,
                            occurrence: occurrence
                        )
                    }
                    
                    // Wait up to 1s for playback to actually start
                    var playbackStarted = false
                    for attempt in 0..<10 {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        if AlarmPlaybackService.shared.isPlaying {
                            playbackStarted = true
                            break
                        }
                    }
                    
                    if playbackStarted {
                        SmartWakeDebugLog.log("PLAYLIST-FIRST SUCCESS: playback confirmed, cancelling backup alarm")
                        // Cancel the backup alarm using its SystemScheduleID (same as AlarmCoordinator creates)
                        let backupOccurrenceKey = "\(occurrenceKey)-BACKUP"
                        let backupOccurrence = AlarmOccurrence(
                            alarmID: alarm.id,
                            occurrenceKey: backupOccurrenceKey,
                            baseDate: occurrence.baseDate,
                            effectiveDate: occurrence.effectiveDate.addingTimeInterval(30),
                            isAdjusted: false
                        )
                        cancelScheduledAlarms(
                            forAlarmID: alarm.id,
                            backupOccurrence: backupOccurrenceForCancel,
                            label: alarm.label.isEmpty ? "Alarm" : alarm.label,
                            sound: soundToUse,
                            loudness: alarm.loudness,
                            selectionHash: desiredSelectionHash(for: soundToUse)
                        )
                        
                        // Promote to primary session for lock screen controls (if not foreground)
                        AlarmPlaybackService.shared.promoteToPrimarySessionIfNeeded()
                        stopSilentPlayerOnly(reason: "playlist-first takeover completed for \(occurrenceKey)")
                        SmartWakeDebugLog.log("PLAYLIST-FIRST complete for \(occurrenceKey); silent player stopped")
                    } else {
                        // ATTEMPT A FAILED - log and remove occurrence key to allow retry
                        os_log(.error, log: log, "TAKEOVER ATTEMPT-A FAILED: playback failed to start, leaving AlarmKit alarms ringing")
                        SmartWakeDebugLog.log("TAKEOVER ATTEMPT-A FALLBACK: playback failed, AlarmKit alarms left ringing")
                        // Remove from isArmedForOccurrence so we can retry
                        let armingKey = makeArmingKey(alarmID: alarm.id, occurrenceKey: occurrenceKey)
                        armedOccurrences.remove(armingKey)
                        
                        // ATTEMPT B: Cancel ALL alerting alarms first, then reclaim session and retry
                        SmartWakeDebugLog.log("TAKEOVER RETRY-B: cancelling alerting alarms then reclaiming session")
                        
                        // Cancel ALL alerting AlarmKit alarms
                        let alerting = (try? AlarmManager.shared.alarms.filter { $0.state == .alerting }) ?? []
                        var allCancelled = true
                        for kitAlarm in alerting {
                            do {
                                try AlarmManager.shared.cancel(id: kitAlarm.id)
                                SmartWakeDebugLog.log("SILENCE: cancelled alerting alarm \(kitAlarm.id.uuidString)")
                            } catch {
                                allCancelled = false
                                SmartWakeDebugLog.log("SILENCE: cancel FAILED for \(kitAlarm.id.uuidString): \(error.localizedDescription)")
                            }
                        }
                        os_log(.info, log: log, "Cancelled %d alerting alarm(s), allCancelled=%{public}d", alerting.count, allCancelled ? 1 : 0)
                        
                        // Stop silent player to reclaim session
                        stopSilentPlayerOnly(reason: "retry-B reclaim session")
                        
                        // Up to 3 retry attempts
                        var retryBSuccess = false
                        for retryAttempt in 1...3 {
                            SmartWakeDebugLog.log("TAKEOVER RETRY-B ATTEMPT \(retryAttempt)/3")
                            
                            // Ensure audio session is active (reclaim)
                            do {
                                try AlarmPlaybackService.shared.ensureAudioSessionActive()
                                AlarmPlaybackService.shared.logSessionDump("RETRY-B attempt \(retryAttempt) pre-start")
                            } catch {
                                SmartWakeDebugLog.log("RETRY-B attempt \(retryAttempt): session activation FAILED: \(error.localizedDescription)")
                                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
                                continue
                            }
                            
                            // Start playback
                            if case .precomposedPlaylist(let resolvedPlaylistID, _) = soundToUse {
                                AlarmPlaybackService.shared.start(
                                    playlistID: resolvedPlaylistID,
                                    loudness: alarm.loudness,
                                    alarm: alarm,
                                    occurrence: occurrence
                                )
                            }
                            
                            // Wait 500ms for isPlaying
                            var playbackStarted = false
                            for attempt in 0..<10 {
                                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                                if AlarmPlaybackService.shared.isPlaying {
                                    playbackStarted = true
                                    break
                                }
                            }
                            
                            if playbackStarted {
                                retryBSuccess = true
                                break
                            } else {
                                AlarmPlaybackService.shared.logSessionDump("RETRY-B attempt \(retryAttempt) play() FALSE")
                                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
                            }
                        }
                        
                        if retryBSuccess {
                            SmartWakeDebugLog.log("TAKEOVER RETRY-B SUCCESS: playback confirmed after retry")
                            // Promote to primary session for lock screen controls (if not foreground)
                            AlarmPlaybackService.shared.promoteToPrimarySessionIfNeeded()
                            // Setup local notification with Stop action
                            AlarmPlaybackService.shared.setupStopNotification(alarm: alarm, occurrence: occurrence)
                            stopSilentPlayerOnly(reason: "retry-B takeover completed for \(occurrenceKey)")
                            SmartWakeDebugLog.log("TAKEOVER RETRY-B complete for \(occurrenceKey); silent player stopped")
                        } else {
                            // RETRY B FAILED - NEVER leave silence, schedule emergency re-ring
                            os_log(.error, log: log, "TAKEOVER RETRY-B FAILED: all 3 retries exhausted, scheduling emergency re-ring")
                            SmartWakeDebugLog.log("TAKEOVER RETRY-B FAILED: all 3 retries exhausted, scheduling emergency re-ring")
                            
                            // Schedule emergency AlarmKit alarm ~3s in future using existing scheduling path
                            let emergencyFireDate = Date().addingTimeInterval(3.0)
                            do {
                                // Reuse existing scheduling code path - create a one-off alarm
                                let emergencyID = UUID()
                                let emergencyConfig = AlarmManager.AlarmConfiguration<ScheduledOccurrenceMetadata>(
                                    countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: 0),
                                    schedule: .fixed(emergencyFireDate),
                                    attributes: AlarmAttributes(
                                        presentation: AlarmPresentation(
                                            alert: AlarmPresentation.Alert(
                                                title: LocalizedStringResource(stringLiteral: "Emergency Re-ring"),
                                                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle.fill"),
                                                secondaryButton: AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz"),
                                                secondaryButtonBehavior: .countdown
                                            ),
                                            countdown: AlarmPresentation.Countdown(title: LocalizedStringResource(stringLiteral: "Snoozed 10 min")),
                                            paused: AlarmPresentation.Paused(title: LocalizedStringResource(stringLiteral: "Snoozed 10 min"), resumeButton: AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.circle.fill"))
                                        ),
                                        metadata: ScheduledOccurrenceMetadata(
                                            alarmID: alarm.id,
                                            occurrenceKey: "EMERGENCY-\(occurrenceKey)",
                                            baseDate: emergencyFireDate
                                        ),
                                        tintColor: .red
                                    ),
                                    stopIntent: nil,
                                    secondaryIntent: nil,
                                    sound: (try? await AlarmCoordinator.sharedInstance?.alarmKitSound(for: alarm.sound, loudness: alarm.loudness)) ?? .default
                                )
                                _ = try await AlarmManager.shared.schedule(id: emergencyID, configuration: emergencyConfig)
                                SmartWakeDebugLog.log("EMERGENCY RE-RING scheduled id=\(emergencyID.uuidString) at \(emergencyFireDate)")
                                // Register emergency ID with coordinator so it's not cancelled as orphan
                                AlarmCoordinator.sharedInstance?.addEmergencyReRingID(emergencyID)
                            } catch {
                                SmartWakeDebugLog.log("EMERGENCY RE-RING scheduling FAILED: \(error.localizedDescription)")
                                os_log(.error, log: log, "EMERGENCY RE-RING scheduling FAILED: %{public}s", error.localizedDescription)
                            }
                        }
                    }
                    
                    // Re-arm check: if there's another alarm coming up, restart the silent loop
                    Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        await checkAndArmUpcomingAlarms()
                        SmartWakeDebugLog.log("RE-ARM scheduled after takeover completion")
                    }
                } else {
                    os_log(.info, log: log, "Sound type %{public}s - AlarmKit handles playback", String(describing: soundToUse))
                    SmartWakeDebugLog.log("TAKEOVER skipped: non-playlist sound (AlarmKit plays it): \(String(describing: soundToUse))")
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
    
    static func isPlaylistSound(_ sound: AlarmSound) -> Bool {
        switch sound {
        case .precomposedPlaylist: return true
        case .random: return true
        default: return false
        }
    }
    
    /// Start observing native AlarmKit alarm for Stop/Snooze detection (NATIVE-FIRST path)
    /// State machine: (previous, current) -> action
    /// - .scheduled -> ignore
    /// - .alerting -> log once
    /// - .alerting -> .gone (Stop): wait 300ms, ensure mixable session, start in-app playback
    /// - .alerting -> .countdown (Snooze): log, do nothing (AlarmKit re-rings)
    /// - .alerting -> .paused -> ignore
    /// - .countdown -> ignore
    private func startNativeAlarmObservation(alarm: AlarmRecord, occurrence: AlarmOccurrence) {
        let alarmKitID = SystemScheduleID.make(
            for: occurrence,
            label: alarm.label.isEmpty ? "Alarm" : alarm.label,
            sound: alarm.sound,
            loudness: alarm.loudness
        )
        
        var previousState: Alarm.State? = nil
        var hasLoggedAlerting = false
        var stopHandled = false
        
        Task { @MainActor in
            for await alarms in AlarmManager.shared.alarmUpdates {
                guard let nativeAlarm = alarms.first(where: { $0.id == alarmKitID }) else {
                    // Native alarm gone - could be Stop
                    if let prev = previousState, prev == .alerting && !stopHandled {
                        SmartWakeDebugLog.log("NATIVE STOP detected for \(occurrence.occurrenceKey)")
                        stopHandled = true
                        
                        // Wait 300ms then start in-app playback
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        
                        // Ensure mixable audio session (as retry-B does)
                        do {
                            try AlarmPlaybackService.shared.ensureAudioSessionActive()
                            
                            // Start in-app playback for this alarm's playlist
                            if case .precomposedPlaylist(let resolvedPlaylistID, _) = alarm.sound {
                                AlarmPlaybackService.shared.start(
                                    playlistID: resolvedPlaylistID,
                                    loudness: alarm.loudness,
                                    alarm: alarm,
                                    occurrence: occurrence
                                )
                            }
                            
                            // Wait up to 1s for playback to start
                            var playbackStarted = false
                            for attempt in 0..<10 {
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                if AlarmPlaybackService.shared.isPlaying {
                                    playbackStarted = true
                                    break
                                }
                            }
                            
                            if playbackStarted {
                                SmartWakeDebugLog.log("CONTINUE-AFTER-STOP SUCCESS for \(occurrence.occurrenceKey)")
                                // Publish lock-screen controls (existing code)
                                AlarmPlaybackService.shared.setupStopNotification(alarm: alarm, occurrence: occurrence)
                                // Note: we don't stop silent player here - it's already running
                                // Ensure Smart Wake re-arms
                                Task {
                                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                                    await checkAndArmUpcomingAlarms()
                                    SmartWakeDebugLog.log("REARM after native stop")
                                }
                            } else {
                                // Retry up to 3 times at 250ms
                                for retry in 1...3 {
                                    try? await Task.sleep(nanoseconds: 250_000_000)
                                    if AlarmPlaybackService.shared.isPlaying {
                                        SmartWakeDebugLog.log("CONTINUE-AFTER-STOP SUCCESS (retry \(retry)) for \(occurrence.occurrenceKey)")
                                        AlarmPlaybackService.shared.setupStopNotification(alarm: alarm, occurrence: occurrence)
                                        break
                                    }
                                }
                                SmartWakeDebugLog.log("CONTINUE-AFTER-STOP FAILED for \(occurrence.occurrenceKey)")
                            }
                        } catch {
                            SmartWakeDebugLog.log("CONTINUE-AFTER-STOP FAILED code=\((error as NSError).code) for \(occurrence.occurrenceKey)")
                        }
                    }
                    return
                }
                
                let currentState = nativeAlarm.state
                
                // Only log alerting once
                if currentState == .alerting && !hasLoggedAlerting {
                    SmartWakeDebugLog.log("NATIVE alarm alerting: \(alarmKitID.uuidString.prefix(8))")
                    hasLoggedAlerting = true
                }
                
                // Detect Snooze
                if previousState == .alerting && currentState == .countdown {
                    SmartWakeDebugLog.log("NATIVE SNOOZE for \(occurrence.occurrenceKey)")
                    // AlarmKit handles re-ring, do nothing
                    // Ensure Smart Wake re-arms
                    Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        await checkAndArmUpcomingAlarms()
                        SmartWakeDebugLog.log("REARM after native snooze")
                    }
                    return
                }
                
                previousState = currentState
                
                // Ignore .scheduled, .paused, .countdown (unless from alerting)
            }
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
            for attempt in 0..<10 {
                alerting = try AlarmManager.shared.alarms.filter { $0.state == .alerting }
                if !alerting.isEmpty { break }
                if attempt < 9 { try? await Task.sleep(nanoseconds: 300_000_000) }
            }
        } catch {
            os_log(.error, log: log, "Failed to inspect AlarmKit alarms: %{public}s", error.localizedDescription)
            SmartWakeDebugLog.log("SILENCE: AlarmKit access threw: \(error.localizedDescription)")
            return false
        }
        guard !alerting.isEmpty else {
            os_log(.info, log: log, "No alerting AlarmKit alarm appeared within 3s; skipping takeover")
            SmartWakeDebugLog.log("SILENCE: no .alerting alarm found within 3s of wake â€” takeover skipped (system sound may start later)")
            return false
        }
        var allCancelled = true
        for kitAlarm in alerting {
            do {
                // cancel() is the API proven in this codebase (all reconcile
                // paths); on an alerting alarm it removes it and silences the
                // sound. AlarmManager.stop(id:) is documented but unverified
                // here â€” only switch if cancel fails on device.
                try AlarmManager.shared.cancel(id: kitAlarm.id)
                SmartWakeDebugLog.log("SILENCE: cancelled alerting alarm \(kitAlarm.id.uuidString)")
            } catch {
                allCancelled = false
                SmartWakeDebugLog.log("SILENCE: cancel FAILED for \(kitAlarm.id.uuidString): \(error.localizedDescription)")
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
