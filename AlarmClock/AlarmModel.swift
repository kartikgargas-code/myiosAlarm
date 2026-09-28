import Foundation

struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var soundIDs: [UUID]
    var selectedSoundIDs: [UUID]  // Tracks which songs are selected for playback
    var dateCreated: Date

    init(
        id: UUID = UUID(),
        name: String,
        soundIDs: [UUID] = [],
        selectedSoundIDs: [UUID]? = nil,
        dateCreated: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.soundIDs = soundIDs
        self.selectedSoundIDs = selectedSoundIDs ?? soundIDs
        self.dateCreated = dateCreated
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, soundIDs, selectedSoundIDs, dateCreated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        soundIDs = try container.decode([UUID].self, forKey: .soundIDs)
        selectedSoundIDs = try container.decodeIfPresent([UUID].self, forKey: .selectedSoundIDs) ?? soundIDs
        dateCreated = try container.decode(Date.self, forKey: .dateCreated)
    }
}

enum AlarmSound: Codable, Equatable, Hashable {
    case systemDefault
    case builtIn(String)
    case imported(UUID)
    case random(UUID) // References a Playlist ID
    case precomposedPlaylist(UUID, AlarmLoudness) // Precomposed playlist with specific loudness

    var id: String {
        switch self {
        case .systemDefault: "systemDefault"
        case .builtIn(let name): "builtin_\(name)"
        case .imported(let id): "imported_\(id.uuidString)"
        case .random(let playlistID): "random_\(playlistID.uuidString)"
        case .precomposedPlaylist(let playlistID, let loudness): "precomposed_\(playlistID.uuidString)_\(loudness.percentage)"
        }
    }

    var displayName: String {
        switch self {
        case .systemDefault: "Default"
        case .builtIn(let name): name
        case .imported(_): "Imported"
        case .random(let playlistID): "Random — Playlist \(playlistID.uuidString.prefix(8))"
        case .precomposedPlaylist(let playlistID, _): "Precomposed — Playlist \(playlistID.uuidString.prefix(8))"
        }
    }

    var systemFileName: String? {
        switch self {
        case .systemDefault, .imported, .random, .precomposedPlaylist: nil
        case .builtIn(let name): BuiltInSound.fileName(for: name)
        }
    }
}

struct AlarmLoudness: Codable, Equatable, Hashable {
    let percentage: Int

    init(_ percentage: Int) {
        self.percentage = min(max(percentage, 0), 100)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(Int.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(percentage)
    }

    var displayName: String { "\(percentage)%" }
    var gainFactor: Float { Float(percentage) / 100.0 }

    static let twentyFive = AlarmLoudness(25)
    static let fifty = AlarmLoudness(50)
    static let seventyFive = AlarmLoudness(75)
    static let hundred = AlarmLoudness(100)
    static let defaultValue = hundred
}

enum AlarmRepeatRule: Codable, Equatable, Hashable {
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
}

struct AlarmTime: Codable, Equatable, Hashable {
    var hour: Int
    var minute: Int
}

struct AlarmOccurrenceOverride: Codable, Equatable {
    var offsetMinutes: Int?
    var customDate: Date?
    var isSkipped: Bool
    // Random song selection for this occurrence
    var randomSoundID: UUID?

    static let none = AlarmOccurrenceOverride(offsetMinutes: nil, customDate: nil, isSkipped: false, randomSoundID: nil)
}

struct AlarmRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    var time: AlarmTime
    var repeatRule: AlarmRepeatRule
    var oneTimeDate: Date?
    var isEnabled: Bool
    var adjustmentStepMinutes: Int
    var overrides: [String: AlarmOccurrenceOverride]
    var sound: AlarmSound
    var loudness: AlarmLoudness

    init(
        id: UUID = UUID(),
        label: String,
        time: AlarmTime,
        repeatRule: AlarmRepeatRule,
        oneTimeDate: Date? = nil,
        isEnabled: Bool = true,
        adjustmentStepMinutes: Int = 10,
        overrides: [String: AlarmOccurrenceOverride] = [:],
        sound: AlarmSound = .systemDefault,
        loudness: AlarmLoudness = .defaultValue
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
    }
}

struct AlarmOccurrence: Codable, Identifiable, Equatable {
    let alarmID: UUID
    let occurrenceKey: String
    let baseDate: Date
    let effectiveDate: Date
    let isAdjusted: Bool

    var id: UUID {
        StableOccurrenceID.make(alarmID: alarmID, occurrenceKey: occurrenceKey)
    }
}

enum StableOccurrenceID {
    static func make(alarmID: UUID, occurrenceKey: String) -> UUID {
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
