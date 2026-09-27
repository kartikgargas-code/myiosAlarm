import Foundation
import UniformTypeIdentifiers

struct ImportedSound: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var fileName: String
    var fileURL: URL?
    var duration: TimeInterval?
    var dateAdded: Date

    init(id: UUID = UUID(), name: String, fileName: String, duration: TimeInterval? = nil) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.duration = duration
        self.dateAdded = Date()
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
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(soundsDirectoryName, isDirectory: true)
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
                    name: url.deletingPathExtension().lastPathComponent,
                    fileName: url.lastPathComponent,
                    duration: nil
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

        let destFileName = sourceURL.lastPathComponent
        let destURL = soundsDir.appendingPathComponent(destFileName)

        // Handle duplicate names
        var finalURL = destURL
        var counter = 1
        while fileManager.fileExists(atPath: finalURL.path) {
            let baseName = destURL.deletingPathExtension().lastPathComponent
            let ext = destURL.pathExtension
            finalURL = soundsDir.appendingPathComponent("\(baseName) \(counter).\(ext)")
            counter += 1
        }

        do {
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.copyItem(at: sourceURL, to: finalURL)

            let sound = ImportedSound(
                name: finalURL.deletingPathExtension().lastPathComponent,
                fileName: finalURL.lastPathComponent
            )
            importedSounds.insert(sound, at: 0)
            return sound
        } catch {
            return nil
        }
    }

    func deleteSound(_ sound: ImportedSound) {
        guard let localURL = sound.localURL else { return }
        try? fileManager.removeItem(at: localURL)
        importedSounds.removeAll { $0.id == sound.id }
    }

    func renameSound(_ sound: ImportedSound, newName: String) {
        guard let localURL = sound.localURL,
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
        // For AlarmKit custom sounds, the file needs to be in the app's bundle or accessible location
        // We'll return the local file URL; AlarmKit may require specific handling
        return sound.localURL
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