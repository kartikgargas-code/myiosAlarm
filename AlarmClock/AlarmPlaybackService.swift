import Foundation
import AVFoundation
import MediaPlayer
import Observation
import os.log
import AlarmKit
import AlarmClockShared
import UIKit
@preconcurrency import UserNotifications

/// Alarm playback service for playing selected local playlist tracks at alarm fire time.
/// Integrates with system Now Playing and remote command center for lock screen control.
@MainActor
@Observable
final class AlarmPlaybackService: NSObject {
    static let shared = AlarmPlaybackService()

    private let log = OSLog(subsystem: "com.example.alarmclock", category: "AlarmPlayback")
    private let fileManager = FileManager.default

    private var player: AVAudioPlayer?
    private var currentPlaylistID: UUID?
    private var currentLoudness: AlarmLoudness?
    private var currentAlarmID: UUID? // Snapshot of the alarm ID at takeover start
    private var currentAlarm: AlarmRecord?
    private var currentOccurrence: AlarmOccurrence?
    private var currentTrackIndex = 0
    private var selectedSoundIDs: [UUID] = []
    private weak var coordinator: AlarmCoordinator?
    // Track armed occurrences to prevent double-start using composite keys: "alarmID|occurrenceKey"
    private var isArmedForOccurrence: Set<String> = []
    private var transitionCheckTask: Task<Void, Never>?
    private var consecutiveFailures = 0 // Track consecutive play failures to prevent infinite recursion
    
    // Resume state (no companion)
    private var resumeAttempts = 0
    private var maxResumeAttempts = 3
    
    // Remote command state
    private var pendingBackupAlarmID: UUID?
    private var pendingSnoozeAlarmID: UUID?
    // 1-second dedupe gates for remote commands
    private var lastStopCommandTime: Date?
    private var lastSnoozeCommandTime: Date?
    
    // Published state
    private(set) var isPlaying = false
    private(set) var currentTrackName: String?
    private(set) var lastError: String?
    private var lastSessionDump: String = ""

    private override init() {
        super.init()
        os_log(.info, log: log, "AlarmPlaybackService initialized")
        registerForInterruptions()
    }
    
    /// Register for audio session interruption notifications
    private func registerForInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt ?? 0
            SmartWakeDebugLog.log("AVAUDIOSESSION INTERRUPTION began reason=\(reasonValue)")
            SmartWakeDebugLog.log("PLAYBACK INTERRUPTED")
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            SmartWakeDebugLog.log("INTERRUPTION ended options=\(options.rawValue) shouldResume=\(options.contains(.shouldResume))")
            
            // If playback should resume, or if it's supposed to be playing but isn't (2s tick fallback)
            if options.contains(.shouldResume) || (isPlaying && player?.isPlaying != true) {
                attemptPlaybackResume()
            }
        @unknown default:
            break
        }
    }

    /// Start playback for the given alarm occurrence
    /// - Parameters:
    ///   - playlistID: The playlist ID to play from
    ///   - loudness: The alarm loudness setting
    ///   - alarm: The alarm record
    ///   - occurrence: The alarm occurrence being fired
    func start(
        playlistID: UUID,
        loudness: AlarmLoudness,
        alarm: AlarmRecord,
        occurrence: AlarmOccurrence
    ) {
        os_log(.info, log: log, "start(playlistID:%{public}s, loudness:%{public}d%%, alarmID:%{public}s, occurrenceKey:%{public}s)",
               playlistID.uuidString, loudness.percentage, alarm.id.uuidString, occurrence.occurrenceKey)
        SmartWakeDebugLog.log("PLAYBACK start attempt playlist=\(playlistID.uuidString.prefix(8))")
        
        // Guard against double-start for same occurrence using composite key
        let armingKey = "\(alarm.id.uuidString.prefix(8))|\(occurrence.occurrenceKey)"
        guard !isArmedForOccurrence.contains(armingKey) else {
            os_log(.info, log: log, "Already armed for occurrence %{public}s, skipping", occurrence.occurrenceKey)
            return
        }
        isArmedForOccurrence.insert(armingKey)

        // Reset consecutive failures on new start
        consecutiveFailures = 0

        // Resolve playlist and selected sound IDs
        do {
            let playlist = try SoundLibrary.shared.playlist(for: playlistID)
            var soundIDs = playlist.selectedSoundIDs
            
            // Randomize track order if playlist is set to random play order
            if playlist.playOrder == .random {
                soundIDs.shuffle()
            }
            selectedSoundIDs = soundIDs
            
            guard !selectedSoundIDs.isEmpty else {
                throw SoundLibraryError.emptyPlaylist(playlistID)
            }
            
            currentPlaylistID = playlistID
            currentLoudness = loudness
            currentAlarmID = alarm.id // Snapshot the alarm ID for validation
            currentAlarm = alarm
            currentOccurrence = occurrence
            currentTrackIndex = 0
            coordinator = AlarmCoordinator.sharedInstance // Will need access to coordinator for play history
            
            // Compute and store the backup alarm SystemScheduleID for remote commands to cancel
            let backupOccurrenceKey = "\(occurrence.occurrenceKey)-BACKUP"
            let backupOccurrence = AlarmOccurrence(
                alarmID: alarm.id,
                occurrenceKey: backupOccurrenceKey,
                baseDate: occurrence.baseDate,
                effectiveDate: occurrence.effectiveDate.addingTimeInterval(30),
                isAdjusted: false
            )
            pendingBackupAlarmID = SystemScheduleID.make(
                for: backupOccurrence,
                label: alarm.label.isEmpty ? "Alarm" : alarm.label,
                sound: alarm.sound,
                loudness: alarm.loudness,
                selectionHash: nil // Selection hash computed in AlarmCoordinator
            )
            
            // Ensure audio session is active (don't deactivate, only activate if needed)
            try ensureAudioSessionActive()
            // Then claim primary session for lock-screen Now Playing visibility
            try activatePrimaryAudioSession()
            
            SmartWakeDebugLog.log("PLAYBACK start attempt playlist=\(playlistID.uuidString.prefix(8)) tracks=\(selectedSoundIDs.count)")
            SmartWakeDebugLog.log("PLAYBACK queued track 1: \(self.selectedSoundIDs.first.map { id in SoundLibrary.shared.importedSounds.first(where: { $0.id == id })?.name ?? "unknown" } ?? "unknown")")
            
            // Start playing the first track
            playTrack(at: 0)
            
        } catch {
            let nsError = error as NSError
            lastError = error.localizedDescription
            os_log(.error, log: log, "Failed to start playback: %{public}s (domain=%{public}s code=%{public}d)", error.localizedDescription, nsError.domain, nsError.code)
            SmartWakeDebugLog.log("PLAYBACK FAILED: \(nsError.domain) code=\(nsError.code) \(error.localizedDescription)")
            let armingKey = "\(alarm.id.uuidString.prefix(8))|\(occurrence.occurrenceKey)"
            isArmedForOccurrence.remove(armingKey)
        }
    }
    
    /// Check if the original alarm still exists and is enabled.
    /// Call this before advancing to the next track or on a timer tick.
    /// Returns true if playback should continue, false if it should stop.
    func validateStillRinging() -> Bool {
        guard let alarmID = currentAlarmID,
              let coordinator = AlarmCoordinator.sharedInstance else {
            os_log(.info, log: log, "PLAYBACK validation: missing alarmID or coordinator, stopping")
            SmartWakeDebugLog.log("PLAYBACK validation: missing alarmID or coordinator, stopping")
            return false
        }
        
        // Check if the alarm still exists and is enabled
        if let alarm = coordinator.alarms.first(where: { $0.id == alarmID }),
           alarm.isEnabled {
            return true
        }
        
        os_log(.info, log: log, "PLAYBACK stopped: alarm disabled/deleted (alarmID: %{public}s)", alarmID.uuidString)
        SmartWakeDebugLog.log("PLAYBACK stopped: alarm disabled/deleted (alarmID: \(alarmID.uuidString.prefix(8)))")
        return false
    }

    /// Ensure the audio session is active (for background playback)
    func ensureAudioSessionActive() throws {
        let session = AVAudioSession.sharedInstance()
        // ALWAYS set category and activate - no shortcuts. isOtherAudioPlaying is true due to AlarmKit sound, not our active session.
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            os_log(.info, log: log, "Audio session activated (mixable)")
            SmartWakeDebugLog.log("PLAYBACK: session activated (mixable)")
        } catch {
            let nsError = error as NSError
            os_log(.error, log: log, "Failed to activate session: %{public}s (domain=%{public}s code=%{public}d)", error.localizedDescription, nsError.domain, nsError.code)
            SmartWakeDebugLog.log("PLAYBACK: session activation FAILED (domain=\(nsError.domain) code=\(nsError.code) desc=\(error.localizedDescription))")
            throw error
        }
    }
    
    /// Log a complete session state dump for debugging
    /// Call at: after play() returns false, after each retry in retry-B, promote failed, activation failed
    /// Do NOT call at start() entry - that's not a failure
    func logSessionDump(_ tag: String) {
        let session = AVAudioSession.sharedInstance()
        let appState = UIApplication.shared.applicationState.rawValue
        let sceneState = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.activationState.rawValue ?? -1
        let silentPlayerRunning = SmartWakeService.shared.isRunning
        
        var dump = "SESSION DUMP [\(tag)]: "
        dump += "cat=\(session.category.rawValue) mode=\(session.mode.rawValue) opts=\(session.categoryOptions.rawValue) "
        dump += "isOtherAudioPlaying=\(session.isOtherAudioPlaying) secondaryAudioShouldBeSilencedHint=\(session.secondaryAudioShouldBeSilencedHint) "
        dump += "outputVolume=\(session.outputVolume) "
        let routeOutputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        dump += "routeOutputs=\(routeOutputs) "
        dump += "silentPlayer=\(silentPlayerRunning) appState=\(appState) sceneState=\(sceneState)"
        
        lastSessionDump = dump
        SmartWakeDebugLog.logSessionDump(dump)
    }
    
    /// Activate primary audio session for lock-screen Now Playing visibility
    /// Called when takeover playback starts - claims primary session ONLY when app is foregroundActive
    /// When backgrounded/locked, keeps mixable posture to avoid 561015905 (nonmixable activation in background)
    private func activatePrimaryAudioSession() throws {
        // Check scene state - only claim primary when foregroundActive
        let scenes = UIApplication.shared.connectedScenes
        let foregroundActive = scenes.compactMap { $0 as? UIWindowScene }.first?.activationState == .foregroundActive
        
        guard foregroundActive else {
            SmartWakeDebugLog.log("PLAYBACK: keep MIXABLE session (scene=\(scenes.compactMap { $0 as? UIWindowScene }.first?.activationState.rawValue ?? -1))")
            return
        }
        
        let session = AVAudioSession.sharedInstance()
        // Claim PRIMARY session (no .mixWithOthers) so iOS shows Now Playing on lock screen
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        os_log(.info, log: log, "Audio session activated as PRIMARY (no mixWithOthers) for lock-screen Now Playing")
        SmartWakeDebugLog.log("PLAYBACK: audio session activated as PRIMARY (scene=foregroundActive)")
    }
    
    /// Restore mixable audio session when playback stops
    /// If Smart Wake's silent loop is running, reactivate with .mixWithOthers
    private func restoreMixableAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        if SmartWakeService.shared.isRunning {
            // Smart Wake's silent loop is running - reactivate with mixWithOthers
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            os_log(.info, log: log, "Audio session restored to MIXABLE for Smart Wake silent loop")
            SmartWakeDebugLog.log("PLAYBACK: audio session restored to MIXABLE for Smart Wake")
        } else {
            // No silent loop running - just ensure category is mixable (don't activate)
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            os_log(.info, log: log, "Audio session category set to MIXABLE (no activation needed)")
            SmartWakeDebugLog.log("PLAYBACK: audio session category set to MIXABLE (no silent loop)")
        }
    }
    
    /// Try to promote to primary (non-mixable) session for lock screen controls.
    /// Only called after playback is confirmed AND scene is NOT foregroundActive.
    /// Best effort - if it fails, we revert to mixable and continue playback.
    func promoteToPrimarySessionIfNeeded() {
        let scenePhase = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.activationState
        
        guard scenePhase != .foregroundActive else {
            SmartWakeDebugLog.log("PRIMARY PROMOTE: already foregroundActive, skipping")
            return
        }
        
        let session = AVAudioSession.sharedInstance()
        
        // Save current player state
        let wasPlaying = player?.isPlaying ?? false
        let currentTime = player?.currentTime ?? 0
        let currentTrack = currentTrackName
        let currentIndex = currentTrackIndex
        
        do {
            logSessionDump("PRIMARY PROMOTE attempt")
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            SmartWakeDebugLog.log("PRIMARY PROMOTE ok")
            logSessionDump("PRIMARY PROMOTE ok")
            
            // Verify player is still playing
            if !(player?.isPlaying ?? false) {
                // Player stopped during promotion - restart current track
                SmartWakeDebugLog.log("PRIMARY PROMOTE: player stopped during promotion, restarting track")
                if let trackName = currentTrack, let index = selectedSoundIDs.firstIndex(where: { soundID in 
                    SoundLibrary.shared.importedSounds.first(where: { $0.id == soundID })?.name == trackName 
                }) {
                    playTrack(at: index)
                }
            }
            
            // Re-publish Now Playing info with playbackState = .playing
            if let trackName = currentTrackName,
               let sound = SoundLibrary.shared.importedSounds.first(where: { $0.name == currentTrackName }),
               let currentPlayer = player {
                let displayTrackName = displayName(for: sound.name)
                publishNowPlayingInfo(for: sound, player: currentPlayer, displayName: displayTrackName)
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
                SmartWakeDebugLog.log("LOCKSCREEN CONTROLS published")
            }
            
        } catch {
            // Revert to mixable session
            SmartWakeDebugLog.log("PRIMARY PROMOTE failed code=\((error as NSError).code) desc=\(error.localizedDescription)")
            logSessionDump("PRIMARY PROMOTE FAILED")
            
            do {
                try restoreMixableAudioSession()
                SmartWakeDebugLog.log("PRIMARY PROMOTE REVERTED")
                
                // Restart current track if it was playing
                if let trackName = currentTrackName, let index = selectedSoundIDs.firstIndex(where: { soundID in 
                    SoundLibrary.shared.importedSounds.first(where: { $0.id == soundID })?.name == currentTrackName 
                }) {
                    playTrack(at: currentTrackIndex)
                }
            } catch {
                SmartWakeDebugLog.log("PRIMARY PROMOTE REVERT failed: \(error.localizedDescription)")
            }
        }
    }
    
    /// Setup local notification with Stop and Snooze actions for background
    func setupStopNotification(alarm: AlarmRecord, occurrence: AlarmOccurrence) {
        let center = UNUserNotificationCenter.current()
        let snoozeMinutes = alarm.snoozeDurationMinutes ?? 10
        
        // Create stop action
        let stopAction = UNNotificationAction(
            identifier: "STOP_ALARM",
            title: "Stop",
            options: [] // No .foreground - runs in background
        )
        
        // Create snooze action
        let snoozeAction = UNNotificationAction(
            identifier: "SNOOZE_ALARM",
            title: "Snooze \(snoozeMinutes) min",
            options: []
        )
        
        // Create category with stop and snooze actions
        let category = UNNotificationCategory(
            identifier: "ALARM_RINGING",
            actions: [stopAction, snoozeAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        
        center.setNotificationCategories([category])
        
        // Request authorization if not already determined
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error = error {
                        SmartWakeDebugLog.log("NOTIFICATION auth error: \(error.localizedDescription)")
                    }
                    SmartWakeDebugLog.log("STOP NOTIFICATION authorization: \(granted ? "granted" : "denied")")
                    if granted {
                        self.postStopNotification(alarm: alarm, occurrence: occurrence)
                    } else {
                        SmartWakeDebugLog.log("STOP NOTIFICATION denied")
                    }
                }
            case .authorized:
                self.postStopNotification(alarm: alarm, occurrence: occurrence)
            case .denied, .provisional, .ephemeral:
                SmartWakeDebugLog.log("STOP NOTIFICATION denied")
            @unknown default:
                SmartWakeDebugLog.log("STOP NOTIFICATION unknown auth status")
            }
        }
    }
    
    private func postStopNotification(alarm: AlarmRecord, occurrence: AlarmOccurrence) {
        let content = UNMutableNotificationContent()
        content.title = alarm.label.isEmpty ? "Alarm" : alarm.label
        let trackName = currentTrackName != nil ? displayName(for: currentTrackName!) : "ringing"
        content.body = "Alarm ringing - \(trackName)"
        content.sound = nil // We handle audio ourselves
        content.categoryIdentifier = "ALARM_RINGING"
        content.interruptionLevel = .active // Not .timeSensitive
        content.userInfo = [
            "alarmID": alarm.id.uuidString,
            "occurrenceKey": occurrence.occurrenceKey
        ]
        
        let request = UNNotificationRequest(
            identifier: "ALARM_RINGING_\(alarm.id.uuidString)_\(occurrence.occurrenceKey)",
            content: content,
            trigger: nil // Fire immediately
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                SmartWakeDebugLog.log("STOP NOTIFICATION post error: \(error.localizedDescription)")
            } else {
                SmartWakeDebugLog.log("STOP NOTIFICATION posted")
            }
        }
    }
    
    /// Remove stop notification when playback stops
    func removeStopNotification(alarmID: UUID, occurrenceKey: String) {
        let identifier = "ALARM_RINGING_\(alarmID.uuidString)_\(occurrenceKey)"
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Play a track at the given index in selectedSoundIDs
    private func playTrack(at index: Int) {
        guard index < selectedSoundIDs.count else {
            // Completed full playlist cycle - loop back to start
            currentTrackIndex = 0
            playTrack(at: 0)
            return
        }

        let soundID = selectedSoundIDs[index]
        guard let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == soundID }) else {
            os_log(.error, log: log, "Sound not found for ID %{public}s, skipping", soundID.uuidString)
            SmartWakeDebugLog.log("PLAYBACK: track \(index) failed - sound not found in library, skipping")
            // Skip broken track, advance to next
            currentTrackIndex = index + 1
            playTrack(at: currentTrackIndex)
            return
        }

        guard let soundsDir = SoundLibrary.shared.soundsDirectory else {
            lastError = "Library/Sounds directory unavailable"
            os_log(.error, log: log, "Sounds directory unavailable")
            return
        }

        let localURL = sound.localURL(soundsDirectory: soundsDir)
        guard let localURL, fileManager.fileExists(atPath: localURL.path) else {
            os_log(.error, log: log, "Sound file missing for %{public}s (%{public}s), skipping", sound.name, sound.fileName)
            SmartWakeDebugLog.log("PLAYBACK: track \(index) failed - file missing (\(sound.fileName)), skipping")
            // Skip missing file, advance to next
            currentTrackIndex = index + 1
            playTrack(at: currentTrackIndex)
            return
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: localURL)
            newPlayer.numberOfLoops = 0 // Play once, we handle sequencing
            let volume = currentLoudness?.gainFactor ?? 1.0
            newPlayer.volume = volume
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            
            guard newPlayer.play() else {
                // Log session state on play() failure
                logSessionDump("play() FALSE")
                throw NSError(domain: "AlarmPlayback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start playback"])
            }
            
            player = newPlayer
            currentTrackIndex = index
            currentTrackName = sound.name
            isPlaying = true
            lastError = nil
            consecutiveFailures = 0 // Reset on success
            
            let displayTrackName = displayName(for: sound.name)
            
            os_log(.info, log: log, "Now playing: %{public}s (index %{public}d/%{public}d) volume=%{public}.2f (loudness %{public}d%%)", 
                   displayTrackName, index + 1, selectedSoundIDs.count, volume, currentLoudness?.percentage ?? 100)
            SmartWakeDebugLog.log("PLAYBACK started track \(index + 1): \(displayTrackName) volume=\(String(format: "%.2f", volume)) (loudness \(currentLoudness?.percentage ?? 100)%)")
            
            // Publish Now Playing info with stripped display name
            publishNowPlayingInfo(for: sound, player: newPlayer, displayName: displayTrackName)
            
            // Setup remote command center
            setupRemoteCommands()
            
        } catch {
            lastError = error.localizedDescription
            os_log(.error, log: log, "Failed to play track %{public}s: %{public}s", sound.name, error.localizedDescription)
            SmartWakeDebugLog.log("PLAYBACK: track \(index) failed to start: \(error.localizedDescription), skipping")
            // Skip failed track, advance to next
            consecutiveFailures += 1
            if consecutiveFailures >= self.selectedSoundIDs.count {
                // All tracks failed - abort playback
                os_log(.error, log: log, "PLAYBACK ABORT: all \(self.selectedSoundIDs.count) tracks failed to start")
                SmartWakeDebugLog.log("PLAYBACK ABORT: all \(self.selectedSoundIDs.count) tracks failed to start")
                isPlaying = false
                stop()
                return
            }
            // Skip failed track, advance to next
            currentTrackIndex = index + 1
            playTrack(at: currentTrackIndex)
        }
    }

    /// Publish Now Playing info for the current track
    private func publishNowPlayingInfo(for sound: ImportedSound, player: AVAudioPlayer, displayName: String) {
        var nowPlayingInfo: [String: Any] = [:]
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = displayName
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = player.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        
        // Best-effort metadata from AVAsset
        let asset = AVURLAsset(url: player.url!)
        let metadata = asset.commonMetadata
        
        // Artist
        if let artistItem = metadata.first(where: { $0.commonKey == .commonKeyArtist }),
           let artist = artistItem.stringValue {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        }
        
        // Album
        if let albumItem = metadata.first(where: { $0.commonKey == .commonKeyAlbumName }),
           let album = albumItem.stringValue {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
        }
        
        // Artwork: embedded art from the track, else the app icon as fallback
        var artworkImage: UIImage?
        if let artworkItem = metadata.first(where: { $0.commonKey == .commonKeyArtwork }),
           let data = artworkItem.dataValue {
            artworkImage = UIImage(data: data)
        }
        if artworkImage == nil {
            artworkImage = Self.appIconImage()
        }
        if let artwork = artworkImage {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        os_log(.info, log: log, "Published Now Playing info for: %{public}s", displayName)
    }

    /// Best-effort app icon for artwork fallback — uses asset catalog
    private static func appIconImage() -> UIImage? {
        // Modern apps use asset catalog with CFBundleIconName; try common names
        if let img = UIImage(named: "AppIcon") {
            return img
        }
        if let img = UIImage(named: "AppIcon60x60") {
            return img
        }
        if let img = UIImage(named: "AppIcon-1") {
            return img
        }
        // Fallback: legacy CFBundleIcons lookup (pre-asset-catalog)
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last else { return nil }
        return UIImage(named: last)
    }

    /// Update elapsed time in Now Playing info
    private func updateElapsedTime() {
        guard let player = player else { return }
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    /// Setup remote command center for lock screen controls
    /// During alarm ringing: STOP (■) + PAUSE/PLAY (⏯) + SNOOZE (⏭) all enabled
    /// Pause trap code kept for internal use if pause ever re-enabled
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Real Stop button (■ = stop alarm) - ENABLED
        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            SmartWakeDebugLog.log("REMOTE COMMAND: stop (STOP) fired")
            self?.handleStopCommand()
            return .success
        }
        
        // Play/Pause toggle (⏯ = pause/resume) - ENABLED with pause trap
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            SmartWakeDebugLog.log("REMOTE COMMAND: togglePlayPause fired")
            self?.togglePlayPause()
            return .success
        }
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.resumePlayback()
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pausePlayback()
            return .success
        }
        
        // Previous track = STOP alarm (■ = stop alarm) - ENABLED as alternate stop
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            SmartWakeDebugLog.log("REMOTE COMMAND: previousTrack (STOP) fired")
            self?.handleStopCommand()
            return .success
        }
        
        // Next track = SNOOZE (⏭ = snooze) - ENABLED
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            SmartWakeDebugLog.log("REMOTE COMMAND: nextTrack (SNOOZE) fired")
            self?.handleSnoozeCommand()
            return .success
        }
        
        // Disable seek and rate commands
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.changePlaybackRateCommand.isEnabled = false
    }

    /// Remove remote command handlers
    private func removeRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.stopCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.changePlaybackRateCommand.isEnabled = false
    }
    
    /// Handle STOP command from lock screen (previous track)
    private func handleStopCommand() {
        // Snapshot backup ID locally BEFORE async cancel — prevents double-cancel on duplicate deliveries
        let backupID = pendingBackupAlarmID
        pendingBackupAlarmID = nil
        
        // 1-second dedupe gate
        let now = Date()
        if let last = lastStopCommandTime, now.timeIntervalSince(last) < 1.0 {
            SmartWakeDebugLog.log("STOP DUP ignored (within 1s)")
            return
        }
        lastStopCommandTime = now
        
        // Cancel pending backup alarm
        if let id = backupID {
            Task {
                try? await AlarmManager.shared.cancel(id: id)
                SmartWakeDebugLog.log("STOP: cancelled pending backup alarm \(id.uuidString)")
            }
        }
        
        // Stop playback and clean up
        stop(reason: "remote-stop")
        
        // Re-arm next day and restart silent loop via SmartWakeService
        Task { @MainActor in
            await SmartWakeService.shared.checkAndArmUpcomingAlarms()
            await SmartWakeService.shared.startIfReadyForeground()
        }
    }
    
    /// Handle SNOOZE command from lock screen (next track)
    private func handleSnoozeCommand() {
        // Snapshot backup ID locally BEFORE async cancel — prevents double-cancel on duplicate deliveries
        let backupID = pendingBackupAlarmID
        pendingBackupAlarmID = nil
        
        // 1-second dedupe gate
        let now = Date()
        if let last = lastSnoozeCommandTime, now.timeIntervalSince(last) < 1.0 {
            SmartWakeDebugLog.log("SNOOZE DUP ignored (within 1s)")
            return
        }
        lastSnoozeCommandTime = now
        
        // Snapshot alarm/occurrence/coordinator BEFORE stop() clears them
        guard let alarm = currentAlarm,
              let occurrence = currentOccurrence,
              let coordinator = AlarmCoordinator.sharedInstance else {
            SmartWakeDebugLog.log("SNOOZE: missing alarm/occurrence/coordinator")
            return
        }
        
        let snoozeMinutes = alarm.snoozeDurationMinutes ?? 10
        let snoozeFireDate = Date().addingTimeInterval(TimeInterval(snoozeMinutes * 60))
        
        // Cancel pending backup alarm
        if let id = backupID {
            Task {
                try? await AlarmManager.shared.cancel(id: id)
                SmartWakeDebugLog.log("SNOOZE: cancelled pending backup alarm \(id.uuidString)")
            }
        }
        
        // Stop playback
        stop(reason: "remote-snooze")
        
        // Schedule one-shot AlarmKit alarm with floor sound
        Task { @MainActor in
            do {
                // Get the floor sound for this alarm
                let floorSound = try await coordinator.alarmKitSound(for: alarm.sound, loudness: alarm.loudness)
                
                let snoozeID = UUID()
                let snoozeDurationSeconds = TimeInterval(snoozeMinutes * 60)
                let snoozeConfig = AlarmManager.AlarmConfiguration<ScheduledOccurrenceMetadata>(
                    countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: snoozeDurationSeconds),
                    schedule: .fixed(snoozeFireDate),
                    attributes: AlarmAttributes(
                        presentation: AlarmPresentation(
                            alert: AlarmPresentation.Alert(
                                title: LocalizedStringResource(stringLiteral: alarm.label.isEmpty ? "Alarm" : alarm.label),
                                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle.fill"),
                                secondaryButton: AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz"),
                                secondaryButtonBehavior: .countdown
                            ),
                            countdown: AlarmPresentation.Countdown(title: LocalizedStringResource(stringLiteral: "Snoozed \(snoozeMinutes) min")),
                            paused: AlarmPresentation.Paused(title: LocalizedStringResource(stringLiteral: "Snoozed \(snoozeMinutes) min"), resumeButton: AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.circle.fill"))
                        ),
                        metadata: ScheduledOccurrenceMetadata(
                            alarmID: alarm.id,
                            occurrenceKey: "SNOOZE-\(occurrence.occurrenceKey)",
                            baseDate: snoozeFireDate
                        ),
                        tintColor: .orange
                    ),
                    stopIntent: nil,
                    secondaryIntent: nil,
                    sound: floorSound
                )
                _ = try await AlarmManager.shared.schedule(id: snoozeID, configuration: snoozeConfig)
                
                // Register with coordinator for reconcile exclusion
                coordinator.addEmergencyReRingID(snoozeID)
                pendingSnoozeAlarmID = snoozeID
                
                SmartWakeDebugLog.log("SNOOZE: scheduled AlarmKit snooze id=\(snoozeID.uuidString) at \(snoozeFireDate) for \(snoozeMinutes) min")
                
                // Post local notification for snooze feedback
                let content = UNMutableNotificationContent()
                content.title = "Snoozed \(snoozeMinutes) min"
                let formatter = DateFormatter()
                formatter.setLocalizedDateFormatFromTemplate("j:mm a")
                formatter.timeZone = TimeZone.current
                content.body = "Next ring \(formatter.string(from: snoozeFireDate))"
                content.sound = nil // Silent notification
                
                let request = UNNotificationRequest(
                    identifier: "SNOOZE-\(snoozeID.uuidString)",
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
                )
                
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        SmartWakeDebugLog.log("SNOOZE notification failed: \(error.localizedDescription)")
                    }
                }

                // Update the widget snapshot so the lock-screen widget shows the
                // snoozed ring time instead of the regular next alarm.
                coordinator.publishSnoozeWidgetSnapshot(
                    alarm: alarm,
                    fireDate: snoozeFireDate,
                    occurrenceKey: "SNOOZE-\(occurrence.occurrenceKey)"
                )
            } catch {
                let nsError = error as NSError
                SmartWakeDebugLog.log("SNOOZE: scheduling FAILED: \(error.localizedDescription) (domain=\(nsError.domain) code=\(nsError.code))")
            }
        }
    }
    
    /// Toggle play/pause
    private func togglePlayPause() {
        guard let player = player else { return }
        if player.isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }
    
    /// Pause playback - PAUSE TRAP: start silent loop, session stays active, app stays alive
    private func pausePlayback() {
        player?.pause()
        isPlaying = false
        updateElapsedTime()
        
        // PAUSE TRAP: Start silent loop to keep session active and app alive
        // Never deactivate the session on pause
        SmartWakeDebugLog.log("PAUSE TRAP: starting silent loop to keep session alive")
        Task { await SmartWakeService.shared.startIfReadyForeground() }
        
        os_log(.info, log: log, "Playback paused (pause trap: silent loop started)")
    }
    
    /// Resume playback - stop silent loop and continue playlist
    private func resumePlayback() {
        guard let player = player else { return }
        player.play()
        isPlaying = true
        updateElapsedTime()
        
        // Stop silent loop since we're playing again
        SmartWakeService.shared.stopSilentPlayerOnly(reason: "playback resumed from pause")
        
        os_log(.info, log: log, "Playback resumed (silent loop stopped)")
    }

    /// Seek to position
    private func seek(to time: TimeInterval) {
        guard let player = player else { return }
        player.currentTime = min(max(time, 0), player.duration)
        updateElapsedTime()
        os_log(.info, log: log, "Seeked to %{public}.1f", time)
    }

    /// Stop playback and clean up, restoring mixable audio session
    /// - Parameter reason: Reason for stopping (e.g., "user", "alarm disabled/deleted (tick)", "song-finish validation", "takeover transition")
    func stop(reason: String = "user") {
        os_log(.info, log: log, "stop() called (reason: %{public}s)", reason)
        SmartWakeDebugLog.log("PLAYBACK stopped (reason: \(reason))")
        
        // Remove stop notification if we have alarm ID and occurrence key
        if let alarmID = currentAlarmID, let occurrenceKey = currentOccurrence?.occurrenceKey {
            removeStopNotification(alarmID: alarmID, occurrenceKey: occurrenceKey)
        }
        
        // Remove from armed occurrences set using composite key
        if let alarmID = currentAlarmID, let occurrenceKey = currentOccurrence?.occurrenceKey {
            let armingKey = "\(alarmID.uuidString.prefix(8))|\(occurrenceKey)"
            isArmedForOccurrence.remove(armingKey)
        }
        
        player?.stop()
        player = nil
        
        // Clear Now Playing info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        
        // Remove remote commands
        removeRemoteCommands()
        
        // Reset state
        isPlaying = false
        currentTrackName = nil
        currentPlaylistID = nil
        currentLoudness = nil
        currentAlarm = nil
        currentOccurrence = nil
        selectedSoundIDs = []
        currentTrackIndex = 0
        
        // Restore mixable audio session (for Smart Wake silent loop if running)
        do {
            try restoreMixableAudioSession()
        } catch {
            os_log(.error, log: log, "Failed to restore mixable audio session: %{public}s", error.localizedDescription)
            SmartWakeDebugLog.log("PLAYBACK: failed to restore mixable session: \(error.localizedDescription)")
        }
    }

    /// Advance to next track in playlist
    private func advanceToNextTrack() {
        // Validate the alarm still exists and is enabled before continuing
        guard validateStillRinging() else {
            stop(reason: "alarm disabled/deleted (tick)")
            return
        }
        
        currentTrackIndex += 1
        if currentTrackIndex >= selectedSoundIDs.count {
            // Completed full cycle - loop back
            currentTrackIndex = 0
        }
        playTrack(at: currentTrackIndex)
    }

    /// Record a completed song into play history via the app coordinator.
    private func recordHistoryForCurrentTrack() {
        guard let currentTrackName,
              let alarm = currentAlarm,
              let coordinator = AlarmCoordinator.sharedInstance else { return }
        coordinator.recordPlayHistory(
            songName: currentTrackName,
            alarmID: alarm.id,
            alarmLabel: alarm.label.isEmpty ? "Alarm" : alarm.label
        )
    }

    /// Resume playback after interruption - only while playback is active (currentAlarmID set and stop() not run)
    private func attemptPlaybackResume() {
        // Only resume if we have an active alarm and haven't been stopped
        guard currentAlarmID != nil, isPlaying || (player?.isPlaying ?? false) else {
            SmartWakeDebugLog.log("PLAYBACK RESUME skipped: not active (currentAlarmID=\(currentAlarmID?.uuidString ?? "nil") isPlaying=\(isPlaying))")
            return
        }
        
        resumeAttempts = 0
        maxResumeAttempts = 3
        tryResumePlayback()
    }
    
    private func tryResumePlayback() {
        resumeAttempts += 1
        SmartWakeDebugLog.log("PLAYBACK RESUME attempt \(resumeAttempts)/\(maxResumeAttempts)")
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
            
            if player?.play() == true {
                SmartWakeDebugLog.log("PLAYBACK RESUMED ok")
                return
            } else {
                SmartWakeDebugLog.log("PLAYBACK RESUMED failed (play returned false)")
            }
        } catch {
            SmartWakeDebugLog.log("PLAYBACK RESUMED error: \(error.localizedDescription)")
        }
        
        if resumeAttempts < maxResumeAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.tryResumePlayback()
            }
        } else {
            // All attempts failed - log and stop
            SmartWakeDebugLog.log("PLAYBACK RESUMED: all \(maxResumeAttempts) attempts failed")
            stop(reason: "resume-failed")
        }
    }
    
    /// Strip trailing UUID from sound name for display (format: "name_<36-char-uuid>")
    private func displayName(for soundName: String) -> String {
        // Pattern: name_XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX (36 chars after last _)
        let uuidPattern = "_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        if let range = soundName.range(of: uuidPattern, options: .regularExpression) {
            return String(soundName[..<range.lowerBound])
        }
        return soundName
    }

}

// MARK: - AVAudioPlayerDelegate
extension AlarmPlaybackService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard flag else {
                os_log(.info, log: self.log, "Playback finished unsuccessfully (interrupted/error)")
                SmartWakeDebugLog.log("PLAYBACK finished unsuccessfully (interrupted/error)")
                return
            }

            os_log(.info, log: self.log, "Track finished successfully, advancing to next")
            SmartWakeDebugLog.log("PLAYBACK finished track: \(self.currentTrackName ?? "unknown"), advancing")

            // Per-song history: one entry per fully completed track.
            self.recordHistoryForCurrentTrack()

            // Advance to next track
            self.advanceToNextTrack()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            let errorDesc = error?.localizedDescription ?? "Unknown decode error"
            self.lastError = "Audio decode error: \(errorDesc)"
            os_log(.error, log: self.log, "Audio decode error: %{public}s", errorDesc)
            SmartWakeDebugLog.log("PLAYBACK decode error: \(errorDesc)")
            // Skip failed track
            self.currentTrackIndex += 1
            self.playTrack(at: self.currentTrackIndex)
        }
    }
}