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

    func audioMetadata(for url: URL) -> (duration: TimeInterval, sampleRate: Double, channelCount: Int)? {
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

    /// Production format for stitched sounds: CAF/IMA4 (~3.8× smaller than WAV, plays on device).
    /// Keep WAV code path available behind this constant for one release so we can revert instantly.
    static let useCAFFormat = true

    /// Cache statistics for the stitched playlist sounds ("playlist_…pct[.caf|.wav]")
    /// in both Library/ProcessedSounds and Library/Sounds.
    struct StitchCacheFolderStats {
        let fileCount: Int
        let totalBytes: Int64
    }

    /// Statistics for imported sound files in Library/Sounds
    struct ImportedSoundsStats {
        let fileCount: Int
        let totalBytes: Int64
        let orphanedFiles: [OrphanedFile]
    }

    struct OrphanedFile {
        let fileName: String
        let sizeBytes: Int64
        let path: String
    }

    func stitchCacheStats() -> (processed: StitchCacheFolderStats, sounds: StitchCacheFolderStats) {
        func stats(_ dir: URL?) -> StitchCacheFolderStats {
            guard let dir else { return StitchCacheFolderStats(fileCount: 0, totalBytes: 0) }
            let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let stitches = files.filter { $0.lastPathComponent.hasPrefix("playlist_") && $0.lastPathComponent.contains("pct") && ($0.pathExtension == "wav" || $0.pathExtension == "caf") }
            let bytes = stitches.reduce(Int64(0)) { total, url in
                total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return StitchCacheFolderStats(fileCount: stitches.count, totalBytes: bytes)
        }
        return (stats(processedSoundsDirectory), stats(SoundLibrary.shared.soundsDirectory))
    }

    /// Get statistics for imported sounds in Library/Sounds, including orphaned files
    func importedSoundsStats() -> ImportedSoundsStats {
        guard let soundsDir = SoundLibrary.shared.soundsDirectory else {
            return ImportedSoundsStats(fileCount: 0, totalBytes: 0, orphanedFiles: [])
        }
        
        // Get all MP3 files on disk
        let allFiles = (try? fileManager.contentsOfDirectory(at: soundsDir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])) ?? []
        let mp3Files = allFiles.filter { $0.pathExtension.lowercased() == "mp3" }
        
        // Get all library entries
        let libraryFileNames = Set(SoundLibrary.shared.importedSounds.map { $0.fileName })
        
        var totalBytes: Int64 = 0
        var orphanedFiles: [OrphanedFile] = []
        
        for file in mp3Files {
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            totalBytes += size
            
            if !libraryFileNames.contains(file.lastPathComponent) {
                orphanedFiles.append(OrphanedFile(
                    fileName: file.lastPathComponent,
                    sizeBytes: size,
                    path: file.path
                ))
            }
        }
        
        return ImportedSoundsStats(
            fileCount: mp3Files.count,
            totalBytes: totalBytes,
            orphanedFiles: orphanedFiles
        )
    }

    /// Delete orphaned sound files (files on disk with no library entry)
    func cleanOrphanedSoundFiles() -> (deleted: Int, freedBytes: Int64) {
        let stats = importedSoundsStats()
        var deleted = 0
        var freedBytes: Int64 = 0
        
        for orphan in stats.orphanedFiles {
            let url = URL(fileURLWithPath: orphan.path)
            do {
                try fileManager.removeItem(at: url)
                deleted += 1
                freedBytes += orphan.sizeBytes
            } catch {
                SmartWakeDebugLog.log("ORPHAN CLEAN: failed to delete \(orphan.fileName): \(error.localizedDescription)")
            }
        }
        
        let freedMB = Double(freedBytes) / (1_048_576.0)
        SmartWakeDebugLog.log(String(format: "SOUND PRUNE: deleted %d orphaned files (%.1f MB)", deleted, freedMB))
        return (deleted, freedBytes)
    }

    /// Delete every cached stitch file that is NOT referenced by a currently
    /// armed alarm. AlarmKit plays the file by filename, so a file an armed
    /// alarm points at must never be deleted — the caller passes those names
    /// in `keeping`. Per-sound processed variants (no "playlist_" prefix) are
    /// left alone.
    func pruneUnusedStitchFiles(keeping keepFileNames: Set<String>) -> (deleted: Int, freedBytes: Int64, kept: Int) {
        let directories = [processedSoundsDirectory, SoundLibrary.shared.soundsDirectory].compactMap { $0 }
        var deleted = 0
        var freedBytes: Int64 = 0
        var kept = 0

        for directory in directories {
            let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in files {
                let name = file.lastPathComponent
                guard name.hasPrefix("playlist_"),
                      name.contains("pct"),
                      file.pathExtension == "wav" || file.pathExtension == "caf" else { continue }
                if keepFileNames.contains(name) {
                    kept += 1
                    continue
                }
                let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                do {
                    try fileManager.removeItem(at: file)
                    deleted += 1
                    freedBytes += size
                } catch {
                    kept += 1
                }
            }
        }

        let freedMB = Double(freedBytes) / (1_048_576.0)
        // Count playlist_* files remaining
        let playlistFiles = try? fileManager.contentsOfDirectory(at: processedDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("playlist_") }
            .count ?? 0
        SmartWakeDebugLog.log(String(format: "PRECOMPOSE PRUNE: deleted %d files (%.1f MB), kept %d in use, playlist_* files: %d", deleted, freedMB, kept, playlistFiles))
        return (deleted, freedBytes, kept)
    }

    /// A cached stitch with ~zero duration (or size) is a header-only artifact,
    /// e.g. from a render interrupted by app death; AlarmKit would ring it silent.
    private func validateCachedStitch(_ url: URL) -> Bool {
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size >= 1_000 else { return false }
        guard let metadata = audioMetadata(for: url), metadata.duration > 0.5 else { return false }
        return true
    }

    /// Experimental: re-render a WAV stitch as compressed CAF (IMA4) so the
    /// Diagnostics screen can measure whether AlarmKit accepts a compressed
    /// floor sound. Measurement only — the production format is unchanged.
    func renderCAFIma4(from wavURL: URL) async throws -> URL {
        guard let processedDir = processedSoundsDirectory else {
            throw AudioProcessingError.processedDirectoryUnavailable
        }
        let cafName = (wavURL.lastPathComponent as NSString).deletingPathExtension + ".caf"
        let cafURL = processedDir.appendingPathComponent(cafName)
        try? fileManager.removeItem(at: cafURL)

        return try await Task.detached(priority: .userInitiated) { [wavURL, cafURL] in
            let source = try AVAudioFile(forReading: wavURL)
            let sourceFormat = source.processingFormat

            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatAppleIMA4,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: sourceFormat.channelCount
            ]
            let outputFile = try AVAudioFile(forWriting: cafURL, settings: outputSettings)
            let destinationFormat = outputFile.processingFormat

            if sourceFormat == destinationFormat {
                let chunkFrames: AVAudioFrameCount = 262_144
                guard let chunk = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
                    throw AudioProcessingError.bufferCreationFailed
                }
                while true {
                    try source.read(into: chunk, frameCount: chunkFrames)
                    if chunk.frameLength == 0 { break }
                    try outputFile.write(from: chunk)
                    if chunk.frameLength < chunkFrames { break }
                }
            } else {
                guard let converter = try? AVAudioConverter(from: sourceFormat, to: destinationFormat) else {
                    throw AudioProcessingError.processingFailed("IMA4 converter unavailable")
                }
                let srcChunkFrames: AVAudioFrameCount = 262_144
                guard let srcChunk = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: srcChunkFrames) else {
                    throw AudioProcessingError.bufferCreationFailed
                }
                var reachedEOF = false

                let inputBlock: AVAudioConverterInputBlock = { _, status in
                    if reachedEOF {
                        status.pointee = .endOfStream
                        return nil
                    }
                    do {
                        try source.read(into: srcChunk, frameCount: srcChunkFrames)
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
                    guard let dstChunk = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: dstCapacity) else { break }
                    var convertError: NSError?
                    let status = converter.convert(to: dstChunk, error: &convertError, withInputFrom: inputBlock)
                    if status == .error { break }
                    if dstChunk.frameLength > 0 {
                        try outputFile.write(from: dstChunk)
                    }
                    if status == .endOfStream { break }
                }
            }

            guard outputFile.length > 0 else {
                throw AudioProcessingError.processingFailed("CAF render produced no audio")
            }
            return cafURL
        }.value
    }

    /// Precompose a playlist into a single WAV file for AlarmKit
    /// Selects multiple random songs (or uses sequence order), concatenates them with loudness applied
    /// Returns the URL of the combined file
    /// If maxDuration is provided, the total duration is capped at that value (for backup alarms)
    func precomposePlaylist(
        playlistID: UUID,
        loudness: AlarmLoudness,
        songCount: Int = 5,
        alarmID: UUID? = nil,
        maxDuration: TimeInterval? = nil,  // Cap total duration (e.g., 60s for backup alarms)
        forcedSelection: [UUID]? = nil,  // Arming path passes a freshly rolled selection so each ring differs
        protectedFileNames: Set<String> = []  // Files the armed set still references - never deleted here
    ) async throws -> (URL, PlaylistDiagnostics.PreparationEntry, PlaylistDiagnostics.GeneratedFileEntry) {
        // Capture MainActor-isolated values before detaching
        let soundsDir = SoundLibrary.shared.soundsDirectory
        let processedDir = processedSoundsDirectory
        let playlist = try SoundLibrary.shared.playlist(for: playlistID)
        
        // TASK 4: Self-heal playlists - remove missing IDs before building track list
        SoundLibrary.shared.selfHealPlaylists()
        
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

        let preparationStartTime = Date()

        // Sticky random selection: reuse the already-rendered precomposed file
        // for this (playlist, loudness, cap) instead of re-rolling songs on
        // every call. Re-rolling produced a new selection hash each time ->
        // cache miss -> full WAV re-render during every save. A new selection
        // happens only after the file is deleted (playlist edit) or loudness
        // changes.
        // BYPASS sticky finder when forcedSelection is provided (arming path),
        // because the filename already encodes the selection hash, so it's a
        // natural cache miss. Sticky reuse must only apply to the save path.
        var stickyHit: URL?
        let useStickyFinder = forcedSelection == nil && playlist.playOrder != .sequence
        if useStickyFinder,
           let sticky = findStickyPrecomposedFile(
            playlistName: playlistName,
            playlistID: playlistID,
            loudness: loudness,
            maxDuration: maxDuration) {
            if validateCachedStitch(sticky) {
                stickyHit = sticky
            } else {
                // Empty/corrupt artifact; AlarmKit would ring silent. Delete and re-render.
                SmartWakeDebugLog.log("PRECOMPOSE: cached stitch invalid (empty) — deleting \(sticky.lastPathComponent)")
                try? fileManager.removeItem(at: sticky)
            }
        }
        if let sticky = stickyHit {
            let metadata = audioMetadata(for: sticky)
            let preparationEndTime = Date()
            let preparationEntry = PlaylistDiagnostics.PreparationEntry(
                timestamp: preparationStartTime,
                alarmID: alarmID ?? UUID(),
                playlistID: playlistID,
                playlistName: playlistName,
                totalSongsInPlaylist: playlist.soundIDs.count,
                selectedSongCount: 0,
                selectedSongIDs: [],
                selectedSongNames: [],
                selectedSongDurations: [],
                expectedTotalDuration: metadata?.duration ?? 0,
                loudnessPercentage: loudness.percentage,
                usedProcessedAudio: true,
                preparationStartTime: preparationStartTime,
                preparationEndTime: preparationEndTime,
                preparationDuration: preparationEndTime.timeIntervalSince(preparationStartTime),
                success: true,
                error: nil
            )
            let fileSize = (try? fileManager.attributesOfItem(atPath: sticky.path)[.size] as? Int64) ?? 0
            let formatString = Self.useCAFFormat ? "CAF" : "WAV"
            let generatedFileEntry = PlaylistDiagnostics.GeneratedFileEntry(
                timestamp: Date(),
                playlistID: playlistID,
                fileExists: true,
                fileSizeBytes: fileSize,
                audioFormat: formatString,
                sampleRate: metadata?.sampleRate ?? 0,
                channelCount: metadata?.channelCount ?? 0,
                actualDuration: metadata?.duration ?? 0,
                expectedDuration: metadata?.duration ?? 0,
                fileReadable: metadata != nil,
                appearsComplete: metadata != nil
            )
            SmartWakeDebugLog.log("PRECOMPOSE: sticky reuse for save path \(sticky.lastPathComponent) (no re-render)")
            return (sticky, preparationEntry, generatedFileEntry)
        }
        
        // If we get here, either forcedSelection was provided (arming path) or no sticky file found
        if forcedSelection != nil {
            SmartWakeDebugLog.log("PRECOMPOSE: used fresh render for arming path (forcedSelection provided)")
        }

        // Select songs based on play order: random or sequence. The arming path
        // may force a freshly rolled selection so each ring differs.
        let selectedSoundIDs: [UUID]
        if let forcedSelection {
            selectedSoundIDs = forcedSelection
        } else if playlist.playOrder == .sequence {
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
        let capPart = maxDuration.map { "_cap\(Int($0))" } ?? ""
        let outputExtension = Self.useCAFFormat ? "caf" : "wav"
        let precomposedFileName = "playlist_\(playlistName)_\(playlistID.uuidString.prefix(8))_\(selectionHash)_\(loudness.percentage)pct\(capPart).\(outputExtension)"
        let precomposedURL = processedDir.appendingPathComponent(precomposedFileName)
        
        // If already exists for THIS specific selection, return it
        if fileManager.fileExists(atPath: precomposedURL.path)
            && !validateCachedStitch(precomposedURL) {
            // Empty/corrupt artifact: delete and re-render instead of returning
            // a file AlarmKit would ring silent.
            SmartWakeDebugLog.log("PRECOMPOSE: cached stitch invalid (empty) — deleting \(precomposedFileName) and re-rendering")
            try? fileManager.removeItem(at: precomposedURL)
        }
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
            let formatString = Self.useCAFFormat ? "CAF" : "WAV"
            let generatedFileEntry = PlaylistDiagnostics.GeneratedFileEntry(
                timestamp: Date(),
                playlistID: playlistID,
                fileExists: true,
                fileSizeBytes: fileSize,
                audioFormat: formatString,
                sampleRate: metadata?.sampleRate ?? 0,
                channelCount: metadata?.channelCount ?? 0,
                actualDuration: actualDuration,
                expectedDuration: expectedTotalDuration,
                fileReadable: metadata != nil,
                appearsComplete: metadata.map { abs($0.duration - expectedTotalDuration) < 1.0 } ?? false
            )
            
            return (precomposedURL, preparationEntry, generatedFileEntry)
        }
        
        // Concatenate songs into a single CAF/IMA4 by streaming each song's frames
        // to disk as they are read. Holding every song's PCM in one buffer
        // peaked at hundreds of MB and got the app killed (jetsam) mid-commit.
        // Memory stays at a few chunk buffers regardless of song count/length.
        // Songs are converted to the output format (44.1k stereo) with
        // AVAudioConverter so mixed-rate/mono MP3s still play at correct speed.
        // CAF/IMA4 is ~3.8× smaller than WAV and plays on device.
        let resultURL = try await Task.detached(priority: .userInitiated) { [soundsDir, processedDir, selectedSoundIDs, loudness, precomposedURL, playlistName, playlistID, fileManager, importedSounds, outputExtension] in
            let outputFileURL = precomposedURL.deletingPathExtension().appendingPathExtension(outputExtension)
            let outputSettings: [String: Any]
            if Self.useCAFFormat {
                outputSettings = [
                    AVFormatIDKey: kAudioFormatAppleIMA4,
                    AVSampleRateKey: 44_100.0,
                    AVNumberOfChannelsKey: 2
                ]
            } else {
                outputSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44_100.0,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            }

            let outputFile = try AVAudioFile(forWriting: outputFileURL, settings: outputSettings)
            let outputFormat = outputFile.processingFormat
            let gain = Float(loudness.gainFactor)
            var appendedSongs = 0
            var framesRemaining: Int64? = maxDuration.map { Int64($0 * outputFormat.sampleRate) }
            // Spread the cap evenly across the selected songs so the capped
            // floor stitch keeps the playlist's variety (cap/selectedCount per
            // song) instead of one song's opening seconds.
            let perSongFrames: Int64? = maxDuration.map { cap in
                Int64(cap * outputFormat.sampleRate) / Int64(max(selectedSoundIDs.count, 1))
            }
            var songFramesRemaining: Int64? = nil
            var capReached = false
            var songCapReached = false
            var currentSongHasFrames = false

            // Writes a chunk, clamped by the total cap and the per-song share.
            // Truncate rather than skip so a capped stitch always contains audio
            // from every selected song; otherwise AlarmKit's guaranteed fallback
            // could ring silent or lose the playlist's variety.
            func writeClamped(_ buffer: AVAudioPCMBuffer) throws {
                if let remaining = framesRemaining, remaining <= 0 {
                    capReached = true
                    return
                }
                if let songRemaining = songFramesRemaining, songRemaining <= 0 {
                    songCapReached = true
                    return
                }
                let length = Int(buffer.frameLength)
                var toWrite = framesRemaining.map { min(Int64(length), $0) } ?? Int64(length)
                if let songRemaining = songFramesRemaining {
                    toWrite = min(toWrite, songRemaining)
                }
                guard toWrite > 0 else { return }
                let out: AVAudioPCMBuffer
                if toWrite == Int64(length) {
                    out = buffer
                } else {
                    guard let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(toWrite)) else {
                        throw AudioProcessingError.bufferCreationFailed
                    }
                    for channel in 0..<Int(buffer.format.channelCount) {
                        guard let src = buffer.floatChannelData?[channel],
                              let dst = trimmed.floatChannelData?[channel] else { continue }
                        memcpy(dst, src, Int(toWrite) * MemoryLayout<Float>.stride)
                    }
                    trimmed.frameLength = AVAudioFrameCount(toWrite)
                    out = trimmed
                }
                if gain != 1.0 {
                    let channels = Int(out.format.channelCount)
                    let frames = Int(out.frameLength)
                    for channel in 0..<channels {
                        guard let channelData = out.floatChannelData?[channel] else { continue }
                        for frame in 0..<frames {
                            channelData[frame] *= gain
                        }
                    }
                }
                try outputFile.write(from: out)
                if !currentSongHasFrames {
                    currentSongHasFrames = true
                    appendedSongs += 1
                }
                if let remaining = framesRemaining {
                    let left = remaining - toWrite
                    framesRemaining = left
                    if left <= 0 { capReached = true }
                }
                if let songRemaining = songFramesRemaining {
                    let songLeft = songRemaining - toWrite
                    songFramesRemaining = songLeft
                    if songLeft <= 0 { songCapReached = true }
                }
            }

            songLoop: for soundID in selectedSoundIDs {
                guard let sound = importedSounds.first(where: { $0.id == soundID }),
                      let soundURL = sound.localURL(soundsDirectory: soundsDir),
                      fileManager.fileExists(atPath: soundURL.path) else {
                    continue
                }

                currentSongHasFrames = false
                songCapReached = false
                songFramesRemaining = perSongFrames
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
                            try writeClamped(chunk)
                            if capReached { break songLoop }
                            if songCapReached { break }
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
                                try writeClamped(dstChunk)
                            }
                            if capReached { break songLoop }
                            if songCapReached { break }
                            if status == .endOfStream { break }
                            if dstChunk.frameLength == 0 && status == .haveData { continue }
                            if dstChunk.frameLength < dstCapacity && status == .haveData { continue }
                        }
                    }
                } catch {
                    // Skip unreadable/corrupt song instead of failing the whole playlist.
                    continue
                }
            }

            let totalFrames = outputFile.length
            guard totalFrames > 0, appendedSongs > 0 else {
                try? fileManager.removeItem(at: outputFileURL)
                let capText = maxDuration.map { "\(Int($0))s" } ?? "none"
                throw AudioProcessingError.processingFailed("Stitch rendered with no audio (songs=\(selectedSoundIDs.count), cap=\(capText))")
            }

            if let cap = maxDuration {
                let totalSeconds = Double(totalFrames) / outputFormat.sampleRate
                let bytes = (try? fileManager.attributesOfItem(atPath: outputFileURL.path)[.size] as? Int64) ?? 0
                let shareText = perSongFrames.map { String(format: "%.1fs", Double($0) / outputFormat.sampleRate) } ?? "none"
                let truncated = capReached ? String(format: "%.1fs", totalSeconds) : "none"
                let formatText = Self.useCAFFormat ? "CAF" : "WAV"
                SmartWakeDebugLog.log(String(format: "PRECOMPOSE: cap=%.0fs share=%@ songs=%d truncatedAt=%@ total=%.1fs bytes=%lld format=%@", cap, shareText, appendedSongs, truncated, totalSeconds, bytes, formatText))
            }

            return outputFileURL
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
        
        // Use the actual output file URL (could be .caf or .wav)
        let outputURL = resultURL
        let fileExists = fileManager.fileExists(atPath: outputURL.path)
        let fileSize = (try? fileManager.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let metadata = audioMetadata(for: outputURL)
        let actualDuration = metadata?.duration ?? 0
        let formatString = Self.useCAFFormat ? "CAF" : "WAV"
        let generatedFileEntry = PlaylistDiagnostics.GeneratedFileEntry(
            timestamp: Date(),
            playlistID: playlistID,
            fileExists: fileExists,
            fileSizeBytes: fileSize,
            audioFormat: formatString,
            sampleRate: metadata?.sampleRate ?? 0,
            channelCount: metadata?.channelCount ?? 0,
            actualDuration: actualDuration,
            expectedDuration: expectedTotalDuration,
            fileReadable: metadata != nil,
            appearsComplete: metadata.map { abs($0.duration - expectedTotalDuration) < 1.0 } ?? false
        )
        
        // Cleanup: delete old precomposed files for this playlist+loudness that don't match current selection.
        // Never delete a file the currently armed set still references - AlarmKit
        // plays by filename; the armed-aware prune removes them once unused.
        let patternPrefix = "playlist_\(playlistName)_\(playlistID.uuidString.prefix(8))_"
        let patternSuffix = "_\(loudness.percentage)pct\(capPart).\(outputExtension)"
        let allFiles = (try? fileManager.contentsOfDirectory(at: processedDir, includingPropertiesForKeys: nil)) ?? []
        for file in allFiles {
            let fileName = file.lastPathComponent
            if fileName.hasPrefix(patternPrefix) && fileName.hasSuffix(patternSuffix) && fileName != outputURL.lastPathComponent && !protectedFileNames.contains(fileName) {
                try? fileManager.removeItem(at: file)
            }
        }
        
        return (outputURL, preparationEntry, generatedFileEntry)
    }
    
    /// Find an existing precomposed file for this (playlist, loudness, cap)
    /// regardless of which random selection produced it. Used to keep saves
    /// zero-audio-work; a fresh selection is made only when none exists.
    private func findStickyPrecomposedFile(
        playlistName: String,
        playlistID: UUID,
        loudness: AlarmLoudness,
        maxDuration: TimeInterval?
    ) -> URL? {
        guard let dir = processedSoundsDirectory else { return nil }
        let prefix = "playlist_\(playlistName)_\(playlistID.uuidString.prefix(8))_"
        let capPart = maxDuration.map { "_cap\(Int($0))" } ?? ""
        let outputExtension = Self.useCAFFormat ? "caf" : "wav"
        let suffix = "_\(loudness.percentage)pct\(capPart).\(outputExtension)"
        let allFiles = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [URLResourceKey.contentModificationDateKey]
        )) ?? []
        return allFiles
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(suffix) }
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
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
        let outputExtension = Self.useCAFFormat ? "caf" : "wav"

        let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("playlist_")
            && file.lastPathComponent.contains(identifier)
            && file.lastPathComponent.hasSuffix("pct.\(outputExtension)") {
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