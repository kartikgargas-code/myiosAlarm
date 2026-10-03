import Foundation
import AVFoundation
import MediaPlayer
import Observation
import os.log
import AlarmClockShared
import UIKit

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
    private var isArmedForOccurrence: Set<String> = [] // Track armed occurrences to prevent double-start
    private var transitionCheckTask: Task<Void, Never>?
    private var consecutiveFailures = 0 // Track consecutive play failures to prevent infinite recursion
    
    // Published state
    private(set) var isPlaying = false
    private(set) var currentTrackName: String?
    private(set) var lastError: String?
    private var lastSessionDump: String = ""

    private override init() {
        super.init()
        os_log(.info, log: log, "AlarmPlaybackService initialized")
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
        
        // Log session state at start entry
        logSessionDump("START")

        // Guard against double-start for same occurrence
        let occurrenceKey = occurrence.occurrenceKey
        guard !isArmedForOccurrence.contains(occurrenceKey) else {
            os_log(.info, log: log, "Already armed for occurrence %{public}s, skipping", occurrenceKey)
            return
        }
        isArmedForOccurrence.insert(occurrenceKey)

        // Reset consecutive failures on new start
        consecutiveFailures = 0

        // Resolve playlist and selected sound IDs
        do {
            let playlist = try SoundLibrary.shared.playlist(for: playlistID)
            selectedSoundIDs = playlist.selectedSoundIDs
            
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
            isArmedForOccurrence.remove(occurrenceKey)
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
    private func ensureAudioSessionActive() throws {
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
    /// Call at: start() entry, after play() returns false, after each retry in retry-B
    private func logSessionDump(_ tag: String) {
        let session = AVAudioSession.sharedInstance()
        let appState = UIApplication.shared.applicationState.rawValue
        let sceneState = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.activationState.rawValue ?? -1
        let silentPlayerRunning = SmartWakeService.shared.isRunning
        
        var dump = "SESSION DUMP [\(tag)]: "
        dump += "cat=\(session.category.rawValue) mode=\(session.mode.rawValue) opts=\(session.categoryOptions.rawValue) "
        dump += "isOtherAudioPlaying=\(session.isOtherAudioPlaying) secondaryAudioShouldBeSilencedHint=\(session.secondaryAudioShouldBeSilencedHint) "
        dump += "outputVolume=\(session.outputVolume) "
        dump += "routeOutputs=\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: \",\")) "
        dump += "silentPlayer=\(silentPlayerRunning) appState=\(appState) sceneState=\(sceneState)"
        
        lastSessionDump = dump
        SmartWakeDebugLog.log(dump)
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
            
            os_log(.info, log: log, "Now playing: %{public}s (index %{public}d/%{public}d) volume=%{public}.2f (loudness %{public}d%%)", 
                   sound.name, index + 1, selectedSoundIDs.count, volume, currentLoudness?.percentage ?? 100)
            SmartWakeDebugLog.log("PLAYBACK started track \(index + 1): \(sound.name) volume=\(String(format: "%.2f", volume)) (loudness \(currentLoudness?.percentage ?? 100)%)")
            
            // Publish Now Playing info
            publishNowPlayingInfo(for: sound, player: newPlayer)
            
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
    private func publishNowPlayingInfo(for sound: ImportedSound, player: AVAudioPlayer) {
        var nowPlayingInfo: [String: Any] = [:]
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = sound.name
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
        
        // Artwork
        if let artworkItem = metadata.first(where: { $0.commonKey == .commonKeyArtwork }),
           let data = artworkItem.dataValue,
           let image = UIImage(data: data) {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        os_log(.info, log: log, "Published Now Playing info for: %{public}s", sound.name)
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
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Play/Pause
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
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
        
        // Seek
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(to: positionEvent.positionTime)
            return .success
        }
        
        // Disable unsupported commands
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
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
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
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

    /// Pause playback
    private func pausePlayback() {
        player?.pause()
        isPlaying = false
        updateElapsedTime()
        os_log(.info, log: log, "Playback paused")
    }

    /// Resume playback
    private func resumePlayback() {
        guard let player = player else { return }
        player.play()
        isPlaying = true
        updateElapsedTime()
        os_log(.info, log: log, "Playback resumed")
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