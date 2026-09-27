import Foundation

struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var soundIDs: [UUID]
    var dateCreated: Date

    init(
        id: UUID = UUID(),
        name: String,
        soundIDs: [UUID] = [],
        dateCreated: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.soundIDs = soundIDs
        self.dateCreated = dateCreated
    }
}

enum AlarmSound: Codable, Equatable, Hashable {
    case systemDefault
    case builtIn(String)
    case imported(UUID)
    case random(UUID) // References a Playlist ID

    var id: String {
        switch self {
        case .systemDefault: "systemDefault"
        case .builtIn(let name): "builtin_\(name)"
        case .imported(let id): "imported_\(id.uuidString)"
        case .random(let playlistID): "random_\(playlistID.uuidString)"
        }
    }

    var displayName: String {
        switch self {
        case .systemDefault: "Default"
        case .builtIn(let name): name
        case .imported(_): "Imported"
        case .random(let playlistID): "Random — Playlist \(playlistID.uuidString.prefix(8))"
        }
    }

    var systemFileName: String? {
        switch self {
        case .systemDefault, .imported, .random: nil
        case .builtIn(let name): BuiltInSound.fileName(for: name)
        }
    }
}

enum AlarmLoudness: Int, Codable, CaseIterable, Equatable, Hashable {
    case twentyFive = 25
    case fifty = 50
    case seventyFive = 75
    case hundred = 100

    var displayName: String {
        "\(rawValue)%"
    }

    var gainFactor: Float {
        // Linear amplitude scaling: 25% = 0.25, 50% = 0.50, 75% = 0.75, 100% = 1.0
        Float(rawValue) / 100.0
    }

    static var defaultValue: AlarmLoudness = .hundred
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
