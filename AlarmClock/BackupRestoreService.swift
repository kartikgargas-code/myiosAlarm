import Foundation
import UniformTypeIdentifiers
import SwiftUI
import os.log

/// Document wrapper for .fileExporter - exports as JSON file from a file URL
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    
    let url: URL
    
    init(url: URL) {
        self.url = url
    }
    
    init(configuration: ReadConfiguration) throws {
        self.url = URL(fileURLWithPath: "")
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return try FileWrapper(url: url, options: .immediate)
    }
}

@MainActor
@Observable
final class BackupRestoreService {
    static let shared = BackupRestoreService()
    
    private let log = OSLog(subsystem: "com.example.alarmclock", category: "BackupRestore")
    
    struct BackupArchive: Codable {
        var alarms: AlarmStoreSnapshot
        var userThemes: [UserTheme]
        var displayNameOverrides: [String: String]  // fileName -> displayName
        var durationOverrides: [String: TimeInterval]  // fileName -> duration
        var sounds: [BackupSoundFile]  // Only imported sounds
        var version: Int = 2
        var exportedAt: Date = Date()
        
        struct BackupSoundFile: Codable {
            let fileName: String
            var name: String? = nil
            var folder: String? = nil
            var duration: TimeInterval? = nil
            var dataBase64: String? = nil   // nil = metadata-only (v2). v1 files still decode.
        }
    }
    
    private init() {}
    
    /// Export all app data to a JSON file (metadata-only, no audio bytes)
    func exportArchive(fileName: String? = nil) async throws -> URL {
        let fileManager = FileManager.default
        
        // Gather all data
        let coordinator = AlarmCoordinator.sharedInstance
        let themeManager = ThemeManager.shared
        let soundLibrary = SoundLibrary.shared
        
        guard let coordinator else {
            throw BackupError.coordinatorNotAvailable
        }
        
        // Collect imported sound metadata only (no audio bytes)
        var soundFiles: [BackupArchive.BackupSoundFile] = []
        for sound in soundLibrary.importedSounds {
            soundFiles.append(.init(
                fileName: sound.fileName,
                name: sound.name,
                folder: sound.folder,
                duration: sound.duration,
                dataBase64: nil
            ))
        }
        
        // Get display name and duration overrides
        let displayNames = soundLibrary.savedDisplayNamesForBackup()
        let durations = soundLibrary.savedDurationsForBackup()
        
        let archive = BackupArchive(
            alarms: try coordinator.currentEngine.snapshot,
            userThemes: themeManager.userThemes,
            displayNameOverrides: displayNames,
            durationOverrides: durations,
            sounds: soundFiles
        )
        
        // Write JSON directly to a stable temp file in Documents (survives until exporter finishes)
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let backupDir = docsDir.appendingPathComponent("AlarmClock_Backups", isDirectory: true)
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        
        // Sanitize the file name
        let base = (fileName?.isEmpty == false ? fileName! : "AlarmClock_Backup_\(Int(Date().timeIntervalSince1970))")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined()
        let archiveURL = backupDir.appendingPathComponent("\(base).json")
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        try data.write(to: archiveURL, options: .atomic)
        
        // Log the file details
        let exists = fileManager.fileExists(atPath: archiveURL.path)
        let byteSize = (try? fileManager.attributesOfItem(atPath: archiveURL.path)[.size] as? Int) ?? 0
        os_log(.info, log: log, "Exported backup to %{public}s (exists=%{public}d, bytes=%{public}d, %d sounds, %d alarms)", archiveURL.path, exists ? 1 : 0, byteSize, soundFiles.count, archive.alarms.alarms.count)
        
        return archiveURL
    }
    
    /// Import and restore from a JSON file
    func importArchive(from url: URL) async throws {
        let fileManager = FileManager.default
        
        // Start accessing security-scoped resource
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
        
        // Read backup.json directly
        guard fileManager.fileExists(atPath: url.path) else {
            throw BackupError.invalidArchive("Backup file not found")
        }
        
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(BackupArchive.self, from: data)
        
        // Validate version (support v1 and v2)
        guard archive.version <= 2 else {
            throw BackupError.unsupportedVersion(archive.version)
        }
        
        // Validate alarms data
        let coordinator = AlarmCoordinator.sharedInstance
        guard let coordinator else {
            throw BackupError.coordinatorNotAvailable
        }
        
        // Stage 1: Restore sound files from base64 (only for v1 archives)
        if archive.version <= 1 {
            let soundsDir = SoundLibrary.shared.soundsDirectory
            if let soundsDir {
                try fileManager.createDirectory(at: soundsDir, withIntermediateDirectories: true)
                
                for soundFile in archive.sounds {
                    let destURL = soundsDir.appendingPathComponent(soundFile.fileName)
                    guard let decodedData = Data(base64Encoded: soundFile.dataBase64 ?? "") else {
                        os_log(.error, log: log, "Failed to decode base64 for sound: %{public}s", soundFile.fileName)
                        continue
                    }
                    try decodedData.write(to: destURL, options: .atomic)
                }
            }
        }
        
        // Stage 2: Restore display names and durations
        let soundLibrary = SoundLibrary.shared
        for (fileName, displayName) in archive.displayNameOverrides {
            soundLibrary.setDisplayNameOverrideForRestore(displayName, for: fileName)
        }
        for (fileName, duration) in archive.durationOverrides {
            soundLibrary.setDurationOverrideForRestore(duration, for: fileName)
        }
        
        // Stage 3: Reload sound library
        soundLibrary.loadSounds()
        
        // Stage 4: Validate alarm sound references - reset missing imported sounds to Default
        var restoredAlarms = archive.alarms.alarms
        var changed = false
        for i in restoredAlarms.indices {
            if case .imported(let id) = restoredAlarms[i].sound,
               !soundLibrary.importedSounds.contains(where: { $0.id == id }) {
                restoredAlarms[i].sound = .systemDefault
                changed = true
            }
        }
        
        let finalAlarms = AlarmStoreSnapshot(alarms: restoredAlarms)
        
        // Stage 5: Save alarms snapshot
        try coordinator.persistence.save(finalAlarms)
        coordinator.currentEngine.snapshot = finalAlarms
        coordinator.publish()
        coordinator.writeAlarmsToAppGroup(finalAlarms)
        
        // Stage 6: Restore user themes
        let themeManager = ThemeManager.shared
        themeManager.userThemes = archive.userThemes
        themeManager.saveUserThemes()
        
        // Stage 7: Re-schedule alarms
        await coordinator.synchronize()
        
        os_log(.info, log: log, "Imported backup (%d sounds, %d alarms, %d themes)", archive.sounds.count, archive.alarms.alarms.count, archive.userThemes.count)
    }
    
    enum BackupError: LocalizedError {
        case coordinatorNotAvailable
        case invalidArchive(String)
        case unsupportedVersion(Int)
        case zipCreationFailed(String)
        case zipExtractionFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .coordinatorNotAvailable:
                return "Alarm coordinator not available"
            case .invalidArchive(let reason):
                return "Invalid backup archive: \(reason)"
            case .unsupportedVersion(let version):
                return "Unsupported backup version: \(version)"
            case .zipCreationFailed(let reason):
                return "Failed to create backup: \(reason)"
            case .zipExtractionFailed(let reason):
                return "Failed to extract backup: \(reason)"
            }
        }
    }
}