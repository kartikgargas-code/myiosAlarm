import Foundation

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
        }
    }
}

@MainActor
@Observable
final class SoundLibrary {
    static let shared = SoundLibrary()

    private(set) var importedSounds: [ImportedSound] = []
    private let fileManager = FileManager.default
    private let displayNameKey = "importedSoundDisplayNames"

    var soundsDirectory: URL? {
        // AlarmKit custom sounds must live in the app container Library/Sounds.
        fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    private init() {
        createSoundsDirectory()
        loadSounds()
    }

    private func createSoundsDirectory() {
        guard let dir = soundsDirectory else { return }
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
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

    func importMP3(from sourceURL: URL) async throws -> ImportedSound {
        guard let soundsDir = soundsDirectory else {
            throw SoundLibraryError.importFailed("Library/Sounds is unavailable.")
        }

        let baseName = sanitizedFileName(sourceURL.deletingPathExtension().lastPathComponent)
        let ext = sourceURL.pathExtension.lowercased()
        let stableFileName = "\(baseName)_\(UUID().uuidString.lowercased()).\(ext)"
        let destURL = soundsDir.appendingPathComponent(stableFileName)
        let displayName = sourceURL.deletingPathExtension().lastPathComponent

        let copied: (fileName: String, bytes: Int) = try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() } }

            try fileManager.createDirectory(at: soundsDir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destURL)
            let size = (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
            return (stableFileName, size)
        }.value

        let sound = ImportedSound(
            id: stableID(for: copied.fileName),
            name: displayName,
            fileName: copied.fileName
        )
        importedSounds.insert(sound, at: 0)
        return sound
    }

    func deleteSound(_ sound: ImportedSound, referencedBy alarms: [AlarmRecord]) {
        guard !isReferenced(sound, by: alarms) else { return }
        if let localURL = sound.localURL(soundsDirectory: soundsDirectory) {
            try? fileManager.removeItem(at: localURL)
        }
        removeDisplayNameOverride(for: sound.fileName)
        importedSounds.removeAll { $0.id == sound.id }
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
        guard let url = sound.localURL(soundsDirectory: soundsDirectory),
              fileManager.fileExists(atPath: url.path) else {
            throw SoundLibraryError.soundFileMissing(sound.fileName)
        }
        return sound.fileName
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