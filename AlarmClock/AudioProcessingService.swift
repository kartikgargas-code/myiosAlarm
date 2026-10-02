import Foundation
import AVFoundation
import AudioToolbox
import CryptoKit

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

    private func audioMetadata(for url: URL) -> (duration: TimeInterval, sampleRate: Double, channelCount: Int)? {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return (
            Double(audioFile.length) / sampleRate,
            sampleRate,
            Int(audioFile.processingFormat.channelCount)
        )
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
    /// Selects multiple random songs (or uses sequence order), concatenates them with loudness applied
    /// Returns the URL of the combined file
    func precomposePlaylist(
        playlistID: UUID,
        loudness: AlarmLoudness,
        songCount: Int = 5,
        alarmID: UUID? = nil
    ) async throws -> (URL, PlaylistDiagnostics.PreparationEntry, PlaylistDiagnostics.GeneratedFileEntry) {
        // Capture MainActor-isolated values before detaching
        let soundsDir = SoundLibrary.shared.soundsDirectory
        let processedDir = processedSoundsDirectory
        let playlist = try SoundLibrary.shared.playlist(for: playlistID)
        let soundIDs = playlist.selectedSoundIDs
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
        
        // Select songs based on play order: random or sequence
        let selectedSoundIDs: [UUID]
        if playlist.playOrder == .sequence {
            // Use selected songs in their listed order (up to songCount)
            selectedSoundIDs = Array(soundIDs.prefix(min(songCount, soundIDs.count)))
        } else {
            // Random mode (default behavior)
            selectedSoundIDs = selectRandomSongs(
                from: soundIDs,
                count: min(songCount, soundIDs.count)
            )
        }
        
        // Prepare diagnostic data
        let preparationStartTime = Date()
        let selectedSounds = selectedSoundIDs.compactMap { id in
            importedSounds.first(where: { $0.id == id })
        }
        let selectedSongNames = selectedSounds.map { $0.name }
        let selectedSongDurations = selectedSounds.compactMap { $0.duration }
        let expectedTotalDuration = selectedSongDurations.reduce(0, +)
        
        // Generate selection hash for cache key based on actual selected songs.
        // SHA256, not hashValue: Swift's hashValue is randomized per launch, which
        // made cache keys unstable across launches and defeated cache reuse.
        let selectionKey = selectedSoundIDs.map { $0.uuidString }.sorted().joined(separator: "-")
        let selectionHash = SoundSelectionHash.make(from: selectionKey)
        let precomposedFileName = "playlist_\(playlistName)_\(playlistID.uuidString.prefix(8))_\(selectionHash)_\(loudness.percentage)pct.wav"
        let precomposedURL = processedDir.appendingPathComponent(precomposedFileName)
        
        // If already exists for THIS specific selection, return it
        if fileManager.fileExists(atPath: precomposedURL.path) {
            let preparationEndTime = Date()
            let preparationEntry = PlaylistDiagnostics.PreparationEntry(
                timestamp: preparationStartTime,
                alarmID: alarmID ?? UUID(),
                playlistID: playlistID,
                playlistName: playlistName,
                totalSongsInPlaylist: playlist.soundIDs.count,
                selectedSongCount: selectedSoundIDs.count,
                selectedSongIDs: selectedSoundIDs,
                selectedSongNames: selectedSounds.map { $0.name },
                selectedSongDurations: selectedSounds.compactMap { $0.duration },
                expectedTotalDuration: expectedTotalDuration,
                loudnessPercentage: loudness.percentage,
                usedProcessedAudio: true,
                preparationStartTime: preparationStartTime,
                preparationEndTime: preparationEndTime,
                preparationDuration: preparationEndTime.timeIntervalSince(preparationStartTime),
                success: true,
                error: nil
            )
            
            let fileSize = (try? fileManager.attributesOfItem(atPath: precomposedURL.path)[.size] as? Int64) ?? 0
            let metadata = audioMetadata(for: precomposedURL)
            let actualDuration = metadata?.duration ?? 0
            let generatedFileEntry = PlaylistDiagnostics.GeneratedFileEntry(
                timestamp: Date(),
                playlistID: playlistID,
                fileExists: true,
                fileSizeBytes: fileSize,
                audioFormat: "WAV",
                sampleRate: metadata?.sampleRate ?? 0,
                channelCount: metadata?.channelCount ?? 0,
                actualDuration: actualDuration,
                expectedDuration: expectedTotalDuration,
                fileReadable: metadata != nil,
                appearsComplete: metadata.map { abs($0.duration - expectedTotalDuration) < 1.0 } ?? false
            )
            
            return (precomposedURL, preparationEntry, generatedFileEntry)
        }
        
        // Concatenate songs into a single WAV by streaming each song's frames
        // to disk as they are read. Holding every song's PCM in one buffer
        // peaked at hundreds of MB and got the app killed (jetsam) mid-commit.
        // Memory stays at a few chunk buffers regardless of song count/length.
        // Songs are converted to the output format (44.1k stereo) with
        // AVAudioConverter so mixed-rate/mono MP3s still play at correct speed.
        let resultURL = try await Task.detached(priority: .userInitiated) { [soundsDir, processedDir, selectedSoundIDs, loudness, precomposedURL, playlistName, playlistID, fileManager, importedSounds] in
            let outputSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ] as [String: Any]

            let outputFile = try AVAudioFile(forWriting: precomposedURL, settings: outputSettings)
            let outputFormat = outputFile.processingFormat
            let gain = Float(loudness.gainFactor)
            var appendedSongs = 0

            func writeConverted(_ buffer: AVAudioPCMBuffer) throws {
                if gain != 1.0 {
                    let channels = Int(buffer.format.channelCount)
                    let frames = Int(buffer.frameLength)
                    for channel in 0..<channels {
                        guard let channelData = buffer.floatChannelData?[channel] else { continue }
                        for frame in 0..<frames {
                            channelData[frame] *= gain
                        }
                    }
                }
                try outputFile.write(from: buffer)
            }

            for soundID in selectedSoundIDs {
                guard let sound = importedSounds.first(where: { $0.id == soundID }),
                      let soundURL = sound.localURL(soundsDirectory: soundsDir),
                      fileManager.fileExists(atPath: soundURL.path) else {
                    continue
                }

                do {
                    let audioFile = try AVAudioFile(forReading: soundURL)
                    let sourceFormat = audioFile.processingFormat

                    if sourceFormat == outputFormat {
                        // Fast path: same format, straight chunk copy.
                        let chunkFrames: AVAudioFrameCount = 262_144
                        guard let chunk = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else { continue }
                        while true {
                            try audioFile.read(into: chunk, frameCount: chunkFrames)
                            if chunk.frameLength == 0 { break }
                            try writeConverted(chunk)
                            if chunk.frameLength < chunkFrames { break }
                        }
                    } else {
                        // Convert to the output format so mixed sample rates and
                        // channel counts play at correct speed.
                        guard let converter = try? AVAudioConverter(from: sourceFormat, to: outputFormat) else { continue }
                        let srcChunkFrames: AVAudioFrameCount = 262_144
                        guard let srcChunk = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: srcChunkFrames) else { continue }
                        var reachedEOF = false

                        let inputBlock: AVAudioConverterInputBlock = { _, status in
                            if reachedEOF {
                                status.pointee = .endOfStream
                                return nil
                            }
                            do {
                                try audioFile.read(into: srcChunk, frameCount: srcChunkFrames)
                            } catch {
                                reachedEOF = true
                                status.pointee = .noDataNow
                                return nil
                            }
                            if srcChunk.frameLength == 0 {
                                reachedEOF = true
                                status.pointee = .endOfStream
                                return nil
                            }
                            status.pointee = .haveData
                            return srcChunk
                        }

                        while !reachedEOF {
                            let dstCapacity: AVAudioFrameCount = 262_144
                            guard let dstChunk = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: dstCapacity) else { break }
                            var convertError: NSError?
                            let status = converter.convert(to: dstChunk, error: &convertError, withInputFrom: inputBlock)
                            if status == .error { break }
                            if dstChunk.frameLength > 0 {
                                try writeConverted(dstChunk)
                            }
                            if status == .endOfStream { break }
                            if dstChunk.frameLength == 0 && status == .haveData { continue }
                            if dstChunk.frameLength < dstCapacity && status == .haveData { continue }
                        }
                    }
                    appendedSongs += 1
                } catch {
                    // Skip unreadable/corrupt song instead of failing the whole playlist.
                    continue
                }
            }

            guard appendedSongs > 0 else {
                try? fileManager.removeItem(at: precomposedURL)
                throw AudioProcessingError.processingFailed("No songs in playlist could be read")
            }

            return precomposedURL
        }.value
        
        let preparationEndTime = Date()
        
        // Create preparation entry
        let preparationEntry = PlaylistDiagnostics.PreparationEntry(
            timestamp: Date(),
            alarmID: alarmID ?? UUID(),
            playlistID: playlistID,
            playlistName: playlist.name,
            totalSongsInPlaylist: playlist.soundIDs.count,
            selectedSongCount: selectedSoundIDs.count,
            selectedSongIDs: selectedSoundIDs,
            selectedSongNames: selectedSounds.map { $0.name },
            selectedSongDurations: selectedSounds.compactMap { $0.duration },
            expectedTotalDuration: expectedTotalDuration,
            loudnessPercentage: loudness.percentage,
            usedProcessedAudio: true,
            preparationStartTime: preparationStartTime,
            preparationEndTime: preparationEndTime,
            preparationDuration: preparationEndTime.timeIntervalSince(preparationStartTime),
            success: true,
            error: nil
        )
        
        let fileExists = fileManager.fileExists(atPath: precomposedURL.path)
        let fileSize = (try? fileManager.attributesOfItem(atPath: precomposedURL.path)[.size] as? Int64) ?? 0
        let metadata = audioMetadata(for: precomposedURL)
        let actualDuration = metadata?.duration ?? 0
        let generatedFileEntry = PlaylistDiagnostics.GeneratedFileEntry(
            timestamp: Date(),
            playlistID: playlistID,
            fileExists: fileExists,
            fileSizeBytes: fileSize,
            audioFormat: "WAV",
            sampleRate: metadata?.sampleRate ?? 0,
            channelCount: metadata?.channelCount ?? 0,
            actualDuration: actualDuration,
            expectedDuration: expectedTotalDuration,
            fileReadable: metadata != nil,
            appearsComplete: metadata.map { abs($0.duration - expectedTotalDuration) < 1.0 } ?? false
        )
        
        // Cleanup: delete old precomposed files for this playlist+loudness that don't match current selection
        let patternPrefix = "playlist_\(playlistName)_\(playlistID.uuidString.prefix(8))_"
        let patternSuffix = "_\(loudness.percentage)pct.wav"
        let allFiles = (try? fileManager.contentsOfDirectory(at: processedDir, includingPropertiesForKeys: nil)) ?? []
        for file in allFiles {
            let fileName = file.lastPathComponent
            if fileName.hasPrefix(patternPrefix) && fileName.hasSuffix(patternSuffix) && fileName != precomposedFileName {
                try? fileManager.removeItem(at: file)
            }
        }
        
        return (precomposedURL, preparationEntry, generatedFileEntry)
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
        let identifier = "_\(playlistID.uuidString.prefix(8))_"

        let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("playlist_")
            && file.lastPathComponent.contains(identifier)
            && file.lastPathComponent.hasSuffix("pct.wav") {
            try? fileManager.removeItem(at: file)
        }
    }
}

/// Deterministic cache-key hash for precomposed playlist selections.
/// Must be stable across launches and devices.
enum SoundSelectionHash {
    static func make(from key: String) -> String {
        String(SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined())
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