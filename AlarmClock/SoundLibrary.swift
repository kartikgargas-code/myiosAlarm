import Foundation
import AVFoundation

/// File name for the silent companion alarm sound (near-silent WAV, >=1s)
let silentCompanionFileName = "silent_companion.wav"

struct ImportedSound: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var fileName: String
    var duration: TimeInterval?
    var dateAdded: Date

    init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        duration: TimeInterval? = nil,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.duration = duration
        self.dateAdded = dateAdded
    }

    func localURL(soundsDirectory: URL?) -> URL? {
        guard let soundsDirectory else { return nil }
        return soundsDirectory.appendingPathComponent(fileName)
    }
}

enum SoundLibraryError: LocalizedError, Equatable {
    case importedSoundNotFound(UUID)
    case soundFileMissing(String)
    case builtInSoundMissing(String)
    case importFailed(String)
    case playlistNotFound(UUID)
    case emptyPlaylist(UUID)
    case folderImportFailed(String)

    var errorDescription: String? {
        switch self {
        case .importedSoundNotFound(let id):
            "The imported sound \(id.uuidString) is no longer available."
        case .soundFileMissing(let fileName):
            "The custom alarm sound file \(fileName) is missing from Library/Sounds."
        case .builtInSoundMissing(let name):
            "Built-in sound \(name) has no bundled audio resource."
        case .importFailed(let message):
            "MP3 import failed: \(message)"
        case .playlistNotFound(let id):
            "The playlist \(id.uuidString) is no longer available."
        case .emptyPlaylist(let id):
            "The playlist \(id.uuidString) contains no sounds."
        case .folderImportFailed(let message):
            "Folder import failed: \(message)"
        }
    }
}

@MainActor
@Observable
final class SoundLibrary {
    static let shared = SoundLibrary()

    private(set) var importedSounds: [ImportedSound] = []
    private(set) var playlists: [Playlist] = []
    private let fileManager = FileManager.default
    private let displayNameKey = "importedSoundDisplayNames"
    private let playlistKey = "playlists"

    var soundsDirectory: URL? {
        // AlarmKit custom sounds must live in the app container Library/Sounds.
        fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    private init() {
        createSoundsDirectory()
        ensureSilentCompanionSound()
        loadSounds()
        loadPlaylists()
    }

    private func createSoundsDirectory() {
        guard let dir = soundsDirectory else { return }
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Ensure the silent companion WAV exists in Library/Sounds for AlarmKit companion alarms
    private func ensureSilentCompanionSound() {
        guard let soundsDir = soundsDirectory else { return }
        let silentURL = soundsDir.appendingPathComponent(silentCompanionFileName)
        
        if fileManager.fileExists(atPath: silentURL.path) {
            return
        }

        // Generate a 1-second near-silent WAV file programmatically (reuse SmartWakeService approach)
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.generateSilentCompanionSound(at: silentURL)
        }
    }

    private func generateSilentCompanionSound(at url: URL) async {
        let sampleRate = 44100.0
        let duration = 1.5 // 1.5 seconds to ensure >=1s
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            os_log(.error, log: OSLog(subsystem: "com.example.alarmclock", category: "SoundLibrary"), "Failed to create silent companion buffer")
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
            os_log(.info, log: OSLog(subsystem: "com.example.alarmclock", category: "SoundLibrary"), "Generated silent companion sound at %{public}s", url.path)
        } catch {
            os_log(.error, log: OSLog(subsystem: "com.example.alarmclock", category: "SoundLibrary"), "Failed to generate silent companion sound: %{public}s", error.localizedDescription)
        }
    }

    private func loadSounds() {
        guard let dir = soundsDirectory else { return }
        do {
            let files = try fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]
            )
            let displayNames = savedDisplayNames()
            importedSounds = files.compactMap { url in
                guard url.pathExtension.lowercased() == "mp3" else { return nil }
                let attrs = try? fileManager.attributesOfItem(atPath: url.path)
                let creationDate = attrs?[.creationDate] as? Date ?? Date()
                return ImportedSound(
                    id: stableID(for: url.lastPathComponent),
                    name: displayNames[url.lastPathComponent] ?? url.deletingPathExtension().lastPathComponent,
                    fileName: url.lastPathComponent,
                    duration: nil,
                    dateAdded: creationDate
                )
            }.sorted { $0.dateAdded > $1.dateAdded }
        } catch {
            importedSounds = []
        }
    }

    private func loadPlaylists() {
        guard let data = UserDefaults.standard.data(forKey: playlistKey),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else {
            playlists = []
            return
        }
        playlists = decoded
    }

    private func savePlaylists() {
        if let encoded = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(encoded, forKey: playlistKey)
        }
    }

    func importMP3(from sourceURL: URL) async throws -> ImportedSound {
        guard let soundsDir = soundsDirectory else {
            throw SoundLibraryError.importFailed("Library/Sounds is unavailable.")
        }

        let baseName = sanitizedFileName(sourceURL.deletingPathExtension().lastPathComponent)
        let ext = sourceURL.pathExtension.lowercased()
        let stableFileName = "\(baseName)_\(UUID().uuidString.lowercased()).\(ext)"
        let destURL = soundsDir.appendingPathComponent(stableFileName)
        let displayName = sourceURL.deletingPathExtension().lastPathComponent

        let copied: (fileName: String, bytes: Int, duration: TimeInterval?) = try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() } }

            try fileManager.createDirectory(at: soundsDir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destURL)
            let size = (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
            
            // Read duration from the audio file. Some MP3s (odd headers/VBR)
            // defeat AVAudioFile's length estimate; fall back to AVURLAsset.
            var duration: TimeInterval? = nil
            do {
                let audioFile = try AVAudioFile(forReading: destURL)
                let sampleRate = audioFile.processingFormat.sampleRate
                let frameCount = audioFile.length
                if sampleRate > 0, frameCount > 0 {
                    duration = Double(frameCount) / sampleRate
                }
            } catch {
                // Duration reading failed, try asset fallback below
            }
            if duration == nil || duration == 0 {
                let asset = AVURLAsset(url: destURL)
                if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
                    duration = seconds
                }
            }
            
            return (stableFileName, size, duration)
        }.value

        let sound = ImportedSound(
            id: stableID(for: copied.fileName),
            name: displayName,
            fileName: copied.fileName,
            duration: copied.duration
        )
        importedSounds.insert(sound, at: 0)
        return sound
    }

    func importFolder(from sourceURL: URL) async throws -> Playlist {
        guard let soundsDir = soundsDirectory else {
            throw SoundLibraryError.folderImportFailed("Library/Sounds is unavailable.")
        }

        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let folderName = sourceURL.lastPathComponent
        var importedSoundInfos: [(id: UUID, name: String, fileName: String, duration: TimeInterval?)] = []
        var errors: [String] = []

        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: soundsDir, withIntermediateDirectories: true)

            let fileURLs = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            let mp3Files = fileURLs.filter { $0.pathExtension.lowercased() == "mp3" }

            for sourceFileURL in mp3Files {
                do {
                    let baseName = sanitizedFileName(sourceFileURL.deletingPathExtension().lastPathComponent)
                    let ext = sourceFileURL.pathExtension.lowercased()
                    let stableFileName = "\(baseName)_\(UUID().uuidString.lowercased()).\(ext)"
                    let destURL = soundsDir.appendingPathComponent(stableFileName)
                    let displayName = sourceFileURL.deletingPathExtension().lastPathComponent

                    if fileManager.fileExists(atPath: destURL.path) {
                        try fileManager.removeItem(at: destURL)
                    }
                    try fileManager.copyItem(at: sourceFileURL, to: destURL)

                    // Read duration from the audio file (asset fallback for
                    // MP3s whose length AVAudioFile can't estimate)
                    var duration: TimeInterval? = nil
                    do {
                        let audioFile = try AVAudioFile(forReading: destURL)
                        let sampleRate = audioFile.processingFormat.sampleRate
                        let frameCount = audioFile.length
                        if sampleRate > 0, frameCount > 0 {
                            duration = Double(frameCount) / sampleRate
                        }
                    } catch {
                        // Duration reading failed, asset fallback below
                    }
                    if duration == nil || duration == 0 {
                        let asset = AVURLAsset(url: destURL)
                        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
                            duration = seconds
                        }
                    }

                    let id = stableID(for: stableFileName)
                    importedSoundInfos.append((id: id, name: displayName, fileName: stableFileName, duration: duration))
                } catch {
                    errors.append("\(sourceFileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            throw SoundLibraryError.folderImportFailed("Failed to read folder: \(error.localizedDescription)")
        }

        guard !importedSoundInfos.isEmpty else {
            throw SoundLibraryError.folderImportFailed("No valid MP3 files found in folder.")
        }

        // Update @MainActor state
        await MainActor.run {
            let importedSoundIDs = importedSoundInfos.map { $0.id }
            for info in importedSoundInfos {
                let sound = ImportedSound(
                    id: info.id,
                    name: info.name,
                    fileName: info.fileName,
                    duration: info.duration
                )
                self.importedSounds.insert(sound, at: 0)
            }

            let playlist = Playlist(
                name: folderName,
                soundIDs: importedSoundIDs,
                selectedSoundIDs: importedSoundIDs  // All songs selected by default
            )
            self.playlists.append(playlist)
            self.savePlaylists()
        }

        if !errors.isEmpty {
            print("Folder import completed with \(errors.count) errors: \(errors.joined(separator: "; "))")
        }

        // Return the playlist (we need to fetch it)
        let playlist = try await MainActor.run {
            guard let p = self.playlists.first(where: { $0.name == folderName }) else {
                throw SoundLibraryError.folderImportFailed("Failed to create playlist.")
            }
            return p
        }
        return playlist
    }

    func createPlaylist(name: String, soundIDs: [UUID]) -> Playlist {
        let playlist = Playlist(name: name, soundIDs: soundIDs)
        playlists.append(playlist)
        savePlaylists()
        return playlist
    }

    func deletePlaylist(_ playlist: Playlist, referencedBy alarms: [AlarmRecord]) -> SoundLibraryError? {
        let referencingAlarms = alarms.filter { alarm in
            switch alarm.sound {
            case .random(let playlistID), .precomposedPlaylist(let playlistID, _):
                return playlistID == playlist.id
            default:
                return false
            }
        }

        if !referencingAlarms.isEmpty {
            return SoundLibraryError.importFailed("Playlist is used by \(referencingAlarms.count) alarm(s). Remove or change those alarms first.")
        }

        AudioProcessingService.shared.removePrecomposedPlaylist(for: playlist.id)
        playlists.removeAll { $0.id == playlist.id }
        savePlaylists()
        return nil
    }

    func updatePlaylist(_ playlist: Playlist, newName: String? = nil, newSoundIDs: [UUID]? = nil) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        if let newName {
            playlists[index].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let newSoundIDs {
            playlists[index].soundIDs = newSoundIDs
        }
        playlists[index].selectedSoundIDs = playlist.selectedSoundIDs
        AudioProcessingService.shared.removePrecomposedPlaylist(for: playlist.id)
        savePlaylists()
    }

    func deleteSound(_ sound: ImportedSound, referencedBy alarms: [AlarmRecord]) {
        guard !isReferenced(sound, by: alarms) else { return }
        AudioProcessingService.shared.removeProcessedSounds(for: sound)
        if let localURL = sound.localURL(soundsDirectory: soundsDirectory) {
            try? fileManager.removeItem(at: localURL)
        }
        removeDisplayNameOverride(for: sound.fileName)
        importedSounds.removeAll { $0.id == sound.id }

        // Remove from any playlists
        for i in playlists.indices {
            playlists[i].soundIDs.removeAll { $0 == sound.id }
        }
        savePlaylists()
    }

    func renameSound(_ sound: ImportedSound, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = importedSounds.firstIndex(where: { $0.id == sound.id }) else { return }
        importedSounds[index].name = trimmed
        setDisplayNameOverride(trimmed, for: sound.fileName)
    }

    func alarmKitFileName(for id: UUID) throws -> String {
        guard let sound = importedSounds.first(where: { $0.id == id }) else {
            throw SoundLibraryError.importedSoundNotFound(id)
        }
        let url = sound.localURL(soundsDirectory: soundsDirectory)
        guard let url, fileManager.fileExists(atPath: url.path) else {
            throw SoundLibraryError.soundFileMissing(sound.fileName)
        }
        return sound.fileName
    }

    /// Get the silent companion alarm sound file name for AlarmKit
    /// This is a near-silent WAV file (>=1s) in Library/Sounds for companion alarms
    func silentCompanionAlarmKitFileName() -> String {
        return silentCompanionFileName
    }

    func playlist(for id: UUID) throws -> Playlist {
        guard let playlist = playlists.first(where: { $0.id == id }) else {
            throw SoundLibraryError.playlistNotFound(id)
        }
        let soundIDs = playlist.soundIDs
        guard !soundIDs.isEmpty else {
            throw SoundLibraryError.emptyPlaylist(id)
        }
        return playlist
    }

    func isReferenced(_ sound: ImportedSound, by alarms: [AlarmRecord]) -> Bool {
        alarms.contains { $0.sound == .imported(sound.id) }
    }

    private func sanitizedFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return result.isEmpty ? "alarm-sound" : result
    }

    private func stableID(for fileName: String) -> UUID {
        StableOccurrenceID.make(
            alarmID: UUID(uuidString: "b23f4a5e-cc2f-4e71-9cde-979301000001")!,
            occurrenceKey: fileName
        )
    }

    private func savedDisplayNames() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: displayNameKey) as? [String: String]) ?? [:]
    }

    private func setDisplayNameOverride(_ name: String, for fileName: String) {
        var overrides = savedDisplayNames()
        overrides[fileName] = name
        UserDefaults.standard.set(overrides, forKey: displayNameKey)
    }

    private func removeDisplayNameOverride(for fileName: String) {
        var overrides = savedDisplayNames()
        overrides[fileName] = nil
        UserDefaults.standard.set(overrides, forKey: displayNameKey)
    }
}