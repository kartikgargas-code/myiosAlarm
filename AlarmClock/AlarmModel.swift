import Foundation

public enum BuiltInSound: String, Codable, CaseIterable, Identifiable {
    case classicBell = "Classic Bell"
    case digital = "Digital"
    case gentleWake = "Gentle Wake"
    case morning = "Morning"
    case pulse = "Pulse"
    case chime = "Chime"
    case soft = "Soft"
    case bright = "Bright"

    public var id: String { rawValue }
    
    public var displayName: String { rawValue }
    
    public var fileName: String {
        switch self {
        case .classicBell: "classic-bell.wav"
        case .digital: "digital.wav"
        case .gentleWake: "gentle-wake.wav"
        case .morning: "morning.wav"
        case .pulse: "pulse.wav"
        case .chime: "chime.wav"
        case .soft: "soft.wav"
        case .bright: "bright.wav"
        }
    }
    
    public static func fileName(for displayName: String) -> String? {
        allCases.first { $0.rawValue == displayName }?.fileName
    }
}

public enum PlaylistPlayOrder: String, Codable, CaseIterable, Identifiable {
    case random = "Random"
    case sequence = "Sequence"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .random: "Random"
        case .sequence: "Sequence"
        }
    }
}

public enum PlaylistSortOption: String, Codable, CaseIterable, Identifiable {
    case name = "Name"
    case fileSize = "File Size"
    case dateAdded = "Date Added"
    case dateModified = "Date Modified"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .name: "Name"
        case .fileSize: "File Size"
        case .dateAdded: "Date Added"
        case .dateModified: "Date Modified"
        }
    }
}

public struct Playlist: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var soundIDs: [UUID]
    public var selectedSoundIDs: [UUID]  // Tracks which songs are selected for playback
    public var dateCreated: Date
    public var playOrder: PlaylistPlayOrder  // New: Random vs Sequence
    public var sortOption: PlaylistSortOption  // New: How songs are sorted in editor
    
    public init(
        id: UUID = UUID(),
        name: String,
        soundIDs: [UUID] = [],
        selectedSoundIDs: [UUID]? = nil,
        dateCreated: Date = Date(),
        playOrder: PlaylistPlayOrder = .random,
        sortOption: PlaylistSortOption = .name
    ) {
        self.id = id
        self.name = name
        self.soundIDs = soundIDs
        self.selectedSoundIDs = selectedSoundIDs ?? soundIDs
        self.dateCreated = dateCreated
        self.playOrder = playOrder
        self.sortOption = sortOption
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, name, soundIDs, selectedSoundIDs, dateCreated, playOrder, sortOption
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        soundIDs = try container.decode([UUID].self, forKey: .soundIDs)
        selectedSoundIDs = try container.decodeIfPresent([UUID].self, forKey: .selectedSoundIDs) ?? soundIDs
        dateCreated = try container.decode(Date.self, forKey: .dateCreated)
        playOrder = try container.decodeIfPresent(PlaylistPlayOrder.self, forKey: .playOrder) ?? .random
        sortOption = try container.decodeIfPresent(PlaylistSortOption.self, forKey: .sortOption) ?? .name
    }
}

public enum AlarmSound: Codable, Equatable, Hashable {
    case systemDefault
    case builtIn(String)
    case imported(UUID)
    case random(UUID) // References a Playlist ID
    case precomposedPlaylist(UUID, AlarmLoudness) // Precomposed playlist with specific loudness

    public var id: String {
        switch self {
        case .systemDefault: "systemDefault"
        case .builtIn(let name): "builtin_\(name)"
        case .imported(let id): "imported_\(id.uuidString)"
        case .random(let playlistID): "random_\(playlistID.uuidString)"
        case .precomposedPlaylist(let playlistID, let loudness): "precomposed_\(playlistID.uuidString)_\(loudness.percentage)"
        }
    }

    public var displayName: String {
        switch self {
        case .systemDefault: "Default"
        case .builtIn(let name): name
        case .imported(_): "Imported"
        case .random(let playlistID): "Random — Playlist \(playlistID.uuidString.prefix(8))"
        case .precomposedPlaylist(let playlistID, _): "Precomposed — Playlist \(playlistID.uuidString.prefix(8))"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, name, id, playlistID, loudness
    }

    public init(from decoder: Decoder) throws {
        // Current format: {"type": "imported", "id": ...} etc.
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "systemDefault": self = .systemDefault
            case "builtin":
                let name = try container.decode(String.self, forKey: .name)
                self = .builtIn(name)
            case "imported":
                let id = try container.decode(UUID.self, forKey: .id)
                self = .imported(id)
            case "random":
                let playlistID = try container.decode(UUID.self, forKey: .playlistID)
                self = .random(playlistID)
            case "precomposed":
                let playlistID = try container.decode(UUID.self, forKey: .playlistID)
                let loudness = try container.decode(AlarmLoudness.self, forKey: .loudness)
                self = .precomposedPlaylist(playlistID, loudness)
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid alarm sound type: \(type)")
            }
        } catch {
            self = try AlarmSound.decodeLegacy(from: decoder)
        }
    }

    /// Accepts every encoding AlarmSound has ever produced on device:
    /// - pre-a049a2f auto-synthesis: "systemDefault" | {"imported": "<uuid>"} |
    ///   {"builtIn": "<name>"} | {"random": "<uuid>"} | {"precomposedPlaylist": {"_0": "<uuid>", "_1": 100}}
    /// - current format: {"type": "precomposed", ...}
    private static func decodeLegacy(from decoder: Decoder) throws -> AlarmSound {
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            switch string {
            case "systemDefault": return .systemDefault
            default: break
            }
        }
        let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if let id = try? container.decode(UUID.self, forKey: .imported) {
            return .imported(id)
        }
        if let name = try? container.decode(String.self, forKey: .builtIn) {
            return .builtIn(name)
        }
        if let playlistID = try? container.decode(UUID.self, forKey: .random) {
            return .random(playlistID)
        }
        // Synthesized associated-value payload: {"precomposedPlaylist": {"_0": uuid, "_1": pct}}
        if let payload = try? container.nestedContainer(keyedBy: LegacyPayloadKeys.self, forKey: .precomposedPlaylist),
           let playlistID = try? payload.decode(UUID.self, forKey: ._0),
           let loudness = try? payload.decode(AlarmLoudness.self, forKey: ._1) {
            return .precomposedPlaylist(playlistID, loudness)
        }
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Unrecognized AlarmSound encoding"))
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case systemDefault, builtIn, imported, random, precomposedPlaylist
    }

    private enum LegacyPayloadKeys: String, CodingKey {
        case _0
        case _1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemDefault:
            try container.encode("systemDefault", forKey: .type)
        case .builtIn(let name):
            try container.encode("builtin", forKey: .type)
            try container.encode(name, forKey: .name)
        case .imported(let id):
            try container.encode("imported", forKey: .type)
            try container.encode(id, forKey: .id)
        case .random(let playlistID):
            try container.encode("random", forKey: .type)
            try container.encode(playlistID, forKey: .playlistID)
        case .precomposedPlaylist(let playlistID, let loudness):
            try container.encode("precomposed", forKey: .type)
            try container.encode(playlistID, forKey: .playlistID)
            try container.encode(loudness, forKey: .loudness)
        }
    }
}

public struct AlarmLoudness: Codable, Equatable, Hashable {
    public let percentage: Int

    public init(_ percentage: Int) {
        self.percentage = min(max(percentage, 0), 100)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(percentage)
    }

    public var displayName: String { "\(percentage)%" }
    public var gainFactor: Float { Float(percentage) / 100.0 }

    public static let twentyFive = AlarmLoudness(25)
    public static let fifty = AlarmLoudness(50)
    public static let seventyFive = AlarmLoudness(75)
    public static let hundred = AlarmLoudness(100)
    public static let defaultValue = hundred
}

public enum AlarmRepeatRule: Codable, Equatable, Hashable {
    case never
    case daily
    case weekdays
    case weekends
    case custom(Set<Int>)

    var weekdays: Set<Int> {
        switch self {
        case .never:
            []
        case .daily:
            Set(1...7)
        case .weekdays:
            Set(2...6)
        case .weekends:
            [1, 7]
        case .custom(let days):
            days
        }
    }

    var displayName: String {
        switch self {
        case .never: "Never"
        case .daily: "Every Day"
        case .weekdays: "Weekdays"
        case .weekends: "Weekends"
        case .custom(let days):
            days.filter { (1...7).contains($0) }
                .sorted()
                .map { Calendar.current.shortWeekdaySymbols[$0 - 1] }
                .joined(separator: ", ")
        }
    }

    public init(from decoder: Decoder) throws {
        // Current format: {"type": "daily"} / {"type": "custom", "days": [...]}
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "never": self = .never
            case "daily": self = .daily
            case "weekdays": self = .weekdays
            case "weekends": self = .weekends
            case "custom":
                let days = try container.decode(Set<Int>.self, forKey: .days)
                self = .custom(days)
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid repeat rule type: \(type)")
            }
        } catch {
            self = try AlarmRepeatRule.decodeLegacy(from: decoder)
        }
    }

    /// Accepts every encoding AlarmRepeatRule has ever produced on device:
    /// - pre-1f79eb4 auto-synthesis: "daily" | {"custom": {"_0": [days]}} | {"custom": [days]}
    /// - current format: {"type": "daily"} | {"type": "custom", "days": [...]}
    private static func decodeLegacy(from decoder: Decoder) throws -> AlarmRepeatRule {
        // Plain string: confirmed pre-1f79eb4 encoding (commit diff shows "repeatRule": "daily").
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            switch string {
            case "never": return .never
            case "daily": return .daily
            case "weekdays": return .weekdays
            case "weekends": return .weekends
            case "custom": return .custom([])
            default: break
            }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Synthesized .custom: {"custom": {"_0": [days]}} or {"custom": [days]}.
        if let payload = try? container.nestedContainer(keyedBy: LegacyPayloadKeys.self, forKey: .custom),
           let days = try? payload.decode(Set<Int>.self, forKey: ._0) {
            return .custom(days)
        }
        if let days = try? container.decode(Set<Int>.self, forKey: .custom) {
            return .custom(days)
        }
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Unrecognized AlarmRepeatRule encoding"))
    }

    private enum CodingKeys: String, CodingKey {
        case type, days, custom
    }

    private enum LegacyPayloadKeys: String, CodingKey {
        case _0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .never:
            try container.encode("never", forKey: .type)
        case .daily:
            try container.encode("daily", forKey: .type)
        case .weekdays:
            try container.encode("weekdays", forKey: .type)
        case .weekends:
            try container.encode("weekends", forKey: .type)
        case .custom(let days):
            try container.encode("custom", forKey: .type)
            try container.encode(days, forKey: .days)
        }
    }
}

public struct AlarmTime: Codable, Equatable, Hashable {
    public var hour: Int
    public var minute: Int
}

public struct AlarmOccurrenceOverride: Codable, Equatable {
    public var offsetMinutes: Int?
    public var customDate: Date?
    public var isSkipped: Bool
    // Random song selection for this occurrence
    public var randomSoundID: UUID?

    public static let none = AlarmOccurrenceOverride(offsetMinutes: nil, customDate: nil, isSkipped: false, randomSoundID: nil)
}

public struct AlarmRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public var label: String
    public var time: AlarmTime
    public var repeatRule: AlarmRepeatRule
    public var oneTimeDate: Date?
    public var isEnabled: Bool
    public var adjustmentStepMinutes: Int
    public var overrides: [String: AlarmOccurrenceOverride]
    public var sound: AlarmSound
    public var loudness: AlarmLoudness
    public var snoozeDurationMinutes: Int?

    public init(
        id: UUID = UUID(),
        label: String,
        time: AlarmTime,
        repeatRule: AlarmRepeatRule,
        oneTimeDate: Date? = nil,
        isEnabled: Bool = true,
        adjustmentStepMinutes: Int = 10,
        overrides: [String: AlarmOccurrenceOverride] = [:],
        sound: AlarmSound = .systemDefault,
        loudness: AlarmLoudness = .defaultValue,
        snoozeDurationMinutes: Int? = 10
    ) {
        self.id = id
        self.label = label
        self.time = time
        self.repeatRule = repeatRule
        self.oneTimeDate = oneTimeDate
        self.isEnabled = isEnabled
        self.adjustmentStepMinutes = adjustmentStepMinutes
        self.overrides = overrides
        self.sound = sound
        self.loudness = loudness
        self.snoozeDurationMinutes = snoozeDurationMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, time, repeatRule, oneTimeDate, isEnabled, adjustmentStepMinutes, overrides, sound, loudness, snoozeDurationMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        time = try container.decode(AlarmTime.self, forKey: .time)
        repeatRule = try container.decode(AlarmRepeatRule.self, forKey: .repeatRule)
        oneTimeDate = try container.decodeIfPresent(Date.self, forKey: .oneTimeDate)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        adjustmentStepMinutes = try container.decode(Int.self, forKey: .adjustmentStepMinutes)
        overrides = try container.decode([String: AlarmOccurrenceOverride].self, forKey: .overrides)
        sound = try container.decode(AlarmSound.self, forKey: .sound)
        loudness = try container.decode(AlarmLoudness.self, forKey: .loudness)
        snoozeDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .snoozeDurationMinutes) ?? 10
    }
}

public struct AlarmOccurrence: Codable, Identifiable, Equatable {
    public let alarmID: UUID
    public let occurrenceKey: String
    public let baseDate: Date
    public let effectiveDate: Date
    public let isAdjusted: Bool

    public init(
        alarmID: UUID,
        occurrenceKey: String,
        baseDate: Date,
        effectiveDate: Date,
        isAdjusted: Bool
    ) {
        self.alarmID = alarmID
        self.occurrenceKey = occurrenceKey
        self.baseDate = baseDate
        self.effectiveDate = effectiveDate
        self.isAdjusted = isAdjusted
    }

    public var id: UUID {
        StableOccurrenceID.make(alarmID: alarmID, occurrenceKey: occurrenceKey)
    }
}

/// A record of a song that finished playing during an alarm ring
public struct PlayHistoryEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public let songName: String
    public let alarmLabel: String
    public let alarmID: UUID
    public let timestamp: Date
    // Optional: sound ID if the song is still in the library (added in Phase 9h-4 for delete-with-song)
    public let soundID: UUID?

    public init(
        id: UUID = UUID(),
        songName: String,
        alarmLabel: String,
        alarmID: UUID,
        timestamp: Date = Date(),
        soundID: UUID? = nil
    ) {
        self.id = id
        self.songName = songName
        self.alarmLabel = alarmLabel
        self.alarmID = alarmID
        self.timestamp = timestamp
        self.soundID = soundID
    }

    /// Backward-compatible decoder: old persisted history has no soundID
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        songName = try container.decode(String.self, forKey: .songName)
        alarmLabel = try container.decode(String.self, forKey: .alarmLabel)
        alarmID = try container.decode(UUID.self, forKey: .alarmID)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        soundID = try container.decodeIfPresent(UUID.self, forKey: .soundID)
    }

    private enum CodingKeys: String, CodingKey {
        case id, songName, alarmLabel, alarmID, timestamp, soundID
    }

    /// Display name for the alarm (label or "Alarm at HH:MM")
    public var alarmDisplayName: String {
        if !alarmLabel.isEmpty {
            return alarmLabel
        }
        return "Alarm"
    }
}

public enum StableOccurrenceID {
    public static func make(alarmID: UUID, occurrenceKey: String) -> UUID {
        var bytes = withUnsafeBytes(of: alarmID.uuid) { Array($0) }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in occurrenceKey.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        for index in 0..<8 {
            bytes[index + 8] ^= UInt8(truncatingIfNeeded: hash >> (index * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// Diagnostics for playlist preparation and playback
struct PlaylistDiagnostics: Codable, Equatable {
    struct PreparationEntry: Codable, Equatable {
        let timestamp: Date
        let alarmID: UUID
        let playlistID: UUID
        let playlistName: String
        let totalSongsInPlaylist: Int
        let selectedSongCount: Int
        let selectedSongIDs: [UUID]
        let selectedSongNames: [String]
        let selectedSongDurations: [TimeInterval]
        let expectedTotalDuration: TimeInterval
        let loudnessPercentage: Int
        let usedProcessedAudio: Bool
        let preparationStartTime: Date
        let preparationEndTime: Date
        let preparationDuration: TimeInterval
        let success: Bool
        let error: String?
    }
    
    struct GeneratedFileEntry: Codable, Equatable {
        let timestamp: Date
        let playlistID: UUID
        let fileExists: Bool
        let fileSizeBytes: Int64
        let audioFormat: String?
        let sampleRate: Double?
        let channelCount: Int?
        let actualDuration: TimeInterval
        let expectedDuration: TimeInterval
        let fileReadable: Bool
        let appearsComplete: Bool
    }
    
    struct SchedulingEntry: Codable, Equatable {
        let timestamp: Date
        let alarmID: UUID
        let occurrenceKey: String
        let scheduledDate: Date
        let soundConfiguration: String
        let usedPrecomposedFile: Bool
        let fileName: String?
        let fileExistedAtScheduling: Bool
        let alarmKitAccepted: Bool
        let error: String?
        let fallbackToSingleSong: Bool
        let fallbackReason: String?
    }
    
    struct PlaybackEventEntry: Codable, Equatable {
        let timestamp: Date
        let alarmID: UUID
        let eventType: String
        let details: String?
    }
    
    var preparationHistory: [PreparationEntry] = []
    var generatedFileHistory: [GeneratedFileEntry] = []
    var schedulingHistory: [SchedulingEntry] = []
    var playbackHistory: [PlaybackEventEntry] = []
    
    // Keep only last 50 entries per category to avoid unbounded growth
    private let maxHistory = 50
    
    mutating func addPreparation(_ entry: PreparationEntry) {
        preparationHistory.append(entry)
        if preparationHistory.count > maxHistory {
            preparationHistory.removeFirst(preparationHistory.count - maxHistory)
        }
    }
    
    mutating func addGeneratedFile(_ entry: GeneratedFileEntry) {
        generatedFileHistory.append(entry)
        if generatedFileHistory.count > maxHistory {
            generatedFileHistory.removeFirst(generatedFileHistory.count - maxHistory)
        }
    }
    
    mutating func addScheduling(_ entry: SchedulingEntry) {
        schedulingHistory.append(entry)
        if schedulingHistory.count > maxHistory {
            schedulingHistory.removeFirst(schedulingHistory.count - maxHistory)
        }
    }
    
    mutating func addPlaybackEvent(_ entry: PlaybackEventEntry) {
        playbackHistory.append(entry)
        if playbackHistory.count > maxHistory {
            playbackHistory.removeFirst(playbackHistory.count - maxHistory)
        }
    }
    
    var diagnosticsText: String {
        var output = ""
        output += "=== PLAYLIST DIAGNOSTICS ===\n\n"
        
        if preparationHistory.isEmpty && generatedFileHistory.isEmpty && schedulingHistory.isEmpty && playbackHistory.isEmpty {
            output += "No playlist diagnostics available yet.\n"
            return output
        }
        
        if !preparationHistory.isEmpty {
            output += "--- PREPARATION HISTORY (most recent first) ---\n"
            for entry in preparationHistory.reversed() {
                output += "\n"
                output += "Alarm: \(entry.alarmID.uuidString)\n"
                output += "Playlist: \(entry.playlistName) (\(entry.playlistID.uuidString))\n"
                output += "Total songs in playlist: \(entry.totalSongsInPlaylist)\n"
                output += "Selected songs: \(entry.selectedSongCount)\n"
                for (index, name) in entry.selectedSongNames.enumerated() {
                    let duration = index < entry.selectedSongDurations.count ? entry.selectedSongDurations[index] : 0
                    output += "  \(index + 1). \(name) — \(String(format: "%.1f", duration)) seconds\n"
                }
                output += "Expected total duration: \(String(format: "%.1f", entry.expectedTotalDuration)) seconds\n"
                output += "Loudness: \(entry.loudnessPercentage)%\n"
                output += "Used processed audio: \(entry.usedProcessedAudio ? "yes" : "no")\n"
                output += "Preparation: \(entry.preparationStartTime.formatted(date: .omitted, time: .standard)) → \(entry.preparationEndTime.formatted(date: .omitted, time: .standard)) (\(String(format: "%.2f", entry.preparationDuration))s)\n"
                output += "Success: \(entry.success ? "yes" : "no")\n"
                if let error = entry.error {
                    output += "Error: \(error)\n"
                }
            }
        }
        
        if !generatedFileHistory.isEmpty {
            output += "\n--- GENERATED FILE HISTORY (most recent first) ---\n"
            for entry in generatedFileHistory.reversed() {
                output += "\n"
                output += "Playlist: \(entry.playlistID.uuidString)\n"
                output += "File exists: \(entry.fileExists ? "yes" : "no")\n"
                output += "File size: \(entry.fileSizeBytes) bytes\n"
                if let format = entry.audioFormat { output += "Audio format: \(format)\n" }
                if let rate = entry.sampleRate { output += "Sample rate: \(rate) Hz\n" }
                if let channels = entry.channelCount { output += "Channels: \(channels)\n" }
                output += "Actual duration: \(String(format: "%.1f", entry.actualDuration)) seconds\n"
                output += "Expected duration: \(String(format: "%.1f", entry.expectedDuration)) seconds\n"
                output += "File readable: \(entry.fileReadable ? "yes" : "no")\n"
                output += "Appears complete: \(entry.appearsComplete ? "yes" : "no")\n"
                if abs(entry.actualDuration - entry.expectedDuration) > 1.0 {
                    output += "⚠️ DURATION MISMATCH > 1s\n"
                }
            }
        }
        
        if !schedulingHistory.isEmpty {
            output += "\n--- SCHEDULING HISTORY (most recent first) ---\n"
            for entry in schedulingHistory.reversed() {
                output += "\n"
                output += "Alarm: \(entry.alarmID.uuidString)\n"
                output += "Occurrence: \(entry.occurrenceKey)\n"
                output += "Scheduled: \(entry.scheduledDate.formatted(date: .complete, time: .standard))\n"
                output += "Sound: \(entry.soundConfiguration)\n"
                output += "Precomposed: \(entry.usedPrecomposedFile ? "yes" : "no")\n"
                if let fileName = entry.fileName { output += "File: \(fileName)\n" }
                output += "File existed: \(entry.fileExistedAtScheduling ? "yes" : "no")\n"
                output += "AlarmKit accepted: \(entry.alarmKitAccepted ? "yes" : "no")\n"
                if let error = entry.error { output += "Error: \(error)\n" }
                output += "Fallback: \(entry.fallbackToSingleSong ? "yes (\(entry.fallbackReason ?? "unknown"))" : "no")\n"
            }
        }
        
        if !playbackHistory.isEmpty {
            output += "\n--- PLAYBACK EVENTS (most recent first) ---\n"
            for entry in playbackHistory.reversed() {
                output += "\n"
                output += "\(entry.timestamp.formatted(date: .omitted, time: .standard)) — \(entry.eventType)\n"
                if let details = entry.details { output += "  \(details)\n" }
            }
        }
        
        output += "\n=== NOTE ===\n"
        output += "• AlarmKit does NOT expose song-completion callbacks during active alarm.\n"
        output += "• Transitions between songs in precomposed file are EXPECTED, not OBSERVED via API.\n"
        output += "• User must manually confirm if Song B actually played after Song A.\n"
        
        return output
    }
}
