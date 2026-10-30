import Foundation
import AVFoundation
import os.log

private let soundLibraryLog = OSLog(subsystem: "com.example.alarmclock", category: "SoundLibrary")

struct ImportedSound: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var fileName: String
    var duration: TimeInterval?
    var dateAdded: Date
    var folder: String?  // Which imported folder this sound came from
    var isLinked: Bool = false  // true = linked to original file (bookmark), false = copied to Library/Sounds

    init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        duration: TimeInterval? = nil,
        dateAdded: Date = Date(),
        folder: String? = nil,
        isLinked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.duration = duration
        self.dateAdded = dateAdded
        self.folder = folder
        self.isLinked = isLinked
    }

    func localURL(soundsDirectory: URL?) -> URL? {
        guard let soundsDirectory else { return nil }
        return soundsDirectory.appendingPathComponent(fileName)
    }

    // Mock helpers for UI preview/placeholder rows (not persisted)
    static func mockBuiltIn(_ name: String) -> ImportedSound {
        // Use fixed UUIDs for each built-in sound to ensure consistency
        let uuidString: String
        switch name {
        case "Classic Bell": uuidString = "00000000-0000-0000-0000-000000000010"
        case "Digital": uuidString = "00000000-0000-0000-0000-000000000011"
        case "Gentle Wake": uuidString = "00000000-0000-0000-0000-000000000012"
        case "Morning": uuidString = "00000000-0000-0000-0000-000000000013"
        case "Pulse": uuidString = "00000000-0000-0000-0000-000000000014"
        case "Chime": uuidString = "00000000-0000-0000-0000-000000000015"
        case "Soft": uuidString = "00000000-0000-0000-0000-000000000016"
        case "Bright": uuidString = "00000000-0000-0000-0000-000000000017"
        default: uuidString = "00000000-0000-0000-0000-000000000010"
        }
        return ImportedSound(id: UUID(uuidString: uuidString)!,
                     name: name,
                     fileName: "built-in-\(name.lowercased())",
                     duration: nil,
                     dateAdded: Date.distantPast,
                     folder: nil,
                     isLinked: false)
    }
    
    static func mockDefault() -> ImportedSound {
        ImportedSound(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                     name: "Default",
                     fileName: "system-default",
                     duration: nil,
                     dateAdded: Date.distantPast,
                     folder: nil,
                     isLinked: false)
    }
}

/// Persisted record for a linked sound (bookmark to original file location)
struct LinkedSoundRecord: Codable, Identifiable {
    let id: UUID
    var name: String          // display name
    var fileName: String      // original file's lastPathComponent (display only)
    var duration: TimeInterval?
    var dateAdded: Date
    var folder: String?
    var bookmark: Data
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

    /// Trailing "_<uuid>" suffix appended by the importer (stable-ID scheme).
    private static let uuidSuffixRegex = try! NSRegularExpression(
        pattern: "_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    )
    /// Leading track-number prefixes: "03", "03_", "03 - ", "03 " etc.
    private static let trackPrefixRegex = try! NSRegularExpression(
        pattern: "^[0-9]{1,3}[\\s._-]*"
    )

    /// Derive a human display name from a stored filename: drop the
    /// "_<uuid>" suffix, drop a leading track number, tidy underscores.
    static func prettyDisplayName(fromRawName rawName: String) -> String {
        var s = rawName
        let full = NSRange(s.startIndex..., in: s)
        if let m = uuidSuffixRegex.firstMatch(in: s, range: full) {
            s = (s as NSString).replacingCharacters(in: m.range, with: "")
        }
        let afterSuffix = NSRange(s.startIndex..., in: s)
        if let m = trackPrefixRegex.firstMatch(in: s, range: afterSuffix), m.range.length > 0 {
            s = (s as NSString).replacingCharacters(in: m.range, with: "")
        }
        s = s.replacingOccurrences(of: "_+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? rawName : s
    }

    private(set) var importedSounds: [ImportedSound] = []
    /// Extensions AVFoundation can decode. Used by the folder import AND by the disk scan,
    /// so an imported file is still listed after a relaunch. Keep both uses in step.
    static let supportedAudioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac", "mp4", "mov"
    ]
    private(set) var playlists: [Playlist] = []
    private(set) var linkedRecords: [LinkedSoundRecord] = []
    private let fileManager = FileManager.default
    private let displayNameKey = "importedSoundDisplayNames"
    private let durationKey = "importedSoundDurations"
    private let playlistKey = "playlists"
    private let linkedSoundsKey = "linkedSounds"

    var soundsDirectory: URL? {
        // AlarmKit custom sounds must live in the app container Library/Sounds.
        fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    private init() {
        createSoundsDirectory()
        loadSounds()
        loadPlaylists()
    }

    private func createSoundsDirectory() {
        guard let dir = soundsDirectory else { return }
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Reload imported sounds from disk — used by backup/restore
    func loadSounds() {
        // Load linked records from UserDefaults
        loadLinkedRecords()
        
        guard let dir = soundsDirectory else { 
            // Even if soundsDirectory is nil, we still want linked records
            return 
        }
        do {
            let files = try fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]
            )
            let displayNames = savedDisplayNames()
            let copiedSounds: [ImportedSound] = files.compactMap { (url: URL) -> ImportedSound? in
                let ext = url.pathExtension.lowercased()
                guard Self.supportedAudioExtensions.contains(ext) else { return nil }
                // "playlist_..." is the app's own stitched playlist render, not a song anybody
                // imported - keep it out of the list even when an old build left one in this folder.
                // "cache_..." is the temporary AlarmKit copy for a linked song - same rule.
                guard !url.lastPathComponent.hasPrefix("playlist_"),
                      !url.lastPathComponent.hasPrefix("cache_") else { return nil }
                let attrs = try? fileManager.attributesOfItem(atPath: url.path)
                let creationDate = attrs?[.creationDate] as? Date ?? Date()
                let fileName = url.lastPathComponent
                // One-time migration: derive a clean display name from the
                // stored filename and persist it so it stays stable.
                let pretty: String
                if let saved = displayNames[fileName] {
                    pretty = saved
                } else {
                    pretty = Self.prettyDisplayName(fromRawName: url.deletingPathExtension().lastPathComponent)
                    setDisplayNameOverride(pretty, for: fileName)
                }
                return ImportedSound(
                    id: stableID(for: fileName),
                    name: pretty,
                    fileName: fileName,
                    duration: savedDurations()[fileName],
                    dateAdded: creationDate,
                    isLinked: false
                )
            }.sorted { $0.dateAdded > $1.dateAdded }
            
            // Merge: copied sounds first, then linked records
            importedSounds = copiedSounds + linkedRecords.map { record in
                ImportedSound(
                    id: record.id,
                    name: record.name,
                    fileName: record.fileName,
                    duration: record.duration,
                    dateAdded: record.dateAdded,
                    folder: record.folder,
                    isLinked: true
                )
            }.sorted { $0.dateAdded > $1.dateAdded }
            
            backfillMissingDurations()
        } catch {
            // Keep linked records even if disk scan fails
            importedSounds = linkedRecords.map { record in
                ImportedSound(
                    id: record.id,
                    name: record.name,
                    fileName: record.fileName,
                    duration: record.duration,
                    dateAdded: record.dateAdded,
                    folder: record.folder,
                    isLinked: true
                )
            }.sorted { $0.dateAdded > $1.dateAdded }
        }
    }
    
    private func loadLinkedRecords() {
        guard let data = UserDefaults.standard.data(forKey: linkedSoundsKey) else {
            linkedRecords = []
            return
        }
        do {
            let records = try JSONDecoder().decode([LinkedSoundRecord].self, from: data)
            linkedRecords = records
        } catch {
            os_log(.error, log: soundLibraryLog, "Failed to decode linked sounds: %{public}s", error.localizedDescription)
            linkedRecords = []
        }
    }
    
    private func saveLinkedRecords() {
        do {
            let data = try JSONEncoder().encode(linkedRecords)
            UserDefaults.standard.set(data, forKey: linkedSoundsKey)
        } catch {
            os_log(.error, log: soundLibraryLog, "Failed to encode linked sounds: %{public}s", error.localizedDescription)
        }
    }
    
    /// Track which URLs have active security-scoped access
    private var activeSecurityScopedURLs: Set<URL> = []
    
    /// URL to read/play this sound from. For linked sounds, resolves the bookmark and
    /// starts security-scoped access. Returns nil if a linked file can no longer be reached.
    func resolvedURL(for sound: ImportedSound) -> URL? {
        if !sound.isLinked {
            // Copied sound - use the existing localURL method
            return sound.localURL(soundsDirectory: soundsDirectory)
        }
        
        // Linked sound - resolve bookmark
        guard let record = linkedRecords.first(where: { $0.id == sound.id }) else {
            os_log(.error, log: soundLibraryLog, "LINKED: resolve FAILED id=%{public}s %{public}s - record not found", sound.id.uuidString, sound.name)
            SmartWakeDebugLog.log("LINKED: resolve FAILED id=\(sound.id.uuidString) \(sound.name) - record not found")
            return nil
        }
        
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: record.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            
            if stale {
                // Bookmark is stale - create a fresh one and save it
                os_log(.info, log: soundLibraryLog, "LINKED: bookmark stale for id=%{public}s %{public}s - refreshing", sound.id.uuidString, sound.name)
                SmartWakeDebugLog.log("LINKED: bookmark stale for id=\(sound.id.uuidString) \(sound.name) - refreshing")
                if let freshBookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    if let index = linkedRecords.firstIndex(where: { $0.id == sound.id }) {
                        linkedRecords[index].bookmark = freshBookmark
                        saveLinkedRecords()
                    }
                }
            }
            
            // Start security-scoped access if not already started
            if !activeSecurityScopedURLs.contains(url) {
                let started = url.startAccessingSecurityScopedResource()
                if started {
                    activeSecurityScopedURLs.insert(url)
                } else {
                    os_log(.error, log: soundLibraryLog, "LINKED: startAccessingSecurityScopedResource FAILED id=%{public}s %{public}s", sound.id.uuidString, sound.name)
                    SmartWakeDebugLog.log("LINKED: startAccessingSecurityScopedResource FAILED id=\(sound.id.uuidString) \(sound.name)")
                }
            }
            
            // Verify file exists
            if fileManager.fileExists(atPath: url.path) {
                return url
            } else {
                os_log(.error, log: soundLibraryLog, "LINKED: resolve FAILED id=%{public}s %{public}s - file not found at path", sound.id.uuidString, sound.name)
                SmartWakeDebugLog.log("LINKED: resolve FAILED id=\(sound.id.uuidString) \(sound.name) - file not found at path")
                endAccess(for: sound)
                return nil
            }
        } catch {
            os_log(.error, log: soundLibraryLog, "LINKED: resolve FAILED id=%{public}s %{public}s - %{public}s", sound.id.uuidString, sound.name, error.localizedDescription)
            SmartWakeDebugLog.log("LINKED: resolve FAILED id=\(sound.id.uuidString) \(sound.name) - \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Stop security-scoped access for a linked sound's resolved URL
    func endAccess(for sound: ImportedSound) {
        guard sound.isLinked,
              let record = linkedRecords.first(where: { $0.id == sound.id }) else {
            return
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: record.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return
        }
        
        if activeSecurityScopedURLs.remove(url) != nil {
            url.stopAccessingSecurityScopedResource()
            os_log(.info, log: soundLibraryLog, "LINKED: ended access for id=%{public}s %{public}s", sound.id.uuidString, sound.name)
            SmartWakeDebugLog.log("LINKED: ended access for id=\(sound.id.uuidString) \(sound.name)")
        }
    }

    /// Existing sounds predate persisted durations: compute them off the main
    /// actor and publish so playlist rows stop showing "Unknown duration".
    private func backfillMissingDurations() {
        let targets = importedSounds.filter { $0.duration == nil }
        guard !targets.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            var measured: [(fileName: String, duration: TimeInterval)] = []
            for sound in targets {
                guard let url = await SoundLibrary.shared.resolvedURL(for: sound),
                      FileManager.default.fileExists(atPath: url.path) else { continue }
                var duration: TimeInterval? = nil
                if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
                   seconds.isFinite, seconds > 0 {
                    duration = seconds
                }
                if let duration { measured.append((sound.fileName, duration)) }
            }
            guard !measured.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (fileName, seconds) in measured {
                    if let i = self.importedSounds.firstIndex(where: { $0.fileName == fileName }) {
                        self.importedSounds[i].duration = seconds
                    }
                    self.setDurationOverride(seconds, for: fileName)
                }
            }
        }
    }

    private func savedDurations() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: durationKey) as? [String: Double]) ?? [:]
    }

    /// Get all saved duration overrides (for backup/restore)
    func savedDurationsForBackup() -> [String: TimeInterval] {
        return savedDurations()
    }

    private func setDurationOverride(_ seconds: Double, for fileName: String) {
        var overrides = savedDurations()
        overrides[fileName] = seconds
        UserDefaults.standard.set(overrides, forKey: durationKey)
    }
    
    /// Set duration override (for backup/restore)
    func setDurationOverrideForRestore(_ seconds: TimeInterval, for fileName: String) {
        setDurationOverride(seconds, for: fileName)
    }

    /// Playlists as they are right now, for backup.
    func playlistsForBackup() -> [Playlist] {
        playlists
    }

    /// Put restored playlists back, matching BY NAME. A playlist with that name that already
    /// exists is kept as it is - it may already hold the songs the user re-imported - and the
    /// backed-up one is NOT added a second time. Returns a map of the backed-up id to the
    /// surviving id, so the caller can point the restored alarms at the right playlist.
    func restorePlaylistsFromBackup(_ restored: [Playlist]) -> [UUID: UUID] {
        var remap: [UUID: UUID] = [:]
        for candidate in restored {
            if let index = playlists.firstIndex(where: { $0.name == candidate.name }) {
                remap[candidate.id] = playlists[index].id
            } else {
                playlists.append(candidate)
                remap[candidate.id] = candidate.id
            }
        }
        savePlaylists()
        return remap
    }
    
    /// Restore playlists from v3 backup that includes missingSongs field.
    /// Keeps ALL entries (even missing ones), marks missing so they can be reconnected later.
    /// Returns (remap, reconnectedCount, stillMissingCount).
    func restorePlaylistsFromBackupV3(_ restored: [Playlist]) -> ([UUID: UUID], Int, Int) {
        var remap: [UUID: UUID] = [:]
        var reconnectedCount = 0
        var stillMissingCount = 0
        
        // Build a lookup of imported sounds by normalized fileName for reconnection
        let soundsByFileName = Dictionary(grouping: importedSounds, by: { normalizeFileName($0.fileName) })
        
        for candidate in restored {
            if let index = playlists.firstIndex(where: { $0.name == candidate.name }) {
                // Playlist already exists - merge entries, keeping missing ones
                var existing = playlists[index]
                
                // First, handle missingSongs from backup - try to reconnect them
                for missingSong in candidate.missingSongs {
                    let fileNameKey = normalizeFileName(missingSong.fileName)
                    if let matchingSounds = soundsByFileName[fileNameKey],
                       let match = matchingSounds.first {
                        // Song now exists in library - add its UUID
                        if !existing.soundIDs.contains(match.id) {
                            existing.soundIDs.append(match.id)
                        }
                        if !existing.selectedSoundIDs.contains(match.id) {
                            existing.selectedSoundIDs.append(match.id)
                        }
                        reconnectedCount += 1
                    } else {
                        // Still missing - keep in missingSongs
                        if !existing.missingSongs.contains(where: { normalizeFileName($0.fileName) == fileNameKey }) {
                            existing.missingSongs.append(missingSong)
                        }
                        stillMissingCount += 1
                    }
                }
                
                // Also try to reconnect any existing missingSongs in the playlist
                var newMissingSongs: [MissingSong] = []
                for missingSong in existing.missingSongs {
                    let fileNameKey = normalizeFileName(missingSong.fileName)
                    if let matchingSounds = soundsByFileName[fileNameKey],
                       let match = matchingSounds.first {
                        // Song now exists - reconnect
                        if !existing.soundIDs.contains(match.id) {
                            existing.soundIDs.append(match.id)
                        }
                        if !existing.selectedSoundIDs.contains(match.id) {
                            existing.selectedSoundIDs.append(match.id)
                        }
                        reconnectedCount += 1
                    } else {
                        // Still missing
                        newMissingSongs.append(missingSong)
                    }
                }
                existing.missingSongs = newMissingSongs
                
                playlists[index] = existing
                remap[candidate.id] = existing.id
            } else {
                // New playlist - build it with whatever songs we can connect
                var newSoundIDs: [UUID] = []
                var newSelectedIDs: [UUID] = []
                var newMissingSongs: [MissingSong] = []
                
                // First process missingSongs from backup
                for missingSong in candidate.missingSongs {
                    let fileNameKey = normalizeFileName(missingSong.fileName)
                    if let matchingSounds = soundsByFileName[fileNameKey],
                       let match = matchingSounds.first {
                        newSoundIDs.append(match.id)
                        newSelectedIDs.append(match.id)
                        reconnectedCount += 1
                    } else {
                        newMissingSongs.append(missingSong)
                        stillMissingCount += 1
                    }
                }
                
                let newPlaylist = Playlist(
                    name: candidate.name,
                    soundIDs: newSoundIDs,
                    selectedSoundIDs: newSelectedIDs,
                    dateCreated: candidate.dateCreated,
                    playOrder: candidate.playOrder,
                    sortOption: candidate.sortOption,
                    missingSongs: newMissingSongs
                )
                playlists.append(newPlaylist)
                remap[candidate.id] = newPlaylist.id
                stillMissingCount += newMissingSongs.count
            }
        }
        savePlaylists()
        return (remap, reconnectedCount, stillMissingCount)
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
    
    /// Remove sound IDs from playlists that no longer exist in importedSounds
    /// Called on load and before playback/stitch to keep playlists clean
    func selfHealPlaylists() {
        let validIDs = Set(importedSounds.map { $0.id })
        var totalRemoved = 0
        
        for i in playlists.indices {
            let beforeSoundCount = playlists[i].soundIDs.count
            let beforeSelectedCount = playlists[i].selectedSoundIDs.count
            
            playlists[i].soundIDs = playlists[i].soundIDs.filter { validIDs.contains($0) }
            playlists[i].selectedSoundIDs = playlists[i].selectedSoundIDs.filter { validIDs.contains($0) }
            
            let removed = (beforeSoundCount - playlists[i].soundIDs.count) + (beforeSelectedCount - playlists[i].selectedSoundIDs.count)
            totalRemoved += removed
        }
        
        if totalRemoved > 0 {
            SmartWakeDebugLog.log("PLAYLIST SELF-HEAL: removed \(totalRemoved) missing ids across \(playlists.count) playlists")
            // Save the healed playlists
            savePlaylists()
        }
    }

    func importMP3(from sourceURL: URL) async throws -> ImportedSound {
        // Start accessing the security-scoped resource
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        
        let displayName = sourceURL.deletingPathExtension().lastPathComponent
        let fileName = sourceURL.lastPathComponent
        
        // Read duration from the audio file without copying
        var duration: TimeInterval? = nil
        do {
            let audioFile = try AVAudioFile(forReading: sourceURL)
            let sampleRate = audioFile.processingFormat.sampleRate
            let frameCount = audioFile.length
            if sampleRate > 0, frameCount > 0 {
                duration = Double(frameCount) / sampleRate
            }
        } catch {
            // Duration reading failed, try asset fallback below
        }
        if duration == nil || duration == 0 {
            let asset = AVURLAsset(url: sourceURL)
            if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
                duration = seconds
            }
        }
        
        // Create bookmark for the original file
        let bookmark: Data
        do {
            bookmark = try sourceURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw SoundLibraryError.importFailed("Failed to create bookmark for \(fileName): \(error.localizedDescription)")
        }
        
        // Stable ID derived from file name so re-import after restore gets the same ID
        let stableId = stableID(for: fileName)
        
        // Create linked record
        let record = LinkedSoundRecord(
            id: stableId,
            name: displayName,
            fileName: fileName,
            duration: duration,
            dateAdded: Date(),
            folder: nil,
            bookmark: bookmark
        )
        linkedRecords.insert(record, at: 0)
        saveLinkedRecords()
        
        // Create ImportedSound with isLinked = true
        let sound = ImportedSound(
            id: stableId,
            name: displayName,
            fileName: fileName,
            duration: duration,
            dateAdded: record.dateAdded,
            folder: nil,
            isLinked: true
        )
        importedSounds.insert(sound, at: 0)
        return sound
    }

    func importFolder(from sourceURL: URL) async throws -> Playlist {
        // Start accessing the security-scoped resource
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        
        let folderName = sourceURL.lastPathComponent
        var linkedRecordsToAdd: [LinkedSoundRecord] = []
        var importedSoundInfos: [(id: UUID, name: String, fileName: String, duration: TimeInterval?)] = []
        var errors: [String] = []

        do {
            let fileManager = FileManager.default
            
            let fileURLs = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            let audioFiles = fileURLs.filter {
                Self.supportedAudioExtensions.contains($0.pathExtension.lowercased())
                    && !$0.lastPathComponent.hasPrefix("playlist_")
            }

            for sourceFileURL in audioFiles {
                do {
                    let displayName = sourceFileURL.deletingPathExtension().lastPathComponent
                    let fileName = sourceFileURL.lastPathComponent
                    
                    // Read duration from the audio file without copying
                    var duration: TimeInterval? = nil
                    do {
                        let audioFile = try AVAudioFile(forReading: sourceFileURL)
                        let sampleRate = audioFile.processingFormat.sampleRate
                        let frameCount = audioFile.length
                        if sampleRate > 0, frameCount > 0 {
                            duration = Double(frameCount) / sampleRate
                        }
                    } catch {
                        // Duration reading failed, asset fallback below
                    }
                    if duration == nil || duration == 0 {
                        let asset = AVURLAsset(url: sourceFileURL)
                        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
                            duration = seconds
                        }
                    }
                    
                    // Create bookmark for the original file
                    let bookmark: Data
                    do {
                        bookmark = try sourceFileURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                    } catch {
                        errors.append("\(fileName): Failed to create bookmark - \(error.localizedDescription)")
                        continue
                    }
                    
                    // Stable ID derived from file name so re-import after restore gets the same ID
                    let stableId = stableID(for: fileName)
                    
                    // Create linked record
                    let record = LinkedSoundRecord(
                        id: stableId,
                        name: displayName,
                        fileName: fileName,
                        duration: duration,
                        dateAdded: Date(),
                        folder: folderName,
                        bookmark: bookmark
                    )
                    linkedRecordsToAdd.append(record)
                    importedSoundInfos.append((id: stableId, name: displayName, fileName: fileName, duration: duration))
                } catch {
                    errors.append("\(sourceFileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            throw SoundLibraryError.folderImportFailed("Failed to read folder: \(error.localizedDescription)")
        }

        guard !importedSoundInfos.isEmpty else {
            throw SoundLibraryError.folderImportFailed("No playable audio files found in this folder.")
        }

        // Update @MainActor state
        await MainActor.run {
            let importedSoundIDs = importedSoundInfos.map { $0.id }
            
            // Add linked records
            for record in linkedRecordsToAdd {
                linkedRecords.insert(record, at: 0)
            }
            saveLinkedRecords()
            
            // Create ImportedSound objects with isLinked = true
            for info in importedSoundInfos {
                let sound = ImportedSound(
                    id: info.id,
                    name: info.name,
                    fileName: info.fileName,
                    duration: info.duration,
                    folder: folderName,
                    isLinked: true
                )
                if let d = info.duration {
                    self.setDurationOverride(d, for: info.fileName)
                }
                self.importedSounds.insert(sound, at: 0)
            }

            // A playlist with this folder's name may already exist - for example one that came back
            // from a backup. Put the songs INTO it instead of adding a second playlist with the same
            // name, so the alarms that already point at it keep working.
            if let index = self.playlists.firstIndex(where: { $0.name == folderName }) {
                var existing = self.playlists[index]
                for id in importedSoundIDs where !existing.soundIDs.contains(id) {
                    existing.soundIDs.append(id)
                }
                for id in importedSoundIDs where !existing.selectedSoundIDs.contains(id) {
                    existing.selectedSoundIDs.append(id)
                }
                self.playlists[index] = existing
                AudioProcessingService.shared.removePrecomposedPlaylist(for: existing.id)
            } else {
                let playlist = Playlist(
                    name: folderName,
                    soundIDs: importedSoundIDs,
                    selectedSoundIDs: importedSoundIDs  // All songs selected by default
                )
                self.playlists.append(playlist)
            }
            self.savePlaylists()
            
            // After folder import, reconnect any missing playlist entries by fileName
            // and rebuild alarm sounds so playlists with now-available songs work
            let (reconnected, stillMissing) = self.reconnectMissingPlaylistEntries()
            // RECONNECT is logged by the UI layer (ContentView/SoundPickerView) to avoid duplicate logs
            // Note: alarm rebuild (synchronize) is called by the UI layer after import completes
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

    /// Reconnect missing playlist entries by matching fileName in importedSounds.
    /// Called after mp3 folder import to hook up songs that were missing at backup-restore time.
    /// Uses Unicode NFC normalization and case-insensitive comparison.
    /// Returns (reconnectedCount, stillMissingCount).
    func reconnectMissingPlaylistEntries() -> (Int, Int) {
        // Build lookup with normalized keys (NFC + lowercase)
        let soundsByFileName = Dictionary(grouping: importedSounds, by: { normalizeFileName($0.fileName) })
        var reconnectedCount = 0
        var stillMissingCount = 0
        
        for i in playlists.indices {
            var playlist = playlists[i]
            var newMissingSongs: [MissingSong] = []
            
            // Process missingSongs - try to reconnect them
            for missingSong in playlist.missingSongs {
                let fileNameKey = normalizeFileName(missingSong.fileName)
                if let matchingSounds = soundsByFileName[fileNameKey],
                   let match = matchingSounds.first {
                    // Song now exists in library - reconnect
                    if !playlist.soundIDs.contains(match.id) {
                        playlist.soundIDs.append(match.id)
                    }
                    if !playlist.selectedSoundIDs.contains(match.id) {
                        playlist.selectedSoundIDs.append(match.id)
                    }
                    reconnectedCount += 1
                } else {
                    // Still missing
                    newMissingSongs.append(missingSong)
                    stillMissingCount += 1
                }
            }
            
            playlist.missingSongs = newMissingSongs
            playlists[i] = playlist
        }
        savePlaylists()
        SmartWakeDebugLog.log("RECONNECT: matched \(reconnectedCount), still missing \(stillMissingCount)")
        
        return (reconnectedCount, stillMissingCount)
    }
    
    /// Normalize file name for matching: Unicode NFC + lowercase
    private func normalizeFileName(_ fileName: String) -> String {
        fileName.precomposedStringWithCanonicalMapping.lowercased()
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
    
    /// Remove a sound from all playlists (both soundIDs and selectedSoundIDs) and save
    func removeSoundFromAllPlaylists(_ soundID: UUID) {
        for i in playlists.indices {
            playlists[i].soundIDs.removeAll { $0 == soundID }
            playlists[i].selectedSoundIDs.removeAll { $0 == soundID }
        }
        savePlaylists()
    }

    func deleteSound(_ sound: ImportedSound, referencedBy alarms: [AlarmRecord]) {
        guard !isReferenced(sound, by: alarms) else { return }
        AudioProcessingService.shared.removeProcessedSounds(for: sound)
        if sound.isLinked {
            AudioProcessingService.shared.removeCacheFiles(for: sound.id)
        }
        
        if sound.isLinked {
            // Linked sound - remove bookmark and end access, DON'T delete original file
            endAccess(for: sound)
            if let index = linkedRecords.firstIndex(where: { $0.id == sound.id }) {
                linkedRecords.remove(at: index)
                saveLinkedRecords()
            }
        } else {
            // Copied sound - delete the copy from Library/Sounds
            if let localURL = sound.localURL(soundsDirectory: soundsDirectory) {
                try? fileManager.removeItem(at: localURL)
            }
        }
        
        removeDisplayNameOverride(for: sound.fileName)
        importedSounds.removeAll { $0.id == sound.id }

        // Remove from any playlists
        for i in playlists.indices {
            playlists[i].soundIDs.removeAll { $0 == sound.id }
            playlists[i].selectedSoundIDs.removeAll { $0 == sound.id }
        }
        savePlaylists()
    }
    
    /// Delete a sound file by its ID (for Play History delete-with-song)
    func deleteSoundFileByID(_ soundID: UUID) {
        guard let sound = importedSounds.first(where: { $0.id == soundID }) else { return }
        let fileName = sound.fileName
        
        // Remove processed sounds (gain-adjusted variants)
        AudioProcessingService.shared.removeProcessedSounds(for: sound)
        if sound.isLinked {
            AudioProcessingService.shared.removeCacheFiles(for: sound.id)
        }
        SmartWakeDebugLog.log("SOUND DELETE: removeProcessedSounds ran for id=\(soundID.uuidString) file=\(fileName)")
        
        if sound.isLinked {
            // Linked sound - remove bookmark and end access, DON'T delete original file
            endAccess(for: sound)
            if let index = linkedRecords.firstIndex(where: { $0.id == soundID }) {
                linkedRecords.remove(at: index)
                saveLinkedRecords()
            }
            SmartWakeDebugLog.log("SOUND DELETE: id=\(soundID.uuidString) file=\(fileName) LINKED - removed bookmark only")
        } else {
            // Copied sound - delete the copy from Library/Sounds
            var deleteError: String?
            var verifiedGone = false
            if let localURL = sound.localURL(soundsDirectory: soundsDirectory) {
                let path = localURL.path
                do {
                    try fileManager.removeItem(at: localURL)
                    verifiedGone = !fileManager.fileExists(atPath: path)
                } catch {
                    deleteError = error.localizedDescription
                    verifiedGone = !fileManager.fileExists(atPath: path)
                }
            } else {
                deleteError = "soundsDirectory is nil, localURL is nil"
            }
            
            // Log the deletion result
            let verifiedStatus = verifiedGone ? "gone" : "STILL PRESENT"
            let errMsg = deleteError ?? "none"
            SmartWakeDebugLog.log("SOUND DELETE: id=\(soundID.uuidString) file=\(fileName) verified=\(verifiedStatus) path=\(sound.localURL(soundsDirectory: soundsDirectory)?.path ?? "nil") err=\(errMsg)")
        }
        
        removeDisplayNameOverride(for: fileName)
        importedSounds.removeAll { $0.id == soundID }

        // Remove from any playlists - BOTH soundIDs AND selectedSoundIDs
        for i in playlists.indices {
            playlists[i].soundIDs.removeAll { $0 == soundID }
            playlists[i].selectedSoundIDs.removeAll { $0 == soundID }
        }
        savePlaylists()
        
        // Reset any alarm whose sound is .imported(this id) back to system default
        // This is done via AlarmCoordinator's confirmDeleteSoundFile which calls this method
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
        let url = resolvedURL(for: sound)
        guard let url, fileManager.fileExists(atPath: url.path) else {
            throw SoundLibraryError.soundFileMissing(sound.fileName)
        }
        // For ALL imported single-song alarms, use a capped (120s max) cache file.
        // One file per song (by sound ID), raw/no-gain, reused across alarms/loudness.
        // Per-alarm loudness is NOT baked into system-played single songs.
        // Linked sounds also end access after cache creation.
        if let soundsDir = soundsDirectory {
            let cacheFileName = "cache_\(sound.id.uuidString.prefix(8))_\(sound.fileName)"
            let dest = soundsDir.appendingPathComponent(cacheFileName)
            if !fileManager.fileExists(atPath: dest.path) {
                let cacheDest = dest.appendingPathExtension("tmp")
                try? fileManager.removeItem(at: cacheDest)
                if let duration = sound.duration, duration > TimeInterval(AlarmCoordinator.backupSoundCapSeconds) {
                    // Longer than the cap - render a truncated WAV (raw, no gain)
                    try? AudioProcessingService.shared.renderCappedAlarmSound(
                        from: url,
                        to: cacheDest,
                        maxDuration: TimeInterval(AlarmCoordinator.backupSoundCapSeconds)
                    )
                } else {
                    try? fileManager.copyItem(at: url, to: cacheDest)
                }
                if (try? fileManager.attributesOfItem(atPath: cacheDest.path)[.size]) != nil {
                    try? fileManager.moveItem(at: cacheDest, to: dest)
                    // Log only on first creation - subsequent calls reuse the file
                    SmartWakeDebugLog.log("CACHE: created capped alarm sound \(cacheFileName) (ONCE per song)")
                } else {
                    SmartWakeDebugLog.log("CACHE: capped alarm sound creation FAILED for \(cacheFileName)")
                }
            }
            if sound.isLinked {
                endAccess(for: sound)
            }
            return cacheFileName
        }
        return sound.fileName
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

    /// Get all saved display name overrides (for backup/restore)
    func savedDisplayNamesForBackup() -> [String: String] {
        return savedDisplayNames()
    }

    private func setDisplayNameOverride(_ name: String, for fileName: String) {
        var overrides = savedDisplayNames()
        overrides[fileName] = name
        UserDefaults.standard.set(overrides, forKey: displayNameKey)
    }
    
    /// Set display name override (for backup/restore)
    func setDisplayNameOverrideForRestore(_ name: String, for fileName: String) {
        setDisplayNameOverride(name, for: fileName)
    }

    private func removeDisplayNameOverride(for fileName: String) {
        var overrides = savedDisplayNames()
        overrides[fileName] = nil
        UserDefaults.standard.set(overrides, forKey: displayNameKey)
    }
    
    /// All unique folder names from imported sounds (sorted)
    var importedFolders: [String] {
        Array(Set(importedSounds.compactMap { $0.folder })).sorted()
    }
    
    /// Remove the physical sound file and any processed variants (for copied sounds only)
    /// For linked sounds, removes the bookmark and ends access but does NOT delete the original file
    private func purgeSoundFiles(_ sound: ImportedSound) {
        AudioProcessingService.shared.removeProcessedSounds(for: sound)
        if sound.isLinked {
            AudioProcessingService.shared.removeCacheFiles(for: sound.id)
        }
        
        if sound.isLinked {
            // Linked sound - remove bookmark and end access, DON'T delete original file
            endAccess(for: sound)
            if let index = linkedRecords.firstIndex(where: { $0.id == sound.id }) {
                linkedRecords.remove(at: index)
                saveLinkedRecords()
            }
        } else {
            // Copied sound - delete the copy from Library/Sounds
            if let url = sound.localURL(soundsDirectory: soundsDirectory) {
                try? fileManager.removeItem(at: url)
            }
        }
        
        removeDisplayNameOverride(for: sound.fileName)
    }
    
    /// Delete all imported sounds and playlists
    func deleteAllSounds() {
        let count = importedSounds.count
        for sound in importedSounds { purgeSoundFiles(sound) }
        importedSounds = []
        playlists = []
        savePlaylists()
        SmartWakeDebugLog.log("SOUNDS DELETE ALL: cleared \(count) tracks + playlists")
    }
    
    /// Delete all sounds in a specific folder (and the playlist with that name)
    func deleteSounds(inFolder folder: String) {
        let victims = importedSounds.filter { $0.folder == folder }
        let victimIDs = Set(victims.map { $0.id })
        for sound in victims { purgeSoundFiles(sound) }
        importedSounds.removeAll { victimIDs.contains($0.id) }
        playlists.removeAll { $0.name == folder }
        savePlaylists()
        SmartWakeDebugLog.log("SOUNDS DELETE FOLDER: \(folder) removed \(victims.count) tracks + playlist")
    }
}