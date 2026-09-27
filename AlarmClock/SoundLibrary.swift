import Foundation
import UniformTypeIdentifiers

struct ImportedSound: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var fileName: String
    var fileURL: URL?
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

@MainActor
@Observable
final class SoundLibrary {
    static let shared = SoundLibrary()

    private(set) var importedSounds: [ImportedSound] = []
    private let fileManager = FileManager.default
    private let soundsDirectoryName = "Sounds"

    var soundsDirectory: URL? {
        // Use Library/Sounds for AlarmKit custom sounds
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
            let files = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])
            importedSounds = files.compactMap { url in
                guard url.pathExtension.lowercased() == "mp3" else { return nil }
                let attrs = try? fileManager.attributesOfItem(atPath: url.path)
                let creationDate = attrs?[.creationDate] as? Date ?? Date()
                return ImportedSound(
                    id: stableID(for: url.lastPathComponent),
                    name: url.deletingPathExtension().lastPathComponent,
                    fileName: url.lastPathComponent,
                    duration: nil,
                    dateAdded: creationDate
                )
            }.sorted { $0.dateAdded > $1.dateAdded }
        } catch {
            importedSounds = []
        }
    }

    func importMP3(from sourceURL: URL, accessGranted: Bool = false) async -> ImportedSound? {
        guard accessGranted || sourceURL.startAccessingSecurityScopedResource() else {
            return nil
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }

        guard let soundsDir = soundsDirectory else { return nil }

        // Generate stable unique filename
        let baseName = sanitizedFileName(sourceURL.deletingPathExtension().lastPathComponent)
        let ext = sourceURL.pathExtension.lowercased()
        let stableFileName = "\(baseName)_\(UUID().uuidString.lowercased()).\(ext)"
        let destURL = soundsDir.appendingPathComponent(stableFileName)

        do {
            // Ensure directory exists
            try fileManager.createDirectory(at: soundsDir, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destURL)

            let sound = ImportedSound(
                id: stableID(for: stableFileName),
                name: sourceURL.deletingPathExtension().lastPathComponent,
                fileName: stableFileName
            )
            importedSounds.insert(sound, at: 0)
            return sound
        } catch {
            return nil
        }
    }

    func deleteSound(_ sound: ImportedSound, referencedBy alarms: [AlarmRecord]) {
        guard !isReferenced(sound, by: alarms) else { return }
        guard let localURL = sound.localURL(soundsDirectory: soundsDirectory) else { return }
        try? fileManager.removeItem(at: localURL)
        importedSounds.removeAll { $0.id == sound.id }
    }

    func renameSound(_ sound: ImportedSound, newName: String) {
        guard let localURL = sound.localURL(soundsDirectory: soundsDirectory),
              let soundsDir = soundsDirectory else { return }

        let ext = localURL.pathExtension
        let newFileName = "\(newName).\(ext)"
        let newURL = soundsDir.appendingPathComponent(newFileName)

        guard !fileManager.fileExists(atPath: newURL.path) else { return }

        do {
            try fileManager.moveItem(at: localURL, to: newURL)
            if let index = importedSounds.firstIndex(where: { $0.id == sound.id }) {
                importedSounds[index].name = newName
                importedSounds[index].fileName = newFileName
            }
        } catch {
            // ignore
        }
    }

    func getAlarmKitSoundURL(for sound: ImportedSound) -> URL? {
        return sound.localURL(soundsDirectory: soundsDirectory)
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
}

enum SoundLibraryError: LocalizedError, Equatable {
    case importedSoundNotFound(UUID)
    case soundFileMissing(String)

    var errorDescription: String? {
        switch self {
        case .importedSoundNotFound(let id):
            "The imported sound \(id.uuidString) is no longer available."
        case .soundFileMissing(let fileName):
            "The custom alarm sound file \(fileName) is missing from Library/Sounds."
        }
    }
}

// Document picker support
import SwiftUI

struct MP3DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.mp3, UTType.audio])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}