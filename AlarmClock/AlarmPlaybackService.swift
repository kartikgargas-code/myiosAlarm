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
        SmartWakeDebugLog.log("PLAYBACK start attempt playlist=\(playlistID.uuidString.prefix(8)) tracks=\(selectedSoundIDs.count)")

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
            currentAlarm = alarm
            currentOccurrence = occurrence
            currentTrackIndex = 0
            coordinator = AlarmCoordinator.sharedInstance // Will need access to coordinator for play history
            
            // Ensure audio session is active (don't deactivate, only activate if needed)
            try ensureAudioSessionActive()
            
            SmartWakeDebugLog.log("PLAYBACK started track 1: \(selectedSoundIDs.first.map { SoundLibrary.shared.importedSounds.first(where: { $0.id == $0 })?.name ?? "unknown" } ?? "unknown")")
            
            // Start playing the first track
            playTrack(at: 0)
            
        } catch {
            lastError = error.localizedDescription
            os_log(.error, log: log, "Failed to start playback: %{public}s", error.localizedDescription)
            isArmedForOccurrence.remove(occurrenceKey)
        }
    }

    /// Ensure the audio session is active (for background playback)
    private func ensureAudioSessionActive() throws {
        let session = AVAudioSession.sharedInstance()
        // Only activate if not already active - never deactivate
        if session.isOtherAudioPlaying {
            // Session is already active from SmartWake, just ensure category
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } else {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
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
            newPlayer.volume = currentLoudness?.gainFactor ?? 1.0
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            
            guard newPlayer.play() else {
                throw NSError(domain: "AlarmPlayback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start playback"])
            }
            
            player = newPlayer
            currentTrackIndex = index
            currentTrackName = sound.name
            isPlaying = true
            lastError = nil
            consecutiveFailures = 0 // Reset on success
            
            os_log(.info, log: log, "Now playing: %{public}s (index %{public}d/%{public}d)", 
                   sound.name, index + 1, selectedSoundIDs.count)
            SmartWakeDebugLog.log("PLAYBACK started track \(index + 1): \(sound.name)")
            
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
            if consecutiveFailures >= selectedSoundIDs.count {
                // All tracks failed - abort playback
                os_log(.error, log: log, "PLAYBACK ABORT: all \(selectedSoundIDs.count) tracks failed to start")
                SmartWakeDebugLog.log("PLAYBACK ABORT: all \(selectedSoundIDs.count) tracks failed to start")
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

    /// Stop playback and clean up (but keep audio session active)
    func stop() {
        os_log(.info, log: log, "stop() called")
        
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
        
        // Note: We do NOT deactivate the audio session - that's managed by SmartWake
        os_log(.info, log: log, "Playback stopped, audio session kept active")
    }

    /// Advance to next track in playlist
    private func advanceToNextTrack() {
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