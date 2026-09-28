import Foundation
import AVFoundation
import AudioToolbox

/// Service for non-destructive audio gain adjustment
/// Creates modified audio files at different loudness levels without modifying the originals
@MainActor
final class AudioProcessingService {
    static let shared = AudioProcessingService()

    private let fileManager = FileManager.default
    private let processingQueue = DispatchQueue(label: "audio.processing", qos: .userInitiated)

    /// Directory for storing processed audio files (gain-adjusted versions)
    var processedSoundsDirectory: URL? {
        fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ProcessedSounds", isDirectory: true)
    }

    private init() {
        createProcessedSoundsDirectory()
    }

    private func createProcessedSoundsDirectory() {
        guard let dir = processedSoundsDirectory else { return }
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Get the URL for a processed sound file at a specific loudness
    /// Returns nil if the file doesn't exist yet (needs to be generated)
    func processedSoundURL(for originalSound: ImportedSound, loudness: AlarmLoudness) -> URL? {
        guard let dir = processedSoundsDirectory else { return nil }
        let baseName = (originalSound.fileName as NSString).deletingPathExtension
        let processedFileName = "\(baseName)_\(loudness.percentage)pct.wav"
        let url = dir.appendingPathComponent(processedFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Generate a gain-adjusted version of the audio file at the specified loudness
    /// Uses AVAudioEngine for non-destructive processing
    /// Output is written as WAV to ensure AlarmKit compatibility
    func generateProcessedSound(for originalSound: ImportedSound, loudness: AlarmLoudness) async throws -> URL {
        // Capture MainActor-isolated values before detaching
        let soundsDir = SoundLibrary.shared.soundsDirectory
        let processedDir = processedSoundsDirectory
        
        guard let soundsDir else {
            throw AudioProcessingError.soundsDirectoryUnavailable
        }
        guard let processedDir else {
            throw AudioProcessingError.processedDirectoryUnavailable
        }

        let originalURL = soundsDir.appendingPathComponent(originalSound.fileName)
        guard fileManager.fileExists(atPath: originalURL.path) else {
            throw AudioProcessingError.originalFileMissing(originalSound.fileName)
        }

        let baseName = (originalSound.fileName as NSString).deletingPathExtension
        let processedFileName = "\(baseName)_\(loudness.percentage)pct.wav"
        let processedURL = processedDir.appendingPathComponent(processedFileName)

        // If already exists, return it
        if fileManager.fileExists(atPath: processedURL.path) {
            return processedURL
        }

        // Process on background queue
        let gainFactor = loudness.gainFactor
        return try await Task.detached(priority: .userInitiated) {
            let audioFile = try AVAudioFile(forReading: originalURL)
            let format = audioFile.processingFormat
            let frameCount = UInt32(audioFile.length)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw AudioProcessingError.bufferCreationFailed
            }

            try audioFile.read(into: buffer)

            // Apply gain
            let gain = Float(gainFactor)
            let channels = Int(format.channelCount)
            let frames = Int(buffer.frameLength)

            for channel in 0..<channels {
                guard let channelData = buffer.floatChannelData?[channel] else { continue }
                for frame in 0..<frames {
                    channelData[frame] *= gain
                }
            }

            // Write processed file as WAV (AVAudioFile supports WAV/AIFF/CAF)
            let outputSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ] as [String: Any]
            let outputFile = try AVAudioFile(forWriting: processedURL, settings: outputSettings)
            try outputFile.write(from: buffer)

            return processedURL
        }.value
    }

    /// Get or generate the processed sound URL for an alarm
    func getOrCreateProcessedSound(for originalSound: ImportedSound, loudness: AlarmLoudness) async throws -> URL {
        if let existing = processedSoundURL(for: originalSound, loudness: loudness) {
            return existing
        }
        return try await generateProcessedSound(for: originalSound, loudness: loudness)
    }

    func removeProcessedSounds(for originalSound: ImportedSound) {
        let baseName = (originalSound.fileName as NSString).deletingPathExtension
        let prefix = "\(baseName)_"
        let directories = [processedSoundsDirectory, SoundLibrary.shared.soundsDirectory].compactMap { $0 }

        for directory in directories {
            let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix(prefix) && file.lastPathComponent.hasSuffix("pct.wav") {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// Clean up all processed sounds
    func removeAllProcessedSounds() {
        guard let dir = processedSoundsDirectory else { return }
        try? fileManager.removeItem(at: dir)
        createProcessedSoundsDirectory()
    }

    /// Precompose a playlist into a single WAV file for AlarmKit
    /// Selects multiple random songs, concatenates them with loudness applied
    /// Returns the URL of the combined file
    func precomposePlaylist(
        playlistID: UUID,
        loudness: AlarmLoudness,
        songCount: Int = 5
    ) async throws -> URL {
        // Capture MainActor-isolated values before detaching
        let soundsDir = SoundLibrary.shared.soundsDirectory
        let processedDir = processedSoundsDirectory
        let playlist = try SoundLibrary.shared.playlist(for: playlistID)
        let soundIDs = playlist.soundIDs
        let playlistName = playlist.name.replacingOccurrences(of: " ", with: "_")
        let importedSounds = SoundLibrary.shared.importedSounds  // Capture imported sounds
        
        guard let soundsDir else {
            throw AudioProcessingError.soundsDirectoryUnavailable
        }
        guard let processedDir else {
            throw AudioProcessingError.processedDirectoryUnavailable
        }
        
        guard !soundIDs.isEmpty else {
            throw AudioProcessingError.processingFailed("Playlist is empty")
        }
        
        // Select random songs (avoiding immediate repeats if we have history)
        let selectedSoundIDs = selectRandomSongs(
            from: soundIDs,
            count: min(songCount, soundIDs.count)
        )
        
        // Generate filename for the precomposed playlist
        let precomposedFileName = "playlist_\(playlistName)_\(playlistID.uuidString.prefix(8))_\(loudness.percentage)pct.wav"
        let precomposedURL = processedDir.appendingPathComponent(precomposedFileName)
        
        // If already exists, return it
        if fileManager.fileExists(atPath: precomposedURL.path) {
            return precomposedURL
        }
        
        // Concatenate songs into single file
        return try await Task.detached(priority: .userInitiated) { [soundsDir, processedDir, selectedSoundIDs, loudness, precomposedURL, playlistName, playlistID, fileManager, importedSounds] in
            var combinedBuffer: AVAudioPCMBuffer?
            var outputFormat: AVAudioFormat?
            
            // Read and concatenate each song
            for soundID in selectedSoundIDs {
                guard let sound = importedSounds.first(where: { $0.id == soundID }),
                      let soundURL = sound.localURL(soundsDirectory: soundsDir),
                      fileManager.fileExists(atPath: soundURL.path) else {
                    continue
                }
                
                let audioFile = try AVAudioFile(forReading: soundURL)
                let format = audioFile.processingFormat
                let frameCount = UInt32(audioFile.length)
                
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                    throw AudioProcessingError.bufferCreationFailed
                }
                
                try audioFile.read(into: buffer)
                
                // Apply gain
                let gain = Float(loudness.gainFactor)
                let channels = Int(format.channelCount)
                let frames = Int(buffer.frameLength)
                
                for channel in 0..<channels {
                    guard let channelData = buffer.floatChannelData?[channel] else { continue }
                    for frame in 0..<frames {
                        channelData[frame] *= gain
                    }
                }
                
                // Initialize combined buffer with first song's format
                if combinedBuffer == nil {
                    outputFormat = format
                    
                    // Calculate total frames
                    var totalFrames = 0
                    for id in selectedSoundIDs {
                        guard let sound = importedSounds.first(where: { $0.id == id }),
                              let soundURL = sound.localURL(soundsDirectory: soundsDir),
                              fileManager.fileExists(atPath: soundURL.path) else { continue }
                        let audioFile = try AVAudioFile(forReading: soundURL)
                        totalFrames += Int(audioFile.length)
                    }
                    
                    guard let outputFormat = outputFormat else {
                        throw AudioProcessingError.processingFailed("No output format")
                    }
                    
                    guard let newBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(totalFrames)) else {
                        throw AudioProcessingError.bufferCreationFailed
                    }
                    combinedBuffer = newBuffer
                }
                
                // Append to combined buffer
                if let combined = combinedBuffer {
                    let srcFrames = Int(buffer.frameLength)
                    let dstFrames = Int(combined.frameLength)
                    
                    for channel in 0..<channels {
                        guard let srcData = buffer.floatChannelData?[channel],
                              let dstData = combined.floatChannelData?[channel] else { continue }
                        
                        for frame in 0..<srcFrames {
                            if dstFrames + frame < Int(combined.frameCapacity) {
                                dstData[dstFrames + frame] = srcData[frame]
                            }
                        }
                    }
                    
                    combined.frameLength += AVAudioFrameCount(srcFrames)
                }
            }
            
            guard let combinedBuffer = combinedBuffer,
                  let outputFormat = outputFormat else {
                throw AudioProcessingError.processingFailed("No audio data to combine")
            }
            
            // Write combined file as WAV
            let outputSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: outputFormat.sampleRate,
                AVNumberOfChannelsKey: outputFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ] as [String: Any]
            
            let outputFile = try AVAudioFile(forWriting: precomposedURL, settings: outputSettings)
            try outputFile.write(from: combinedBuffer)
            
            return precomposedURL
        }.value
    }
    
    /// Select random songs from a list, avoiding immediate repeats if possible
    private func selectRandomSongs(from soundIDs: [UUID], count: Int) -> [UUID] {
        var available = soundIDs
        var selected: [UUID] = []
        
        for _ in 0..<min(count, soundIDs.count) {
            if available.isEmpty { available = soundIDs }
            if selected.count > 1 && available.count > 1 {
                // Avoid the last selected song
                available.removeAll { $0 == selected.last }
            }
            if let random = available.randomElement() {
                selected.append(random)
                available.removeAll { $0 == random }
            }
        }
        
        return selected
    }
    
    func removePrecomposedPlaylist(for playlistID: UUID) {
        guard let dir = processedSoundsDirectory else { return }
        let prefix = "playlist_\(playlistID.uuidString.prefix(8))"
        
        let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) && file.lastPathComponent.hasSuffix("pct.wav") {
            try? fileManager.removeItem(at: file)
        }
    }
}

enum AudioProcessingError: LocalizedError {
    case soundsDirectoryUnavailable
    case processedDirectoryUnavailable
    case originalFileMissing(String)
    case bufferCreationFailed
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .soundsDirectoryUnavailable:
            return "Library/Sounds directory is unavailable."
        case .processedDirectoryUnavailable:
            return "Processed sounds directory is unavailable."
        case .originalFileMissing(let fileName):
            return "Original sound file \(fileName) is missing."
        case .bufferCreationFailed:
            return "Failed to create audio buffer for processing."
        case .processingFailed(let message):
            return "Audio processing failed: \(message)"
        }
    }
}