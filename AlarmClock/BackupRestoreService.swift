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
        var version: Int = 1
        var exportedAt: Date = Date()
        
        struct BackupSoundFile: Codable {
            let fileName: String
            let dataBase64: String  // Base64 encoded
        }
    }
    
    private init() {}
    
    /// Export all app data to a JSON file (with base64-encoded sounds)
    func exportArchive() async throws -> URL {
        let fileManager = FileManager.default
        
        // Gather all data
        let coordinator = AlarmCoordinator.sharedInstance
        let themeManager = ThemeManager.shared
        let soundLibrary = SoundLibrary.shared
        
        guard let coordinator else {
            throw BackupError.coordinatorNotAvailable
        }
        
        // Collect imported sound files as base64
        var soundFiles: [BackupArchive.BackupSoundFile] = []
        let soundsDir = soundLibrary.soundsDirectory
        
        if let soundsDir {
            for sound in soundLibrary.importedSounds {
                let fileURL = soundsDir.appendingPathComponent(sound.fileName)
                if fileManager.fileExists(atPath: fileURL.path) {
                    let data = try Data(contentsOf: fileURL)
                    let base64String = data.base64EncodedString()
                    soundFiles.append(BackupArchive.BackupSoundFile(fileName: sound.fileName, dataBase64: base64String))
                }
            }
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
        
        let archiveURL = backupDir.appendingPathComponent("AlarmClock_Backup_\(Date().timeIntervalSince1970).json")
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
        
        // Validate version
        guard archive.version <= 1 else {
            throw BackupError.unsupportedVersion(archive.version)
        }
        
        // Validate alarms data
        let coordinator = AlarmCoordinator.sharedInstance
        guard let coordinator else {
            throw BackupError.coordinatorNotAvailable
        }
        
        // Stage 1: Restore sound files from base64
        let soundsDir = SoundLibrary.shared.soundsDirectory
        if let soundsDir {
            try fileManager.createDirectory(at: soundsDir, withIntermediateDirectories: true)
            
            for soundFile in archive.sounds {
                let destURL = soundsDir.appendingPathComponent(soundFile.fileName)
                guard let decodedData = Data(base64Encoded: soundFile.dataBase64) else {
                    os_log(.error, log: log, "Failed to decode base64 for sound: %{public}s", soundFile.fileName)
                    continue
                }
                try decodedData.write(to: destURL, options: .atomic)
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
        
        // Stage 4: Validate alarm sound references
        for alarm in archive.alarms.alarms {
            if case .imported(let id) = alarm.sound {
                let sound = soundLibrary.importedSounds.first { $0.id == id }
                if sound == nil {
                    os_log(.info, log: log, "Alarm %{public}s references missing imported sound %{public}s", alarm.id.uuidString, id.uuidString)
                }
            }
        }
        
        // Stage 5: Save alarms snapshot
        try coordinator.persistence.save(archive.alarms)
        coordinator.currentEngine.snapshot = archive.alarms
        coordinator.publish()
        coordinator.writeAlarmsToAppGroup(archive.alarms)
        
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