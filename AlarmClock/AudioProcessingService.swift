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
        // Processed files are always WAV
        let processedFileName = "\(baseName)_\(loudness.rawValue)pct.wav"
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
        // Use WAV extension for processed files since AVAudioFile doesn't support MP3 encoding
        let processedFileName = "\(baseName)_\(loudness.rawValue)pct.wav"
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

    /// Clean up processed sounds for a deleted original sound
    func removeProcessedSounds(for originalSound: ImportedSound) {
        guard let dir = processedSoundsDirectory else { return }
        let baseName = (originalSound.fileName as NSString).deletingPathExtension

        for loudness in AlarmLoudness.allCases {
            let processedFileName = "\(baseName)_\(loudness.rawValue)pct.wav"
            let url = dir.appendingPathComponent(processedFileName)
            try? fileManager.removeItem(at: url)
        }
    }

    /// Clean up all processed sounds
    func removeAllProcessedSounds() {
        guard let dir = processedSoundsDirectory else { return }
        try? fileManager.removeItem(at: dir)
        createProcessedSoundsDirectory()
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