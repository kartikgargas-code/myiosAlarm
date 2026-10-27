import Foundation
import UniformTypeIdentifiers
import SwiftUI
import WidgetKit
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

        // Added later - optional, so older backup files still decode.
        var playlists: [Playlist]? = nil
        var activeThemeName: String? = nil
        var activeUserThemeID: UUID? = nil
        var widgetSettings: [String: Double]? = nil
        var buttonSettings: [String: Double]? = nil
        
        struct BackupSoundFile: Codable {
            let fileName: String
            var name: String? = nil
            var folder: String? = nil
            var duration: TimeInterval? = nil
            var dataBase64: String? = nil   // nil = metadata-only (v2). v1 files still decode.
        }
    }
    
    /// Widget / Lock Screen / one-line / Home Screen settings kept in the App Group defaults.
    /// Booleans are stored as 1.0 / 0.0.
    private static let widgetBoolKeys = [
        "widgetBatteryShowCircle", "widgetBatteryShowText", "widgetBatteryShowPercentSign",
        "widgetInlineShowBattery", "widgetHomeShowCircle", "widgetHomeShowText",
        "widgetMemoryShowCircle", "widgetMemoryShowText"
    ]

    private static let widgetNumberKeys = [
        "widgetBatteryCircleScale", "widgetBatteryTextScale", "widgetBatteryPlateOpacity",
        "widgetMemoryCircleScale", "widgetMemoryTextScale", "widgetMemoryPlateOpacity"
    ]

    /// Button glow/appearance settings kept in standard UserDefaults.
    private static let buttonNumberKeys = [
        "buttonGlowRadius", "buttonGlowOpacity", "buttonGlowSpread",
        "buttonOuterRing", "buttonTextOutline", "buttonOutlineWidth"
    ]

    private func exportWidgetSettings() -> [String: Double] {
        let defaults = WidgetSettingsStore.defaults
        var result: [String: Double] = [:]
        for key in Self.widgetBoolKeys {
            if let value = defaults.object(forKey: key) as? Bool { result[key] = value ? 1.0 : 0.0 }
        }
        for key in Self.widgetNumberKeys {
            if let value = defaults.object(forKey: key) as? Double { result[key] = value }
        }
        return result
    }

    private func restoreWidgetSettings(_ settings: [String: Double]) {
        let defaults = WidgetSettingsStore.defaults
        for key in Self.widgetBoolKeys {
            if let value = settings[key] { defaults.set(value >= 0.5, forKey: key) }
        }
        for key in Self.widgetNumberKeys {
            if let value = settings[key] { defaults.set(value, forKey: key) }
        }
    }

    private func exportButtonSettings() -> [String: Double] {
        let defaults = UserDefaults.standard
        var result: [String: Double] = [:]
        for key in Self.buttonNumberKeys {
            if let value = defaults.object(forKey: key) as? Double { result[key] = value }
        }
        return result
    }

    private func restoreButtonSettings(_ settings: [String: Double]) {
        let defaults = UserDefaults.standard
        for key in Self.buttonNumberKeys {
            if let value = settings[key] { defaults.set(value, forKey: key) }
        }
    }

    private init() {}

    /// Suggested name for the next backup: 01mynextalarm25-10-26, then 02..., counting up.
    /// The number is remembered between launches and re-derived from the files already on disk,
    /// so a reinstall does not restart at 01 and quietly overwrite an older backup.
    static func suggestedExportName(date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "dd-MM-yy"
        return String(format: "%02dmynextalarm%@", nextExportNumber(), f.string(from: date))
    }
    /// One past the highest number already used by a backup file or by an earlier launch.
    private static func nextExportNumber() -> Int {
        var highest = UserDefaults.standard.integer(forKey: "backupExportNumber")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let dir = docs?.appendingPathComponent("AlarmClock_Backups", isDirectory: true)
        if let path = dir?.path,
           let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for name in names {
                if let n = Int(name.prefix { $0.isNumber }), n > highest { highest = n }
            }
        }
        return highest + 1
    }
    /// Remembers the number that was actually written, so the next suggestion is one higher.
    static func rememberExportNumber(from name: String) {
        guard let used = Int(name.prefix { $0.isNumber }) else { return }
        if used > UserDefaults.standard.integer(forKey: "backupExportNumber") {
            UserDefaults.standard.set(used, forKey: "backupExportNumber")
        }
    }
    
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
        
        var archive = BackupArchive(
            alarms: try coordinator.currentEngine.snapshot,
            userThemes: themeManager.userThemes,
            displayNameOverrides: displayNames,
            durationOverrides: durations,
            sounds: soundFiles
        )
        archive.playlists = soundLibrary.playlistsForBackup()
        archive.activeThemeName = themeManager.currentTheme.rawValue
        archive.activeUserThemeID = themeManager.activeUserThemeID
        archive.widgetSettings = exportWidgetSettings()
        archive.buttonSettings = exportButtonSettings()
        
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
        
        // Stage 3b: Restore playlists (older backups simply have none). The returned map
        // points backed-up playlist ids at the surviving playlist ids.
        var playlistRemap: [UUID: UUID] = [:]
        if let backedUpPlaylists = archive.playlists {
            playlistRemap = soundLibrary.restorePlaylistsFromBackup(backedUpPlaylists)
        }
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
        
        // Stage 4b: an alarm may refer to a playlist that was matched by NAME, in which case its
        // stored id is the backed-up one and has to be pointed at the playlist that survived.
        for i in restoredAlarms.indices {
            switch restoredAlarms[i].sound {
            case .random(let playlistID):
                if let mapped = playlistRemap[playlistID] {
                    restoredAlarms[i].sound = .random(mapped)
                }
            case .precomposedPlaylist(let playlistID, let selection):
                if let mapped = playlistRemap[playlistID] {
                    restoredAlarms[i].sound = .precomposedPlaylist(mapped, selection)
                }
            default:
                break
            }
        }
        let finalAlarms = AlarmStoreSnapshot(
            alarms: restoredAlarms,
            playlists: archive.alarms.playlists,
            managedSystemAlarmIDs: archive.alarms.managedSystemAlarmIDs,
            playHistory: archive.alarms.playHistory
        )
        
        // Stage 5: Save alarms snapshot
        try coordinator.persistence.save(finalAlarms)
        coordinator.currentEngine.snapshot = finalAlarms
        coordinator.publish()
        coordinator.writeAlarmsToAppGroup(finalAlarms)
        
        // Stage 6: Restore user themes
        let themeManager = ThemeManager.shared
        themeManager.userThemes = archive.userThemes
        themeManager.saveUserThemes()
        themeManager.restoreActiveTheme(
            themeName: archive.activeThemeName,
            activeUserThemeID: archive.activeUserThemeID
        )
        // Stage 6b: Restore widget / one-line / circle settings and refresh the widgets
        if let widgetSettings = archive.widgetSettings {
            restoreWidgetSettings(widgetSettings)
            WidgetCenter.shared.reloadAllTimelines()
        }
        // Stage 6c: Restore button glow/appearance settings
        if let buttonSettings = archive.buttonSettings {
            restoreButtonSettings(buttonSettings)
            ThemeManager.shared.reloadButtonSettings()
        }
        
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