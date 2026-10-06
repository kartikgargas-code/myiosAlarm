import Foundation
import UniformTypeIdentifiers
import SwiftUI
import os.log

/// Document wrapper for .fileExporter
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    
    let url: URL?
    
    init(url: URL?) {
        self.url = url
    }
    
    init(configuration: ReadConfiguration) throws {
        self.url = nil
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url = url else {
            throw CocoaError(.fileNoSuchFile)
        }
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
            let data: Data
        }
    }
    
    private init() {}
    
    /// Export all app data to a zip archive
    func exportArchive() async throws -> URL {
        let fileManager = FileManager.default
        
        // Gather all data
        let coordinator = AlarmCoordinator.sharedInstance
        let themeManager = ThemeManager.shared
        let soundLibrary = SoundLibrary.shared
        
        guard let coordinator else {
            throw BackupError.coordinatorNotAvailable
        }
        
        // Collect imported sound files
        var soundFiles: [BackupArchive.BackupSoundFile] = []
        let soundsDir = soundLibrary.soundsDirectory
        
        if let soundsDir {
            for sound in soundLibrary.importedSounds {
                let fileURL = soundsDir.appendingPathComponent(sound.fileName)
                if fileManager.fileExists(atPath: fileURL.path) {
                    let data = try Data(contentsOf: fileURL)
                    soundFiles.append(BackupArchive.BackupSoundFile(fileName: sound.fileName, data: data))
                }
            }
        }
        
        // Get display name and duration overrides
        let displayNames = soundLibrary.savedDisplayNamesForBackup()
        let durations = soundLibrary.savedDurationsForBackup()
        
        let archive = BackupArchive(
            alarms: try coordinator.persistence.load(),
            userThemes: themeManager.userThemes,
            displayNameOverrides: displayNames,
            durationOverrides: durations,
            sounds: soundFiles
        )
        
        // Write to temporary directory
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("AlarmClockBackup_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let archiveURL = tempDir.appendingPathComponent("backup.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        try data.write(to: archiveURL, options: .atomic)
        
        // Create zip file
        let zipURL = fileManager.temporaryDirectory.appendingPathComponent("AlarmClock_Backup_\(Date().timeIntervalSince1970).zip")
        try createZipArchive(sourceDir: tempDir, destinationURL: zipURL)
        
        // Clean up temp directory
        try? fileManager.removeItem(at: tempDir)
        
        os_log(.info, log: log, "Exported backup to %{public}s (%d sounds, %d alarms)", zipURL.path, soundFiles.count, archive.alarms.alarms.count)
        
        return zipURL
    }
    
    /// Import and restore from a zip archive
    func importArchive(from url: URL) async throws {
        let fileManager = FileManager.default
        
        // Start accessing security-scoped resource
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
        
        // Extract to temporary directory
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("AlarmClockRestore_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? fileManager.removeItem(at: tempDir)
        }
        
        try extractZipArchive(sourceURL: url, destinationDir: tempDir)
        
        // Read backup.json
        let archiveURL = tempDir.appendingPathComponent("backup.json")
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            throw BackupError.invalidArchive("backup.json not found")
        }
        
        let data = try Data(contentsOf: archiveURL)
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
        
        // Stage 1: Restore sound files
        let soundsDir = SoundLibrary.shared.soundsDirectory
        if let soundsDir {
            try fileManager.createDirectory(at: soundsDir, withIntermediateDirectories: true)
            
            for soundFile in archive.sounds {
                let destURL = soundsDir.appendingPathComponent(soundFile.fileName)
                try soundFile.data.write(to: destURL, options: .atomic)
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
                    os_log(.warning, log: log, "Alarm %{public}s references missing imported sound %{public}s", alarm.id.uuidString, id.uuidString)
                }
            }
        }
        
        // Stage 5: Save alarms snapshot
        try coordinator.persistence.save(archive.alarms)
        coordinator.engine.snapshot = archive.alarms
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
    
    /// Create a zip archive from a directory
    private func createZipArchive(sourceDir: URL, destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", destinationURL.path, "."]
        process.currentDirectoryURL = sourceDir
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw BackupError.zipCreationFailed(errorString)
        }
    }
    
    /// Extract a zip archive to a directory
    private func extractZipArchive(sourceURL: URL, destinationDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", sourceURL.path, "-d", destinationDir.path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw BackupError.zipExtractionFailed(errorString)
        }
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
                return "Failed to create zip: \(reason)"
            case .zipExtractionFailed(let reason):
                return "Failed to extract zip: \(reason)"
            }
        }
    }
}